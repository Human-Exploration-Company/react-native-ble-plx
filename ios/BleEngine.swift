import CoreBluetooth
import Foundation
import os

// The Apple engine, on CoreBluetooth directly.
//
// Threading model
//
// Every piece of mutable state below is confined to `BleEngine.queue`, which is also the queue the
// CBCentralManager delivers its delegate calls on. `@JS` methods start on the JavaScript thread,
// dispatch onto the queue and suspend on a continuation; no code touches state after resuming.
//
// Identity
//
// Each session has a generation. Requests carry the generation they were issued for; events and
// results carry the session's. Each connection attempt has a token; a callback from an attempt that
// is no longer current is dropped. GATT objects get numeric handles when discovered; a handle dies
// with its connection, a new discovery, or the service it belongs to changing.
//
// Ordering
//
// CoreBluetooth answers a peripheral's requests of one kind on one attribute in the order they were
// made, so each attribute keeps a FIFO of its waiting requests. A request cancelled from JavaScript
// stays in its FIFO until CoreBluetooth answers it, so later answers still reach later requests.

// MARK: - Settle once

/// Resumes its continuation exactly once, from any thread. Later calls are ignored.
final class Once<R: Sendable>: @unchecked Sendable {
  private let continuation: OSAllocatedUnfairLock<CheckedContinuation<R, Never>?>

  init(_ continuation: CheckedContinuation<R, Never>) {
    self.continuation = OSAllocatedUnfairLock(uncheckedState: continuation)
  }

  @discardableResult
  func resume(_ value: R) -> Bool {
    let taken = continuation.withLockUnchecked { state -> CheckedContinuation<R, Never>? in
      let current = state
      state = nil
      return current
    }
    guard let taken else {
      return false
    }
    taken.resume(returning: value)
    return true
  }
}

// MARK: - Pending requests

protocol PendingEntry: AnyObject {
  var id: UInt64 { get }
  var publicTransaction: String? { get }
  var settled: Bool { get }
  func fail(_ error: BleErrorRecord)
}

/// One in-flight request. Settling removes it from its session's registry.
final class Pending<R: BleResult>: PendingEntry, @unchecked Sendable {
  let id: UInt64
  let generation: Int
  private let once: Once<R>
  private weak var session: Session?
  var publicTransaction: String?
  private(set) var settled = false

  init(id: UInt64, generation: Int, once: Once<R>, session: Session) {
    self.id = id
    self.generation = generation
    self.once = once
    self.session = session
  }

  func succeed(_ result: R) {
    guard !settled else { return }
    settled = true
    session?.unregister(self)
    once.resume(result)
  }

  func fail(_ error: BleErrorRecord) {
    guard !settled else { return }
    settled = true
    session?.unregister(self)
    once.resume(R.failure(generation, error))
  }
}

/// A FIFO of requests waiting on one attribute's answers.
struct Waiters<R: BleResult> {
  private var items: [Pending<R>] = []

  var isEmpty: Bool { items.isEmpty }

  mutating func append(_ entry: Pending<R>) { items.append(entry) }

  /// The oldest request, settled or not: CoreBluetooth's answer belongs to it.
  mutating func pop() -> Pending<R>? {
    items.isEmpty ? nil : items.removeFirst()
  }

  mutating func failAll(_ error: BleErrorRecord) {
    let all = items
    items.removeAll()
    all.forEach { $0.fail(error) }
  }
}

// MARK: - Session state

struct Connection {
  enum Phase {
    case connecting
    case connected
    case cancelling
  }

  let token: UInt64
  var phase: Phase
  var connect: Pending<PeripheralResultRecord>?
  var cancels: [Pending<PeripheralResultRecord>] = []
  var timeout: DispatchWorkItem?
}

struct Monitor {
  let deviceId: String
  let characteristic: Double
}

enum Attribute {
  case service(deviceId: String, service: CBService)
  case characteristic(deviceId: String, characteristic: CBCharacteristic, service: Double)
  case descriptor(deviceId: String, descriptor: CBDescriptor, characteristic: Double, service: Double)

  var deviceId: String {
    switch self {
    case let .service(deviceId, _), let .characteristic(deviceId, _, _), let .descriptor(deviceId, _, _, _):
      return deviceId
    }
  }
}

/// A discovery in progress: services, then each service's characteristics, then each one's descriptors.
struct Discovery {
  let pending: Pending<GattTreeResultRecord>
  var outstanding = 0
}

/// Requests waiting on one peripheral's answers.
struct PeripheralWaiters {
  var reads: [ObjectIdentifier: Waiters<BytesResultRecord>] = [:]
  var writes: [ObjectIdentifier: Waiters<VoidResultRecord>] = [:]
  var notifies: [ObjectIdentifier: Waiters<VoidResultRecord>] = [:]
  var descriptorReads: [ObjectIdentifier: Waiters<BytesResultRecord>] = [:]
  var descriptorWrites: [ObjectIdentifier: Waiters<VoidResultRecord>] = [:]
  var rssi = Waiters<PeripheralResultRecord>()
  /// Writes without response waiting for room in CoreBluetooth's queue.
  var unsent: [(pending: Pending<VoidResultRecord>, characteristic: CBCharacteristic, value: Data)] = []
  var discovery: Discovery?

  mutating func failAll(_ error: BleErrorRecord) {
    for key in reads.keys { reads[key]?.failAll(error) }
    for key in writes.keys { writes[key]?.failAll(error) }
    for key in notifies.keys { notifies[key]?.failAll(error) }
    for key in descriptorReads.keys { descriptorReads[key]?.failAll(error) }
    for key in descriptorWrites.keys { descriptorWrites[key]?.failAll(error) }
    rssi.failAll(error)
    let waiting = unsent
    unsent.removeAll()
    waiting.forEach { $0.pending.fail(error) }
    if let discovery {
      self.discovery = nil
      discovery.pending.fail(error)
    }
  }
}

final class OpenWaiter {
  let once: Once<OpenResultRecord>
  init(_ once: Once<OpenResultRecord>) { self.once = once }
}

final class Session: @unchecked Sendable {
  let generation: Int
  let central: CBCentralManager
  let delegate: CentralDelegate

  var pending: [UInt64: PendingEntry] = [:]
  /// Public transaction id to the pending request currently using it.
  var transactions: [String: UInt64] = [:]
  var peripherals: [String: CBPeripheral] = [:]
  var connections: [String: Connection] = [:]
  var waiters: [String: PeripheralWaiters] = [:]
  var monitors: [String: Monitor] = [:]
  var attributes: [Double: Attribute] = [:]
  var handles: [ObjectIdentifier: Double] = [:]
  /// The last advertisement seen of each peripheral, for its snapshots.
  var advertised: [String: PeripheralRecord] = [:]
  var scanId: String?
  var openWaiter: OpenWaiter?
  var logLevel = "None"
  private var serial: UInt64 = 0
  private var lastHandle: Double = 0

  init(generation: Int, central: CBCentralManager, delegate: CentralDelegate) {
    self.generation = generation
    self.central = central
    self.delegate = delegate
  }

  func nextSerial() -> UInt64 {
    serial &+= 1
    return serial
  }

  func nextHandle() -> Double {
    lastHandle += 1
    return lastHandle
  }

  func register<R: BleResult>(_ once: Once<R>) -> Pending<R> {
    let entry = Pending(id: nextSerial(), generation: generation, once: once, session: self)
    pending[entry.id] = entry
    return entry
  }

  /// Binds a public transaction id to `entry`; a request still holding the same id is cancelled.
  func begin<R: BleResult>(_ entry: Pending<R>, _ publicTransaction: String) {
    if let previous = transactions[publicTransaction], let stale = pending[previous] {
      stale.fail(.make("OperationCancelled"))
    }
    entry.publicTransaction = publicTransaction
    transactions[publicTransaction] = entry.id
  }

  func unregister(_ entry: PendingEntry) {
    guard pending[entry.id] === entry else {
      return
    }
    pending[entry.id] = nil
    if let publicTransaction = entry.publicTransaction, transactions[publicTransaction] == entry.id {
      transactions[publicTransaction] = nil
    }
  }

  func handle(of object: AnyObject) -> Double? {
    handles[ObjectIdentifier(object)]
  }

  func assign(_ object: AnyObject, _ attribute: Attribute) -> Double {
    if let existing = handles[ObjectIdentifier(object)] {
      attributes[existing] = attribute
      return existing
    }
    let handle = nextHandle()
    handles[ObjectIdentifier(object)] = handle
    attributes[handle] = attribute
    return handle
  }

  /// Forgets the handles of `deviceId`, or only those under `services`.
  func forget(_ deviceId: String, services: Set<ObjectIdentifier>? = nil) -> [Double] {
    var dropped: [Double] = []
    for (handle, attribute) in attributes where attribute.deviceId == deviceId {
      let owner: CBService?
      switch attribute {
      case let .service(_, service): owner = service
      case let .characteristic(_, characteristic, _): owner = characteristic.service
      case let .descriptor(_, descriptor, _, _): owner = descriptor.characteristic?.service
      }
      if let services, !(owner.map { services.contains(ObjectIdentifier($0)) } ?? true) {
        continue
      }
      dropped.append(handle)
    }
    for handle in dropped {
      attributes[handle] = nil
    }
    handles = handles.filter { !dropped.contains($0.value) }
    return dropped
  }
}

// MARK: - Delegate and event sink

/// CoreBluetooth retains its delegates weakly; the session holds this one and it holds the engine
/// weakly, stamping events with the generation of the central that produced them.
final class CentralDelegate: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
  private weak var engine: BleEngine?
  let generation: Int

  init(engine: BleEngine, generation: Int) {
    self.engine = engine
    self.generation = generation
  }

  private func on(_ body: (BleEngine, Session) -> Void) {
    guard let engine, let session = engine.current(generation) else { return }
    body(engine, session)
  }

  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    on { $0.stateChanged($1) }
  }

  func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
    let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
    on { $0.restored($1, restored) }
  }

  func centralManager(
    _ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
    advertisementData: [String: Any], rssi RSSI: NSNumber
  ) {
    on { $0.discovered($1, peripheral, advertisementData, RSSI) }
  }

  func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
    on { $0.didConnect($1, peripheral) }
  }

  func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
    on { $0.didFailToConnect($1, peripheral, error) }
  }

  func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
    on { $0.didDisconnect($1, peripheral, error) }
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    on { $0.didDiscoverServices($1, peripheral, error) }
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
    on { $0.didDiscoverCharacteristics($1, peripheral, service, error) }
  }

  func peripheral(_ peripheral: CBPeripheral, didDiscoverDescriptorsFor characteristic: CBCharacteristic, error: Error?) {
    on { $0.didDiscoverDescriptors($1, peripheral, error) }
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
    on { $0.didUpdateValue($1, peripheral, characteristic, error) }
  }

  func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
    on { $0.didWrite($1, peripheral, characteristic, error) }
  }

  func peripheral(
    _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?
  ) {
    on { $0.didUpdateNotificationState($1, peripheral, characteristic, error) }
  }

  func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor descriptor: CBDescriptor, error: Error?) {
    on { $0.didReadDescriptor($1, peripheral, descriptor, error) }
  }

  func peripheral(_ peripheral: CBPeripheral, didWriteValueFor descriptor: CBDescriptor, error: Error?) {
    on { $0.didWriteDescriptor($1, peripheral, descriptor, error) }
  }

  func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
    on { $0.didReadRSSI($1, peripheral, RSSI, error) }
  }

  func peripheralIsReady(toSendWriteWithoutResponse peripheral: CBPeripheral) {
    on { $0.readyToWrite($1, peripheral) }
  }

  func peripheral(_ peripheral: CBPeripheral, didModifyServices invalidatedServices: [CBService]) {
    on { $0.servicesChanged($1, peripheral, invalidatedServices) }
  }
}

protocol BleEventSink: AnyObject {
  func emit(stateChange event: StateChangeEventRecord)
  func emit(scan event: ScanEventRecord)
  func emit(notification event: NotificationEventRecord)
  func emit(disconnect event: DisconnectEventRecord)
  func emit(servicesChange event: ServicesChangeEventRecord)
}

private final class SinkBox: @unchecked Sendable {
  private let lock = OSAllocatedUnfairLock()
  private weak var value: BleEventSink?

  var sink: BleEventSink? {
    get { lock.withLockUnchecked { value } }
    set { lock.withLockUnchecked { value = newValue } }
  }
}

// MARK: - Engine

final class BleEngine: @unchecked Sendable {
  private let queue: DispatchQueue
  private let sinkBox = SinkBox()
  private var session: Session?
  private var lastGeneration = 0
  private var lastConnectionToken: UInt64 = 0
  private let log = Logger(subsystem: "com.bleplx", category: "engine")

  init() {
    queue = DispatchQueue(label: "com.bleplx.adapter", qos: .userInitiated)
  }

  func attach(_ sink: BleEventSink) {
    sinkBox.sink = sink
  }

  fileprivate func current(_ generation: Int) -> Session? {
    guard let session, session.generation == generation else { return nil }
    return session
  }

  private var sink: BleEventSink? { sinkBox.sink }

  /// Registers a request for `generation` on the queue and suspends until it settles.
  private func run<R: BleResult>(
    _ generation: Int,
    _: R.Type,
    _ work: @escaping @Sendable (Session, Pending<R>) -> Void
  ) async -> R {
    await withCheckedContinuation { (continuation: CheckedContinuation<R, Never>) in
      let once = Once(continuation)
      queue.async { [self] in
        guard let session, session.generation == generation else {
          once.resume(R.failure(generation, .sessionClosed))
          return
        }
        work(session, session.register(once))
      }
    }
  }

  /// Runs a GATT request on a connected peripheral, or fails it as the radio's state requires.
  private func onPeripheral<R: BleResult>(
    _ session: Session, _ pending: Pending<R>, _ deviceId: String, _ body: (CBPeripheral) -> Void
  ) {
    if let unavailable = BleConversions.unavailable(session.central.state) {
      pending.fail(unavailable)
      return
    }
    guard let peripheral = session.peripherals[deviceId], peripheral.state == .connected,
      session.connections[deviceId]?.phase == .connected
    else {
      pending.fail(.make("DeviceNotConnected", deviceId: deviceId))
      return
    }
    body(peripheral)
  }

  private func characteristicAt(_ session: Session, _ handle: Double) -> (String, CBCharacteristic)? {
    if case let .characteristic(deviceId, characteristic, _) = session.attributes[handle] {
      return (deviceId, characteristic)
    }
    return nil
  }

  private func descriptorAt(_ session: Session, _ handle: Double) -> (String, CBDescriptor)? {
    if case let .descriptor(deviceId, descriptor, _, _) = session.attributes[handle] {
      return (deviceId, descriptor)
    }
    return nil
  }

  // MARK: Lifecycle

  func open(_ options: OpenOptionsRecord) async -> OpenResultRecord {
    await withCheckedContinuation { (continuation: CheckedContinuation<OpenResultRecord, Never>) in
      let once = Once(continuation)
      queue.async { [self] in
        if let session {
          once.resume(.failure(session.generation, .make("SessionAlreadyOpen")))
          return
        }
        lastGeneration += 1
        let generation = lastGeneration
        let delegate = CentralDelegate(engine: self, generation: generation)
        var managerOptions: [String: Any] = [CBCentralManagerOptionShowPowerAlertKey: false]
        if let restore = options.restoreIdentifier {
          managerOptions[CBCentralManagerOptionRestoreIdentifierKey] = restore
        }
        // The delegate is given at creation: with a restore identifier, CoreBluetooth throws
        // unless it implements willRestoreState. Its calls come on this queue, so none reaches
        // the delegate before this block has set the session up.
        let central = CBCentralManager(delegate: delegate, queue: queue, options: managerOptions)
        let session = Session(generation: generation, central: central, delegate: delegate)
        session.logLevel = options.logLevel
        self.session = session
        guard options.restoreIdentifier != nil else {
          once.resume(.success(generation, OpenInfoRecord(state: BleConversions.state(central.state), restored: nil)))
          return
        }
        // With restoration, CoreBluetooth calls willRestoreState before the first state update when
        // it relaunched the app for this manager; otherwise the first state update comes alone.
        // Hold the result until one of them so restored peripherals reach JavaScript with it.
        session.openWaiter = OpenWaiter(once)
      }
    }
  }

  func close(_ generation: Int) async -> VoidResultRecord {
    await withCheckedContinuation { (continuation: CheckedContinuation<VoidResultRecord, Never>) in
      let once = Once(continuation)
      queue.async { [self] in
        guard let session, session.generation == generation else {
          once.resume(.ok(generation))
          return
        }
        teardown(session)
        once.resume(.ok(generation))
      }
    }
  }

  /// Called from the module's `willDestroy`. The block keeps the engine alive until it runs.
  func destroy() {
    queue.async { [self] in
      if let session {
        teardown(session)
      }
      sinkBox.sink = nil
    }
  }

  private func teardown(_ session: Session) {
    if self.session === session {
      self.session = nil
    }
    if let waiter = session.openWaiter {
      session.openWaiter = nil
      waiter.once.resume(.failure(session.generation, .sessionClosed))
    }
    for deviceId in Array(session.waiters.keys) {
      session.waiters[deviceId]?.failAll(.sessionClosed)
    }
    for entry in Array(session.pending.values) {
      entry.fail(.sessionClosed)
    }
    if session.scanId != nil, session.central.state == .poweredOn {
      session.central.stopScan()
    }
    for (deviceId, connection) in session.connections {
      connection.timeout?.cancel()
      if let peripheral = session.peripherals[deviceId] {
        session.central.cancelPeripheralConnection(peripheral)
      }
    }
    session.connections.removeAll()
    session.monitors.removeAll()
    session.attributes.removeAll()
    session.handles.removeAll()
    session.scanId = nil
    for peripheral in session.peripherals.values where peripheral.delegate === session.delegate {
      peripheral.delegate = nil
    }
    session.central.delegate = nil
  }

  fileprivate func stateChanged(_ session: Session) {
    let state = BleConversions.state(session.central.state)
    if session.openWaiter != nil {
      finishOpen(session, restored: nil)
    }
    if session.central.state != .poweredOn {
      // CoreBluetooth ends every link and scan when the radio goes; report them as ended.
      session.scanId = nil
      let unavailable = BleConversions.unavailable(session.central.state) ?? .make("BluetoothPoweredOff")
      for deviceId in Array(session.connections.keys) {
        endConnection(session, deviceId, error: unavailable)
      }
    }
    sink?.emit(stateChange: StateChangeEventRecord(generation: session.generation, state: state))
  }

  fileprivate func restored(_ session: Session, _ peripherals: [CBPeripheral]) {
    var connected: [PeripheralRecord] = []
    for peripheral in peripherals {
      let id = peripheral.identifier.uuidString
      session.peripherals[id] = peripheral
      peripheral.delegate = session.delegate
      if peripheral.state == .connected {
        session.connections[id] = Connection(token: nextConnectionToken(), phase: .connected)
        connected.append(record(session, peripheral))
      }
    }
    finishOpen(session, restored: connected)
  }

  private func finishOpen(_ session: Session, restored: [PeripheralRecord]?) {
    guard let waiter = session.openWaiter else {
      return
    }
    session.openWaiter = nil
    waiter.once.resume(.success(
      session.generation,
      OpenInfoRecord(state: BleConversions.state(session.central.state), restored: restored)
    ))
  }

  private func nextConnectionToken() -> UInt64 {
    lastConnectionToken &+= 1
    return lastConnectionToken
  }

  /// A snapshot of a peripheral: what it last advertised, its name and the payload it takes now.
  private func record(_ session: Session, _ peripheral: CBPeripheral, rssi: Int? = nil) -> PeripheralRecord {
    let id = peripheral.identifier.uuidString
    var snapshot = session.advertised[id] ?? BleConversions.minimalPeripheral(id)
    snapshot.name = peripheral.name ?? snapshot.name
    if let rssi {
      snapshot.rssi = rssi
    }
    snapshot.mtu = peripheral.state == .connected
      ? peripheral.maximumWriteValueLength(for: .withoutResponse) + 3
      : 23
    return snapshot
  }

  // MARK: State and logging

  func state(_ generation: Int) async -> StateResultRecord {
    await run(generation, StateResultRecord.self) { session, pending in
      pending.succeed(.success(generation, BleConversions.state(session.central.state)))
    }
  }

  func setLogLevel(_ generation: Int, _ level: String) async -> VoidResultRecord {
    await run(generation, VoidResultRecord.self) { session, pending in
      session.logLevel = level
      pending.succeed(.ok(generation))
    }
  }

  func logLevel(_ generation: Int) async -> LogLevelResultRecord {
    await run(generation, LogLevelResultRecord.self) { session, pending in
      pending.succeed(.success(generation, session.logLevel))
    }
  }

  // MARK: Scanning

  func startScan(_ generation: Int, _ scanId: String, _ options: ScanOptionsRecord) async -> VoidResultRecord {
    await run(generation, VoidResultRecord.self) { [self] session, pending in
      let fail = { (error: BleErrorRecord) in
        // A scan that cannot start reports so as its first event, as one that fails later does.
        session.scanId = nil
        self.sink?.emit(scan: ScanEventRecord(generation: generation, scanId: scanId, device: nil, error: error))
      }
      if session.scanId != nil, session.central.state == .poweredOn {
        session.central.stopScan()
      }
      session.scanId = scanId
      pending.succeed(.ok(generation))
      if let unavailable = BleConversions.unavailable(session.central.state) {
        fail(unavailable)
        return
      }
      var services: [CBUUID]?
      if let uuids = options.services {
        guard uuids.allSatisfy(BleConversions.isUUID) else {
          fail(.make("InvalidIdentifiers", reason: "Not a UUID: \(uuids.joined(separator: ", "))"))
          return
        }
        services = uuids.map { CBUUID(string: $0) }
      }
      session.central.scanForPeripherals(
        withServices: services,
        options: [CBCentralManagerScanOptionAllowDuplicatesKey: options.allowDuplicates]
      )
    }
  }

  func stopScan(_ generation: Int, _ scanId: String) async -> VoidResultRecord {
    await run(generation, VoidResultRecord.self) { session, pending in
      if session.scanId == scanId {
        session.scanId = nil
        if session.central.state == .poweredOn {
          session.central.stopScan()
        }
      }
      pending.succeed(.ok(generation))
    }
  }

  fileprivate func discovered(
    _ session: Session, _ peripheral: CBPeripheral, _ advertisement: [String: Any], _ rssi: NSNumber
  ) {
    let id = peripheral.identifier.uuidString
    session.peripherals[id] = peripheral
    let snapshot = BleConversions.advertised(id, peripheral.name, advertisement, rssi.intValue)
    session.advertised[id] = snapshot
    guard let scanId = session.scanId else { return }
    sink?.emit(scan: ScanEventRecord(generation: session.generation, scanId: scanId, device: snapshot, error: nil))
  }

  // MARK: Connections

  func connect(_ generation: Int, _ deviceId: String, _ options: ConnectOptionsRecord) async -> PeripheralResultRecord {
    await run(generation, PeripheralResultRecord.self) { [self] session, pending in
      if let existing = session.connections[deviceId] {
        pending.fail(
          existing.phase == .connected
            ? .make("DeviceAlreadyConnected", deviceId: deviceId)
            : .make("OperationStartFailed", reason: "A connection change is already in progress", deviceId: deviceId)
        )
        return
      }
      if let unavailable = BleConversions.unavailable(session.central.state) {
        pending.fail(unavailable)
        return
      }
      guard let peripheral = peripheral(session, deviceId) else {
        pending.fail(.make("DeviceNotFound", deviceId: deviceId))
        return
      }
      let token = nextConnectionToken()
      var connection = Connection(token: token, phase: .connecting, connect: pending)
      if let timeoutMs = options.timeoutMs {
        let timeout = DispatchWorkItem { [weak self, weak session] in
          guard let self, let session, session.connections[deviceId]?.token == token,
            session.connections[deviceId]?.phase == .connecting
          else { return }
          session.connections[deviceId] = nil
          session.central.cancelPeripheralConnection(peripheral)
          pending.fail(.make("OperationTimedOut", reason: "The connection did not complete in time", deviceId: deviceId))
          _ = self
        }
        connection.timeout = timeout
        queue.asyncAfter(deadline: .now() + .milliseconds(timeoutMs), execute: timeout)
      }
      session.connections[deviceId] = connection
      peripheral.delegate = session.delegate
      // A peripheral the system holds connected (another app, or restoration) connects at once.
      session.central.connect(peripheral, options: nil)
    }
  }

  /// The peripheral for `deviceId`: one seen this session, or one the system knows by identifier.
  private func peripheral(_ session: Session, _ deviceId: String) -> CBPeripheral? {
    if let known = session.peripherals[deviceId] {
      return known
    }
    guard let uuid = UUID(uuidString: deviceId),
      let found = session.central.retrievePeripherals(withIdentifiers: [uuid]).first
    else {
      return nil
    }
    session.peripherals[deviceId] = found
    return found
  }

  fileprivate func didConnect(_ session: Session, _ peripheral: CBPeripheral) {
    let deviceId = peripheral.identifier.uuidString
    guard var connection = session.connections[deviceId], connection.phase == .connecting else {
      // An attempt abandoned since: CoreBluetooth connected anyway; let it go.
      session.central.cancelPeripheralConnection(peripheral)
      return
    }
    connection.timeout?.cancel()
    connection.timeout = nil
    connection.phase = .connected
    let pending = connection.connect
    connection.connect = nil
    session.connections[deviceId] = connection
    pending?.succeed(.success(session.generation, record(session, peripheral)))
  }

  fileprivate func didFailToConnect(_ session: Session, _ peripheral: CBPeripheral, _ error: Error?) {
    let deviceId = peripheral.identifier.uuidString
    guard let connection = session.connections[deviceId], connection.phase == .connecting else { return }
    connection.timeout?.cancel()
    session.connections[deviceId] = nil
    connection.connect?.fail(BleConversions.error(error, "DeviceConnectionFailed", deviceId: deviceId))
  }

  fileprivate func didDisconnect(_ session: Session, _ peripheral: CBPeripheral, _ error: Error?) {
    let deviceId = peripheral.identifier.uuidString
    guard let connection = session.connections[deviceId] else { return }
    if connection.phase == .connecting {
      // A pending connection that ended before it was made fails the attempt.
      connection.timeout?.cancel()
      session.connections[deviceId] = nil
      connection.connect?.fail(BleConversions.error(error, "DeviceConnectionFailed", deviceId: deviceId))
      return
    }
    endConnection(
      session, deviceId,
      error: error.map { BleConversions.error($0, "DeviceDisconnected", deviceId: deviceId) }
    )
  }

  /// A connection ended: its requests fail, its handles and monitors go, and JavaScript hears once.
  private func endConnection(_ session: Session, _ deviceId: String, error: BleErrorRecord?) {
    guard let connection = session.connections.removeValue(forKey: deviceId) else { return }
    connection.timeout?.cancel()
    let failure = error ?? .make("DeviceDisconnected", deviceId: deviceId)
    connection.connect?.fail(failure)
    session.waiters[deviceId]?.failAll(.make("DeviceDisconnected", deviceId: deviceId))
    session.waiters[deviceId] = nil
    for (subscriptionId, monitor) in session.monitors where monitor.deviceId == deviceId {
      session.monitors[subscriptionId] = nil
    }
    _ = session.forget(deviceId)
    let snapshot = session.peripherals[deviceId].map { record(session, $0) } ?? BleConversions.minimalPeripheral(deviceId)
    for cancel in connection.cancels {
      cancel.succeed(.success(session.generation, snapshot))
    }
    if connection.phase != .connecting {
      sink?.emit(disconnect: DisconnectEventRecord(generation: session.generation, deviceId: deviceId, error: error))
    }
  }

  func cancelConnection(_ generation: Int, _ deviceId: String) async -> PeripheralResultRecord {
    await run(generation, PeripheralResultRecord.self) { [self] session, pending in
      guard var connection = session.connections[deviceId] else {
        pending.fail(.make("DeviceNotConnected", deviceId: deviceId))
        return
      }
      guard let peripheral = session.peripherals[deviceId] else {
        endConnection(session, deviceId, error: nil)
        pending.succeed(.success(generation, BleConversions.minimalPeripheral(deviceId)))
        return
      }
      switch connection.phase {
      case .connecting:
        // Abandon the attempt: its connect settles as cancelled, and CoreBluetooth stops trying.
        connection.timeout?.cancel()
        session.connections[deviceId] = nil
        connection.connect?.fail(.make("OperationCancelled", deviceId: deviceId))
        session.central.cancelPeripheralConnection(peripheral)
        pending.succeed(.success(generation, record(session, peripheral)))
      case .connected, .cancelling:
        // Settles when CoreBluetooth reports the disconnection.
        connection.phase = .cancelling
        connection.cancels.append(pending)
        session.connections[deviceId] = connection
        session.central.cancelPeripheralConnection(peripheral)
      }
    }
  }

  func isConnected(_ generation: Int, _ deviceId: String) async -> BoolResultRecord {
    await run(generation, BoolResultRecord.self) { [self] session, pending in
      pending.succeed(.success(generation, peripheral(session, deviceId)?.state == .connected))
    }
  }

  func known(_ generation: Int, _ deviceIds: [String]) async -> PeripheralListResultRecord {
    await run(generation, PeripheralListResultRecord.self) { [self] session, pending in
      let uuids = deviceIds.compactMap(UUID.init(uuidString:))
      guard uuids.count == deviceIds.count else {
        pending.fail(.make("InvalidIdentifiers"))
        return
      }
      let found = session.central.retrievePeripherals(withIdentifiers: uuids)
      for peripheral in found {
        session.peripherals[peripheral.identifier.uuidString] = peripheral
      }
      pending.succeed(.success(generation, found.map { record(session, $0) }))
    }
  }

  func connected(_ generation: Int, _ services: [String]) async -> PeripheralListResultRecord {
    await run(generation, PeripheralListResultRecord.self) { [self] session, pending in
      guard services.allSatisfy(BleConversions.isUUID) else {
        pending.fail(.make("InvalidIdentifiers"))
        return
      }
      let found = session.central.retrieveConnectedPeripherals(withServices: services.map { CBUUID(string: $0) })
      for peripheral in found {
        session.peripherals[peripheral.identifier.uuidString] = peripheral
      }
      pending.succeed(.success(generation, found.map { record(session, $0) }))
    }
  }

  // MARK: Discovery

  func discover(_ generation: Int, _ deviceId: String, _ transactionId: String) async -> GattTreeResultRecord {
    await run(generation, GattTreeResultRecord.self) { [self] session, pending in
      session.begin(pending, transactionId)
      onPeripheral(session, pending, deviceId) { peripheral in
        if let previous = session.waiters[deviceId]?.discovery {
          previous.pending.fail(.make("OperationCancelled", deviceId: deviceId))
        }
        session.waiters[deviceId, default: PeripheralWaiters()].discovery = Discovery(pending: pending, outstanding: 1)
        peripheral.discoverServices(nil)
      }
    }
  }

  private func discoveryStep(
    _ session: Session, _ peripheral: CBPeripheral, _ error: Error?, _ code: String, _ more: () -> Int
  ) {
    let deviceId = peripheral.identifier.uuidString
    guard var discovery = session.waiters[deviceId]?.discovery else { return }
    if discovery.pending.settled {
      session.waiters[deviceId]?.discovery = nil
      return
    }
    if let error {
      session.waiters[deviceId]?.discovery = nil
      discovery.pending.fail(BleConversions.error(error, code, deviceId: deviceId))
      return
    }
    discovery.outstanding += more() - 1
    if discovery.outstanding > 0 {
      session.waiters[deviceId]?.discovery = discovery
      return
    }
    session.waiters[deviceId]?.discovery = nil
    discovery.pending.succeed(.success(session.generation, tree(session, peripheral)))
  }

  fileprivate func didDiscoverServices(_ session: Session, _ peripheral: CBPeripheral, _ error: Error?) {
    discoveryStep(session, peripheral, error, "ServicesDiscoveryFailed") {
      let services = peripheral.services ?? []
      services.forEach { peripheral.discoverCharacteristics(nil, for: $0) }
      return services.count
    }
  }

  fileprivate func didDiscoverCharacteristics(
    _ session: Session, _ peripheral: CBPeripheral, _ service: CBService, _ error: Error?
  ) {
    discoveryStep(session, peripheral, error, "CharacteristicsDiscoveryFailed") {
      let characteristics = service.characteristics ?? []
      characteristics.forEach { peripheral.discoverDescriptors(for: $0) }
      return characteristics.count
    }
  }

  fileprivate func didDiscoverDescriptors(_ session: Session, _ peripheral: CBPeripheral, _ error: Error?) {
    discoveryStep(session, peripheral, error, "DescriptorsDiscoveryFailed") { 0 }
  }

  /// The discovered table, with fresh handles for this discovery; earlier handles die.
  private func tree(_ session: Session, _ peripheral: CBPeripheral) -> GattTreeRecord {
    let deviceId = peripheral.identifier.uuidString
    _ = session.forget(deviceId)
    var services: [ServiceRecord] = []
    var characteristics: [CharacteristicRecord] = []
    var descriptors: [DescriptorRecord] = []
    for service in peripheral.services ?? [] {
      let serviceHandle = session.assign(service, .service(deviceId: deviceId, service: service))
      let serviceUUID = BleConversions.uuid(service.uuid)
      services.append(ServiceRecord(deviceId: deviceId, handle: serviceHandle, uuid: serviceUUID, isPrimary: service.isPrimary))
      for characteristic in service.characteristics ?? [] {
        let handle = session.assign(
          characteristic, .characteristic(deviceId: deviceId, characteristic: characteristic, service: serviceHandle)
        )
        let properties = characteristic.properties
        characteristics.append(CharacteristicRecord(
          deviceId: deviceId, handle: handle, uuid: BleConversions.uuid(characteristic.uuid),
          serviceHandle: serviceHandle, serviceUUID: serviceUUID,
          isReadable: properties.contains(.read),
          isWritableWithResponse: properties.contains(.write),
          isWritableWithoutResponse: properties.contains(.writeWithoutResponse),
          isNotifiable: properties.contains(.notify),
          isNotifying: characteristic.isNotifying,
          isIndicatable: properties.contains(.indicate),
          value: characteristic.value
        ))
        for descriptor in characteristic.descriptors ?? [] {
          let descriptorHandle = session.assign(
            descriptor,
            .descriptor(deviceId: deviceId, descriptor: descriptor, characteristic: handle, service: serviceHandle)
          )
          descriptors.append(DescriptorRecord(
            deviceId: deviceId, handle: descriptorHandle, uuid: BleConversions.uuid(descriptor.uuid),
            characteristicHandle: handle, characteristicUUID: BleConversions.uuid(characteristic.uuid),
            serviceHandle: serviceHandle, serviceUUID: serviceUUID,
            value: BleConversions.descriptorValue(descriptor.value)
          ))
        }
      }
    }
    return GattTreeRecord(deviceId: deviceId, services: services, characteristics: characteristics, descriptors: descriptors)
  }

  // MARK: GATT operations

  /// A characteristic's failure, with where it happened.
  private func failure(_ code: String, _ characteristic: CBCharacteristic, _ deviceId: String, _ error: Error?) -> BleErrorRecord {
    var record = BleConversions.error(error, code, deviceId: deviceId)
    record.serviceUUID = characteristic.service.map { BleConversions.uuid($0.uuid) }
    record.characteristicUUID = BleConversions.uuid(characteristic.uuid)
    return record
  }

  func read(_ generation: Int, _ handle: Double, _ transactionId: String) async -> BytesResultRecord {
    await run(generation, BytesResultRecord.self) { [self] session, pending in
      session.begin(pending, transactionId)
      guard let (deviceId, characteristic) = characteristicAt(session, handle) else {
        pending.fail(.make("CharacteristicNotFound"))
        return
      }
      onPeripheral(session, pending, deviceId) { peripheral in
        session.waiters[deviceId, default: PeripheralWaiters()].reads[ObjectIdentifier(characteristic), default: Waiters()]
          .append(pending)
        peripheral.readValue(for: characteristic)
      }
    }
  }

  fileprivate func didUpdateValue(
    _ session: Session, _ peripheral: CBPeripheral, _ characteristic: CBCharacteristic, _ error: Error?
  ) {
    let deviceId = peripheral.identifier.uuidString
    let key = ObjectIdentifier(characteristic)
    // A read's answer goes to the read; anything else is a notification or indication.
    if let reader = session.waiters[deviceId]?.reads[key]?.pop() {
      if let error {
        reader.fail(failure("CharacteristicReadFailed", characteristic, deviceId, error))
      } else {
        reader.succeed(.success(session.generation, characteristic.value ?? Data()))
      }
      return
    }
    guard let handle = session.handle(of: characteristic) else { return }
    for (subscriptionId, monitor) in session.monitors where monitor.characteristic == handle {
      if let error {
        session.monitors[subscriptionId] = nil
        sink?.emit(notification: NotificationEventRecord(
          generation: session.generation, subscriptionId: subscriptionId, value: nil,
          error: failure("CharacteristicNotifyChangeFailed", characteristic, deviceId, error)
        ))
      } else {
        sink?.emit(notification: NotificationEventRecord(
          generation: session.generation, subscriptionId: subscriptionId, value: characteristic.value ?? Data(), error: nil
        ))
      }
    }
  }

  func write(_ generation: Int, _ handle: Double, _ value: Data, _ withResponse: Bool, _ transactionId: String) async -> VoidResultRecord {
    await run(generation, VoidResultRecord.self) { [self] session, pending in
      session.begin(pending, transactionId)
      guard let (deviceId, characteristic) = characteristicAt(session, handle) else {
        pending.fail(.make("CharacteristicNotFound"))
        return
      }
      onPeripheral(session, pending, deviceId) { peripheral in
        if withResponse {
          session.waiters[deviceId, default: PeripheralWaiters()].writes[ObjectIdentifier(characteristic), default: Waiters()]
            .append(pending)
          peripheral.writeValue(value, for: characteristic, type: .withResponse)
        } else if session.waiters[deviceId]?.unsent.isEmpty ?? true, peripheral.canSendWriteWithoutResponse {
          peripheral.writeValue(value, for: characteristic, type: .withoutResponse)
          pending.succeed(.ok(generation))
        } else {
          // Backpressure: wait for CoreBluetooth's queue to have room, in order.
          session.waiters[deviceId, default: PeripheralWaiters()].unsent.append((pending, characteristic, value))
        }
      }
    }
  }

  fileprivate func readyToWrite(_ session: Session, _ peripheral: CBPeripheral) {
    let deviceId = peripheral.identifier.uuidString
    while peripheral.canSendWriteWithoutResponse, let next = session.waiters[deviceId]?.unsent.first {
      session.waiters[deviceId]?.unsent.removeFirst()
      guard !next.pending.settled else { continue }
      peripheral.writeValue(next.value, for: next.characteristic, type: .withoutResponse)
      next.pending.succeed(.ok(session.generation))
    }
  }

  fileprivate func didWrite(_ session: Session, _ peripheral: CBPeripheral, _ characteristic: CBCharacteristic, _ error: Error?) {
    let deviceId = peripheral.identifier.uuidString
    guard let writer = session.waiters[deviceId]?.writes[ObjectIdentifier(characteristic)]?.pop() else { return }
    if let error {
      writer.fail(failure("CharacteristicWriteFailed", characteristic, deviceId, error))
    } else {
      writer.succeed(.ok(session.generation))
    }
  }

  func readDescriptor(_ generation: Int, _ handle: Double, _ transactionId: String) async -> BytesResultRecord {
    await run(generation, BytesResultRecord.self) { [self] session, pending in
      session.begin(pending, transactionId)
      guard let (deviceId, descriptor) = descriptorAt(session, handle) else {
        pending.fail(.make("DescriptorNotFound"))
        return
      }
      onPeripheral(session, pending, deviceId) { peripheral in
        session.waiters[deviceId, default: PeripheralWaiters()].descriptorReads[ObjectIdentifier(descriptor), default: Waiters()]
          .append(pending)
        peripheral.readValue(for: descriptor)
      }
    }
  }

  fileprivate func didReadDescriptor(_ session: Session, _ peripheral: CBPeripheral, _ descriptor: CBDescriptor, _ error: Error?) {
    let deviceId = peripheral.identifier.uuidString
    guard let reader = session.waiters[deviceId]?.descriptorReads[ObjectIdentifier(descriptor)]?.pop() else { return }
    if let error {
      reader.fail(BleConversions.error(error, "DescriptorReadFailed", deviceId: deviceId))
    } else if let bytes = BleConversions.descriptorValue(descriptor.value) {
      reader.succeed(.success(session.generation, bytes))
    } else {
      reader.fail(.make(
        "DescriptorReadFailed", reason: "CoreBluetooth gave this descriptor's value in no form the library knows",
        deviceId: deviceId, descriptorUUID: BleConversions.uuid(descriptor.uuid)
      ))
    }
  }

  func writeDescriptor(_ generation: Int, _ handle: Double, _ value: Data, _ transactionId: String) async -> VoidResultRecord {
    await run(generation, VoidResultRecord.self) { [self] session, pending in
      session.begin(pending, transactionId)
      guard let (deviceId, descriptor) = descriptorAt(session, handle) else {
        pending.fail(.make("DescriptorNotFound"))
        return
      }
      // CoreBluetooth refuses writes to the client configuration descriptor: subscribe instead.
      if descriptor.uuid == CBUUID(string: CBUUIDClientCharacteristicConfigurationString) {
        pending.fail(.make("DescriptorWriteNotAllowed", reason: "Use monitor to subscribe", deviceId: deviceId))
        return
      }
      onPeripheral(session, pending, deviceId) { peripheral in
        session.waiters[deviceId, default: PeripheralWaiters()].descriptorWrites[ObjectIdentifier(descriptor), default: Waiters()]
          .append(pending)
        peripheral.writeValue(value, for: descriptor)
      }
    }
  }

  fileprivate func didWriteDescriptor(_ session: Session, _ peripheral: CBPeripheral, _ descriptor: CBDescriptor, _ error: Error?) {
    let deviceId = peripheral.identifier.uuidString
    guard let writer = session.waiters[deviceId]?.descriptorWrites[ObjectIdentifier(descriptor)]?.pop() else { return }
    if let error {
      writer.fail(BleConversions.error(error, "DescriptorWriteFailed", deviceId: deviceId))
    } else {
      writer.succeed(.ok(session.generation))
    }
  }

  // MARK: Monitoring

  /// Settles when the peripheral confirms the subscription (its client configuration written; on a
  /// protected characteristic, after the pairing that write started), or fails as it refuses.
  func startMonitor(_ generation: Int, _ handle: Double, _ subscriptionId: String) async -> VoidResultRecord {
    await run(generation, VoidResultRecord.self) { [self] session, pending in
      session.monitors[subscriptionId] = nil
      guard let (deviceId, characteristic) = characteristicAt(session, handle) else {
        pending.fail(.make("CharacteristicNotFound"))
        return
      }
      onPeripheral(session, pending, deviceId) { peripheral in
        session.monitors[subscriptionId] = Monitor(deviceId: deviceId, characteristic: handle)
        let key = ObjectIdentifier(characteristic)
        let confirming = !(session.waiters[deviceId]?.notifies[key]?.isEmpty ?? true)
        if characteristic.isNotifying, !confirming {
          pending.succeed(.ok(generation))
          return
        }
        session.waiters[deviceId, default: PeripheralWaiters()].notifies[key, default: Waiters()].append(pending)
        if !confirming {
          peripheral.setNotifyValue(true, for: characteristic)
        }
      }
    }
  }

  fileprivate func didUpdateNotificationState(
    _ session: Session, _ peripheral: CBPeripheral, _ characteristic: CBCharacteristic, _ error: Error?
  ) {
    let deviceId = peripheral.identifier.uuidString
    let key = ObjectIdentifier(characteristic)
    // Every request waiting on this characteristic's subscription takes the same answer.
    var waiting: [Pending<VoidResultRecord>] = []
    while let next = session.waiters[deviceId]?.notifies[key]?.pop() {
      waiting.append(next)
    }
    guard let handle = session.handle(of: characteristic) else { return }
    if let error {
      let record = failure("CharacteristicNotifyChangeFailed", characteristic, deviceId, error)
      for (subscriptionId, monitor) in session.monitors where monitor.characteristic == handle {
        session.monitors[subscriptionId] = nil
      }
      waiting.forEach { $0.fail(record) }
      return
    }
    waiting.forEach { $0.succeed(.ok(session.generation)) }
    // A subscription ended from JavaScript while its confirmation was on the way.
    if characteristic.isNotifying, !session.monitors.values.contains(where: { $0.characteristic == handle }) {
      peripheral.setNotifyValue(false, for: characteristic)
    }
  }

  /// Cancels a transaction or a monitor by its public id. Unknown ids are already settled.
  func cancel(_ generation: Int, _ transactionId: String) async -> VoidResultRecord {
    await run(generation, VoidResultRecord.self) { [self] session, pending in
      if let monitor = session.monitors.removeValue(forKey: transactionId) {
        let others = session.monitors.values.contains { $0.characteristic == monitor.characteristic }
        if !others, let (deviceId, characteristic) = characteristicAt(session, monitor.characteristic),
          let peripheral = session.peripherals[deviceId], peripheral.state == .connected, characteristic.isNotifying
        {
          peripheral.setNotifyValue(false, for: characteristic)
        }
      } else if let id = session.transactions[transactionId], let entry = session.pending[id] {
        entry.fail(.make("OperationCancelled"))
      }
      pending.succeed(.ok(generation))
    }
  }

  // MARK: Service changes

  /// The peripheral's Service Changed: the handles under the invalidated services die, their
  /// requests and subscriptions fail, and JavaScript hears which device to discover again.
  fileprivate func servicesChanged(_ session: Session, _ peripheral: CBPeripheral, _ invalidated: [CBService]) {
    let deviceId = peripheral.identifier.uuidString
    let services = Set(invalidated.map { ObjectIdentifier($0) })
    let changed = BleErrorRecord.make("ServicesChanged", reason: "The peripheral's services changed", deviceId: deviceId)
    if var waiters = session.waiters[deviceId] {
      for service in invalidated {
        for characteristic in service.characteristics ?? [] {
          let key = ObjectIdentifier(characteristic)
          waiters.reads[key]?.failAll(changed)
          waiters.writes[key]?.failAll(changed)
          waiters.notifies[key]?.failAll(changed)
          for descriptor in characteristic.descriptors ?? [] {
            waiters.descriptorReads[ObjectIdentifier(descriptor)]?.failAll(changed)
            waiters.descriptorWrites[ObjectIdentifier(descriptor)]?.failAll(changed)
          }
        }
      }
      let unsent = waiters.unsent
      waiters.unsent = unsent.filter { item in
        guard let service = item.characteristic.service, services.contains(ObjectIdentifier(service)) else { return true }
        item.pending.fail(changed)
        return false
      }
      session.waiters[deviceId] = waiters
    }
    let dropped = Set(session.forget(deviceId, services: services))
    for (subscriptionId, monitor) in session.monitors where dropped.contains(monitor.characteristic) {
      session.monitors[subscriptionId] = nil
      sink?.emit(notification: NotificationEventRecord(
        generation: session.generation, subscriptionId: subscriptionId, value: nil, error: changed
      ))
    }
    sink?.emit(servicesChange: ServicesChangeEventRecord(generation: session.generation, deviceId: deviceId))
  }

  // MARK: Device requests

  func rssi(_ generation: Int, _ deviceId: String, _ transactionId: String) async -> PeripheralResultRecord {
    await run(generation, PeripheralResultRecord.self) { [self] session, pending in
      session.begin(pending, transactionId)
      onPeripheral(session, pending, deviceId) { peripheral in
        session.waiters[deviceId, default: PeripheralWaiters()].rssi.append(pending)
        peripheral.readRSSI()
      }
    }
  }

  fileprivate func didReadRSSI(_ session: Session, _ peripheral: CBPeripheral, _ rssi: NSNumber, _ error: Error?) {
    let deviceId = peripheral.identifier.uuidString
    guard let reader = session.waiters[deviceId]?.rssi.pop() else { return }
    if let error {
      reader.fail(BleConversions.error(error, "DeviceRSSIReadFailed", deviceId: deviceId))
    } else {
      reader.succeed(.success(session.generation, record(session, peripheral, rssi: rssi.intValue)))
    }
  }

  /// CoreBluetooth negotiates the MTU itself: this reports the payload the link takes now.
  func requestMtu(_ generation: Int, _ deviceId: String, _ mtu: Int, _ transactionId: String) async -> PeripheralResultRecord {
    await run(generation, PeripheralResultRecord.self) { [self] session, pending in
      onPeripheral(session, pending, deviceId) { peripheral in
        pending.succeed(.success(generation, record(session, peripheral)))
      }
    }
  }

  /// Connection priority is Android's; iOS reports the peripheral.
  func requestPriority(_ generation: Int, _ deviceId: String, _ priority: Int, _ transactionId: String) async -> PeripheralResultRecord {
    await run(generation, PeripheralResultRecord.self) { [self] session, pending in
      onPeripheral(session, pending, deviceId) { peripheral in
        pending.succeed(.success(generation, record(session, peripheral)))
      }
    }
  }
}
