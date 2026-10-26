import Foundation
@preconcurrency import MultiplatformBleAdapter
import os

// Threading model
//
// Every piece of mutable state below is confined to `BleEngine.queue`, which is also the queue the
// adapter and its CBCentralManager run on, so adapter callbacks and delegate events arrive on it.
// `@JS` methods start on the JavaScript thread, dispatch onto the queue and suspend on a
// continuation. `JavaScriptActor` does not hop threads, so after the continuation resumes, the
// generated binding keeps running on this queue until it encodes the result on the JavaScript
// thread; no code here touches state after resuming.
//
// Identity
//
// Each session has a generation. Requests carry the generation they were issued for; events and
// results carry the session's. Adapter transaction ids are minted per request ("t<gen>.<serial>",
// "m<gen>.<serial>"), so a reused public id can never reach the adapter or settle a newer request.
// Each connection attempt has a token; a callback or disconnection from an attempt that is no longer
// current is dropped.

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
  var adapterTransaction: String? { get }
  func fail(_ error: BleErrorRecord)
}

/// One in-flight request. Settling removes it from its session's registry, so a late adapter
/// callback finds nothing to settle.
final class Pending<R: BleResult>: PendingEntry, @unchecked Sendable {
  let id: UInt64
  let generation: Int
  private let once: Once<R>
  private weak var session: Session?
  var publicTransaction: String?
  var adapterTransaction: String?

  init(id: UInt64, generation: Int, once: Once<R>, session: Session) {
    self.id = id
    self.generation = generation
    self.once = once
    self.session = session
  }

  func succeed(_ result: R) {
    session?.unregister(self)
    once.resume(result)
  }

  func fail(_ error: BleErrorRecord) {
    session?.unregister(self)
    once.resume(R.failure(generation, error))
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
}

struct Monitor {
  let adapterTransaction: String
  let deviceId: String?
}

final class OpenWaiter {
  let once: Once<OpenResultRecord>
  init(_ once: Once<OpenResultRecord>) { self.once = once }
}

final class Session: @unchecked Sendable {
  let generation: Int
  let adapter: BleAdapter
  let delegate: AdapterDelegate

  var pending: [UInt64: PendingEntry] = [:]
  /// Public transaction id to the pending request currently using it.
  var transactions: [String: UInt64] = [:]
  var connections: [String: Connection] = [:]
  /// Public subscription id to its monitor, and the adapter transaction back to the subscription id.
  var monitors: [String: Monitor] = [:]
  var monitorTransactions: [String: String] = [:]
  /// Characteristic handle to device id, learned from discovery, so monitors end with their device.
  var handleDevices: [Double: String] = [:]
  var scanId: String?
  var openWaiter: OpenWaiter?
  private var serial: UInt64 = 0

  init(generation: Int, adapter: BleAdapter, delegate: AdapterDelegate) {
    self.generation = generation
    self.adapter = adapter
    self.delegate = delegate
  }

  func nextSerial() -> UInt64 {
    serial &+= 1
    return serial
  }

  func register<R: BleResult>(_ once: Once<R>) -> Pending<R> {
    let entry = Pending(id: nextSerial(), generation: generation, once: once, session: self)
    pending[entry.id] = entry
    return entry
  }

  /// Binds a public transaction id to `entry` and returns the adapter transaction id to use. A
  /// request still holding the same public id is cancelled first.
  func begin<R: BleResult>(_ entry: Pending<R>, _ publicTransaction: String) -> String {
    if let previous = transactions[publicTransaction], let stale = pending[previous] {
      stale.fail(.make("OperationCancelled"))
      if let adapterTransaction = stale.adapterTransaction {
        adapter.cancelTransaction(adapterTransaction)
      }
    }
    let adapterTransaction = "t\(generation).\(nextSerial())"
    entry.publicTransaction = publicTransaction
    entry.adapterTransaction = adapterTransaction
    transactions[publicTransaction] = entry.id
    return adapterTransaction
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

  func removeMonitor(_ subscriptionId: String) -> Monitor? {
    guard let monitor = monitors.removeValue(forKey: subscriptionId) else {
      return nil
    }
    monitorTransactions[monitor.adapterTransaction] = nil
    return monitor
  }
}

// MARK: - Delegate and event sink

/// The adapter retains its delegate strongly, so this NSObject holds the engine weakly and stamps
/// events with the generation of the adapter that produced them.
final class AdapterDelegate: NSObject, BleClientManagerDelegate {
  private weak var engine: BleEngine?
  private let generation: Int

  init(engine: BleEngine, generation: Int) {
    self.engine = engine
    self.generation = generation
  }

  func dispatchEvent(_ name: String, value: Any) {
    engine?.adapterEvent(generation: generation, name: name, value: value)
  }
}

protocol BleEventSink: AnyObject {
  func emit(stateChange event: StateChangeEventRecord)
  func emit(scan event: ScanEventRecord)
  func emit(notification event: NotificationEventRecord)
  func emit(disconnect event: DisconnectEventRecord)
}

private final class SinkBox: @unchecked Sendable {
  private let lock = OSAllocatedUnfairLock()
  private weak var value: BleEventSink?

  var sink: BleEventSink? {
    get { lock.withLockUnchecked { value } }
    set { lock.withLockUnchecked { value = newValue } }
  }
}

/// Carries a closure onto the serial queue that confines all of its state.
private struct QueueConfined: @unchecked Sendable {
  let body: () -> Void
  init(_ body: @escaping () -> Void) { self.body = body }
}

// MARK: - Engine

final class BleEngine: @unchecked Sendable {
  private static let queueKey = DispatchSpecificKey<Void>()

  private let queue: DispatchQueue
  private let sinkBox = SinkBox()
  private var session: Session?
  private var lastGeneration = 0
  private var lastConnectionToken: UInt64 = 0

  init() {
    queue = DispatchQueue(label: "com.bleplx.adapter", qos: .userInitiated)
    queue.setSpecific(key: Self.queueKey, value: ())
  }

  func attach(_ sink: BleEventSink) {
    sinkBox.sink = sink
  }

  /// Runs `body` on the queue: inline when already there, as adapter callbacks normally are.
  private func confined(_ body: @escaping () -> Void) {
    if DispatchQueue.getSpecific(key: Self.queueKey) != nil {
      body()
    } else {
      // The closure only ever runs on this queue, which confines everything it touches.
      let confinedBody = QueueConfined(body)
      queue.async { confinedBody.body() }
    }
  }

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

  private func reject<R: BleResult>(_ pending: Pending<R>) -> Reject {
    { [weak self] _, message, _ in
      self?.confined { pending.fail(BleConversions.error(message)) }
    }
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
        let delegate = AdapterDelegate(engine: self, generation: generation)
        let adapter = BleAdapterFactory.getNewAdapterWithQueue(queue, restoreIdentifierKey: options.restoreIdentifier)
        let session = Session(generation: generation, adapter: adapter, delegate: delegate)
        self.session = session
        adapter.setLogLevel(options.logLevel)
        adapter.delegate = delegate

        guard options.restoreIdentifier != nil else {
          once.resume(.success(generation, OpenInfoRecord(state: currentState(session), restored: nil)))
          return
        }
        // The adapter reports restoration, or its absence, exactly once: on willRestoreState or on
        // the first didUpdateState, which CoreBluetooth always delivers after creating the manager
        // (MultiplatformBleAdapter 0.2.0: amb(rx_state.skip(1), listenOnRestoredState()).take(1)).
        // Hold the result until then so restored peripherals reach JavaScript with the session.
        // Only teardown settles the waiter otherwise.
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
    // Settle first: invalidation disposes adapter transactions, whose callbacks then find nothing.
    for entry in Array(session.pending.values) {
      entry.fail(.sessionClosed)
    }
    session.monitors.removeAll()
    session.monitorTransactions.removeAll()
    session.connections.removeAll()
    session.handleDevices.removeAll()
    session.scanId = nil
    session.adapter.invalidate()
    session.adapter.delegate = nil
  }

  private func finishOpen(_ session: Session, restored: [PeripheralRecord]?) {
    guard let waiter = session.openWaiter else {
      return
    }
    session.openWaiter = nil
    for device in restored ?? [] {
      session.connections[device.id] = Connection(token: nextConnectionToken(), phase: .connected)
    }
    waiter.once.resume(.success(session.generation, OpenInfoRecord(state: currentState(session), restored: restored)))
  }

  private func currentState(_ session: Session) -> String {
    var state = "Unknown"
    session.adapter.state({ value in
      state = BleConversions.string(value) ?? "Unknown"
    }, reject: { _, _, _ in })
    return state
  }

  private func nextConnectionToken() -> UInt64 {
    lastConnectionToken &+= 1
    return lastConnectionToken
  }

  // MARK: State and logging

  func state(_ generation: Int) async -> StateResultRecord {
    await run(generation, StateResultRecord.self) { [self] session, pending in
      pending.succeed(.success(generation, currentState(session)))
    }
  }

  func setLogLevel(_ generation: Int, _ level: String) async -> VoidResultRecord {
    await run(generation, VoidResultRecord.self) { session, pending in
      session.adapter.setLogLevel(level)
      pending.succeed(.ok(generation))
    }
  }

  func logLevel(_ generation: Int) async -> LogLevelResultRecord {
    await run(generation, LogLevelResultRecord.self) { [self] session, pending in
      session.adapter.logLevel({ value in
        pending.succeed(.success(generation, BleConversions.string(value) ?? "None"))
      }, reject: reject(pending))
    }
  }

  // MARK: Scanning

  func startScan(_ generation: Int, _ scanId: String, _ options: ScanOptionsRecord) async -> VoidResultRecord {
    await run(generation, VoidResultRecord.self) { session, pending in
      if session.scanId != nil {
        session.adapter.stopDeviceScan()
      }
      // Set before starting: an invalid filter is reported synchronously as a scan event.
      session.scanId = scanId
      let scanOptions: [String: AnyObject] = ["allowDuplicates": NSNumber(value: options.allowDuplicates)]
      session.adapter.startDeviceScan(options.services, options: scanOptions)
      pending.succeed(.ok(generation))
    }
  }

  func stopScan(_ generation: Int, _ scanId: String) async -> VoidResultRecord {
    await run(generation, VoidResultRecord.self) { session, pending in
      if session.scanId == scanId {
        session.scanId = nil
        session.adapter.stopDeviceScan()
      }
      pending.succeed(.ok(generation))
    }
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
      let token = nextConnectionToken()
      session.connections[deviceId] = Connection(token: token, phase: .connecting)
      var connectOptions: [String: AnyObject] = [:]
      if let timeout = options.timeoutMs {
        connectOptions["timeout"] = NSNumber(value: timeout)
      }
      session.adapter.connectToDevice(
        deviceId,
        options: connectOptions,
        resolve: { [weak self, weak session] value in
          self?.confined {
            guard let session, session.connections[deviceId]?.token == token else {
              pending.fail(.make("OperationCancelled", deviceId: deviceId))
              return
            }
            session.connections[deviceId]?.phase = .connected
            pending.succeed(.success(generation, BleConversions.peripheral(value) ?? BleConversions.minimalPeripheral(deviceId)))
          }
        },
        reject: { [weak self, weak session] _, message, _ in
          self?.confined {
            if let session, session.connections[deviceId]?.token == token {
              session.connections[deviceId] = nil
            }
            pending.fail(BleConversions.error(message))
          }
        }
      )
    }
  }

  func cancelConnection(_ generation: Int, _ deviceId: String) async -> PeripheralResultRecord {
    await run(generation, PeripheralResultRecord.self) { [self] session, pending in
      guard let connection = session.connections[deviceId] else {
        // Not tracked by this session: let the adapter decide, and report its "nothing to cancel"
        // rejection as "not connected".
        session.adapter.cancelDeviceConnection(deviceId, resolve: { [weak self] value in
          self?.confined {
            pending.succeed(.success(generation, BleConversions.peripheral(value) ?? BleConversions.minimalPeripheral(deviceId)))
          }
        }, reject: { [weak self] _, message, _ in
          self?.confined {
            let error = BleConversions.error(message)
            pending.fail(error.code == "OperationCancelled" ? .make("DeviceNotConnected", deviceId: deviceId) : error)
          }
        })
        return
      }
      switch connection.phase {
      case .cancelling:
        pending.fail(.make("OperationStartFailed", reason: "The connection is already being cancelled", deviceId: deviceId))
      case .connecting:
        // Abandon the attempt. Its own callbacks settle the connect request as cancelled; the
        // adapter then rejects this cancel as "cancelled", which here means success.
        session.connections[deviceId] = nil
        session.adapter.cancelDeviceConnection(deviceId, resolve: { [weak self] value in
          self?.confined {
            pending.succeed(.success(generation, BleConversions.peripheral(value) ?? BleConversions.minimalPeripheral(deviceId)))
          }
        }, reject: { [weak self] _, _, _ in
          self?.confined { pending.succeed(.success(generation, BleConversions.minimalPeripheral(deviceId))) }
        })
      case .connected:
        let token = connection.token
        session.connections[deviceId]?.phase = .cancelling
        session.adapter.cancelDeviceConnection(deviceId, resolve: { [weak self, weak session] value in
          self?.confined {
            if let engine = self, let session, session.connections[deviceId]?.token == token {
              // The adapter's disconnection event may not have arrived; report it exactly once.
              engine.disconnected(session, deviceId: deviceId, error: nil)
            }
            pending.succeed(.success(generation, BleConversions.peripheral(value) ?? BleConversions.minimalPeripheral(deviceId)))
          }
        }, reject: { [weak self, weak session] _, message, _ in
          self?.confined {
            if let session, session.connections[deviceId]?.token == token {
              session.connections[deviceId]?.phase = .connected
            }
            pending.fail(BleConversions.error(message))
          }
        })
      }
    }
  }

  func isConnected(_ generation: Int, _ deviceId: String) async -> BoolResultRecord {
    await run(generation, BoolResultRecord.self) { [self] session, pending in
      session.adapter.isDeviceConnected(deviceId, resolve: { value in
        pending.succeed(.success(generation, BleConversions.bool(value) ?? false))
      }, reject: reject(pending))
    }
  }

  func known(_ generation: Int, _ deviceIds: [String]) async -> PeripheralListResultRecord {
    await run(generation, PeripheralListResultRecord.self) { [self] session, pending in
      session.adapter.devices(deviceIds, resolve: { [weak self] value in
        self?.confined { self?.settleList(pending, generation, value) }
      }, reject: reject(pending))
    }
  }

  func connected(_ generation: Int, _ services: [String]) async -> PeripheralListResultRecord {
    await run(generation, PeripheralListResultRecord.self) { [self] session, pending in
      session.adapter.connectedDevices(services, resolve: { [weak self] value in
        self?.confined { self?.settleList(pending, generation, value) }
      }, reject: reject(pending))
    }
  }

  private func settleList(_ pending: Pending<PeripheralListResultRecord>, _ generation: Int, _ value: Any?) {
    if let devices = BleConversions.peripherals(value) {
      pending.succeed(.success(generation, devices))
    } else {
      pending.fail(.make("InvalidNativeResult"))
    }
  }

  // MARK: Discovery

  func discover(_ generation: Int, _ deviceId: String, _ transactionId: String) async -> GattTreeResultRecord {
    await run(generation, GattTreeResultRecord.self) { [self] session, pending in
      guard let connection = session.connections[deviceId], connection.phase == .connected else {
        pending.fail(.make("DeviceNotConnected", deviceId: deviceId))
        return
      }
      let transaction = session.begin(pending, transactionId)
      session.adapter.discoverAllServicesAndCharacteristicsForDevice(
        deviceId,
        transactionId: transaction,
        resolve: { [weak self, weak session] _ in
          self?.confined {
            guard let engine = self, let session, session.connections[deviceId]?.token == connection.token else {
              pending.fail(.make("DeviceDisconnected", deviceId: deviceId))
              return
            }
            switch engine.gattTree(session, deviceId) {
            case let .success(tree): pending.succeed(.success(generation, tree))
            case let .failure(error): pending.fail(error.record)
            }
          }
        },
        reject: reject(pending)
      )
    }
  }

  private struct TreeError: Error {
    let record: BleErrorRecord
  }

  /// Reads the adapter's caches after discovery. These getters call back synchronously.
  private func gattTree(_ session: Session, _ deviceId: String) -> Result<GattTreeRecord, TreeError> {
    var failure: BleErrorRecord?
    var services: [ServiceRecord] = []
    var characteristics: [CharacteristicRecord] = []
    var descriptors: [DescriptorRecord] = []
    let invalid = BleErrorRecord.make("InvalidNativeResult", deviceId: deviceId)

    session.adapter.servicesForDevice(deviceId, resolve: { value in
      if let converted = BleConversions.list(value, BleConversions.service) {
        services = converted
      } else {
        failure = failure ?? invalid
      }
    }, reject: { _, message, _ in failure = failure ?? BleConversions.error(message) })
    for service in services {
      session.adapter.characteristicsForService(service.handle, resolve: { value in
        if let converted = BleConversions.list(value, BleConversions.characteristic) {
          characteristics.append(contentsOf: converted)
        } else {
          failure = failure ?? invalid
        }
      }, reject: { _, message, _ in failure = failure ?? BleConversions.error(message) })
    }
    for characteristic in characteristics {
      session.handleDevices[characteristic.handle] = deviceId
      session.adapter.descriptorsForCharacteristic(characteristic.handle, resolve: { value in
        if let converted = BleConversions.list(value, BleConversions.descriptor) {
          descriptors.append(contentsOf: converted)
        } else {
          failure = failure ?? invalid
        }
      }, reject: { _, message, _ in failure = failure ?? BleConversions.error(message) })
    }
    if let failure {
      return .failure(TreeError(record: failure))
    }
    return .success(GattTreeRecord(deviceId: deviceId, services: services, characteristics: characteristics, descriptors: descriptors))
  }

  // MARK: GATT operations

  func read(_ generation: Int, _ handle: Double, _ transactionId: String) async -> BytesResultRecord {
    await run(generation, BytesResultRecord.self) { [self] session, pending in
      let transaction = session.begin(pending, transactionId)
      session.adapter.readCharacteristic(handle, transactionId: transaction, resolve: { [weak self] value in
        self?.confined {
          let characteristic = BleConversions.dictionary(value)
          pending.succeed(.success(generation, BleConversions.bytes(characteristic?["value"]) ?? Data()))
        }
      }, reject: reject(pending))
    }
  }

  func write(_ generation: Int, _ handle: Double, _ value: Data, _ withResponse: Bool, _ transactionId: String) async -> VoidResultRecord {
    await run(generation, VoidResultRecord.self) { [self] session, pending in
      let transaction = session.begin(pending, transactionId)
      session.adapter.writeCharacteristic(
        handle, valueBase64: value.base64EncodedString(), response: withResponse, transactionId: transaction,
        resolve: { [weak self] _ in self?.confined { pending.succeed(.ok(generation)) } },
        reject: reject(pending)
      )
    }
  }

  func readDescriptor(_ generation: Int, _ handle: Double, _ transactionId: String) async -> BytesResultRecord {
    await run(generation, BytesResultRecord.self) { [self] session, pending in
      let transaction = session.begin(pending, transactionId)
      session.adapter.readDescriptor(handle, transactionId: transaction, resolve: { [weak self] value in
        self?.confined {
          let descriptor = BleConversions.dictionary(value)
          if let bytes = BleConversions.bytes(descriptor?["value"]) {
            pending.succeed(.success(generation, bytes))
          } else {
            // The adapter only encodes values of the standard GATT descriptors it recognizes.
            pending.fail(.make(
              "DescriptorReadFailed",
              reason: "The iOS adapter cannot represent this descriptor's value",
              deviceId: BleConversions.string(descriptor?["deviceID"]),
              serviceUUID: BleConversions.string(descriptor?["serviceUUID"]),
              characteristicUUID: BleConversions.string(descriptor?["characteristicUUID"]),
              descriptorUUID: BleConversions.string(descriptor?["uuid"])
            ))
          }
        }
      }, reject: reject(pending))
    }
  }

  func writeDescriptor(_ generation: Int, _ handle: Double, _ value: Data, _ transactionId: String) async -> VoidResultRecord {
    await run(generation, VoidResultRecord.self) { [self] session, pending in
      let transaction = session.begin(pending, transactionId)
      session.adapter.writeDescriptor(
        handle, valueBase64: value.base64EncodedString(), transactionId: transaction,
        resolve: { [weak self] _ in self?.confined { pending.succeed(.ok(generation)) } },
        reject: reject(pending)
      )
    }
  }

  // MARK: Monitoring

  func startMonitor(_ generation: Int, _ handle: Double, _ subscriptionId: String) async -> VoidResultRecord {
    await run(generation, VoidResultRecord.self) { [self] session, pending in
      if let previous = session.removeMonitor(subscriptionId) {
        session.adapter.cancelTransaction(previous.adapterTransaction)
      }
      let transaction = "m\(generation).\(session.nextSerial())"
      session.monitors[subscriptionId] = Monitor(adapterTransaction: transaction, deviceId: session.handleDevices[handle])
      session.monitorTransactions[transaction] = subscriptionId
      // The adapter never resolves a monitor; it rejects only when the subscription is disposed.
      session.adapter.monitorCharacteristic(handle, transactionId: transaction, resolve: { _ in }, reject: { [weak self, weak session] _, message, _ in
        self?.confined {
          guard let engine = self, let session, session.monitorTransactions[transaction] == subscriptionId else {
            return
          }
          _ = session.removeMonitor(subscriptionId)
          engine.sinkBox.sink?.emit(notification: NotificationEventRecord(
            generation: session.generation, subscriptionId: subscriptionId, value: nil, error: BleConversions.error(message)
          ))
        }
      })
      pending.succeed(.ok(generation))
    }
  }

  /// Cancels a transaction or a monitor by its public id. Unknown ids are already settled.
  func cancel(_ generation: Int, _ transactionId: String) async -> VoidResultRecord {
    await run(generation, VoidResultRecord.self) { session, pending in
      if let monitor = session.removeMonitor(transactionId) {
        session.adapter.cancelTransaction(monitor.adapterTransaction)
      } else if let id = session.transactions[transactionId], let entry = session.pending[id] {
        let adapterTransaction = entry.adapterTransaction
        entry.fail(.make("OperationCancelled"))
        if let adapterTransaction {
          session.adapter.cancelTransaction(adapterTransaction)
        }
      }
      pending.succeed(.ok(generation))
    }
  }

  // MARK: Device requests

  func rssi(_ generation: Int, _ deviceId: String, _ transactionId: String) async -> PeripheralResultRecord {
    await run(generation, PeripheralResultRecord.self) { [self] session, pending in
      let transaction = session.begin(pending, transactionId)
      session.adapter.readRSSIForDevice(deviceId, transactionId: transaction, resolve: peripheralResolve(pending, generation, deviceId), reject: reject(pending))
    }
  }

  func requestMtu(_ generation: Int, _ deviceId: String, _ mtu: Int, _ transactionId: String) async -> PeripheralResultRecord {
    await run(generation, PeripheralResultRecord.self) { [self] session, pending in
      let transaction = session.begin(pending, transactionId)
      session.adapter.requestMTUForDevice(deviceId, mtu: mtu, transactionId: transaction, resolve: peripheralResolve(pending, generation, deviceId), reject: reject(pending))
    }
  }

  func requestPriority(_ generation: Int, _ deviceId: String, _ priority: Int, _ transactionId: String) async -> PeripheralResultRecord {
    await run(generation, PeripheralResultRecord.self) { [self] session, pending in
      let transaction = session.begin(pending, transactionId)
      session.adapter.requestConnectionPriorityForDevice(
        deviceId, connectionPriority: priority, transactionId: transaction,
        resolve: peripheralResolve(pending, generation, deviceId), reject: reject(pending)
      )
    }
  }

  private func peripheralResolve(_ pending: Pending<PeripheralResultRecord>, _ generation: Int, _ deviceId: String) -> Resolve {
    { [weak self] value in
      self?.confined {
        pending.succeed(.success(generation, BleConversions.peripheral(value) ?? BleConversions.minimalPeripheral(deviceId)))
      }
    }
  }

  // MARK: Adapter events

  func adapterEvent(generation: Int, name: String, value: Any) {
    confined { [self] in
      guard let session, session.generation == generation else {
        return
      }
      switch name {
      case BleEvent.stateChangeEvent:
        if let state = BleConversions.string(value) {
          sinkBox.sink?.emit(stateChange: StateChangeEventRecord(generation: generation, state: state))
        }
      case BleEvent.restoreStateEvent:
        let restored = BleConversions.dictionary(value).map { BleConversions.peripherals($0["connectedPeripherals"]) ?? [] }
        finishOpen(session, restored: restored)
      case BleEvent.scanEvent:
        handleScan(session, value)
      case BleEvent.readEvent:
        handleNotification(session, value)
      case BleEvent.disconnectionEvent:
        guard let items = value as? [Any], items.count >= 2,
          let deviceId = BleConversions.string(BleConversions.dictionary(items[1])?["id"])
        else {
          return
        }
        let error = BleConversions.string(items[0]).map { BleConversions.error($0) }
        switch session.connections[deviceId]?.phase {
        case .connected, .cancelling:
          disconnected(session, deviceId: deviceId, error: error)
        case .connecting, nil:
          // Either a superseded attempt or the failure of the current attempt, which its connect
          // result reports. Neither ends a connection JavaScript holds.
          break
        }
      default:
        break
      }
    }
  }

  private func disconnected(_ session: Session, deviceId: String, error: BleErrorRecord?) {
    session.connections[deviceId] = nil
    var ended: [String] = []
    for (subscriptionId, monitor) in session.monitors where monitor.deviceId == deviceId {
      _ = session.removeMonitor(subscriptionId)
      ended.append(monitor.adapterTransaction)
    }
    if !ended.isEmpty {
      // This runs inside an adapter callback; dispose the adapter's monitors on a later turn of the
      // queue rather than re-entering its transaction map while it is still dispatching.
      let release = QueueConfined { [weak session] in
        guard let session else { return }
        ended.forEach(session.adapter.cancelTransaction)
      }
      queue.async { release.body() }
    }
    sinkBox.sink?.emit(disconnect: DisconnectEventRecord(generation: session.generation, deviceId: deviceId, error: error))
  }

  private func handleScan(_ session: Session, _ value: Any) {
    guard let scanId = session.scanId, let items = value as? [Any], items.count >= 2 else {
      return
    }
    if let message = BleConversions.string(items[0]) {
      // A scan error ends the adapter's scan.
      session.scanId = nil
      sinkBox.sink?.emit(scan: ScanEventRecord(generation: session.generation, scanId: scanId, device: nil, error: BleConversions.error(message)))
    } else if let device = BleConversions.peripheral(items[1]) {
      sinkBox.sink?.emit(scan: ScanEventRecord(generation: session.generation, scanId: scanId, device: device, error: nil))
    }
  }

  private func handleNotification(_ session: Session, _ value: Any) {
    guard let items = value as? [Any], items.count >= 3,
      let transaction = BleConversions.string(items[2]),
      let subscriptionId = session.monitorTransactions[transaction]
    else {
      return
    }
    if let message = BleConversions.string(items[0]) {
      _ = session.removeMonitor(subscriptionId)
      sinkBox.sink?.emit(notification: NotificationEventRecord(
        generation: session.generation, subscriptionId: subscriptionId, value: nil, error: BleConversions.error(message)
      ))
    } else if let characteristic = BleConversions.dictionary(items[1]) {
      sinkBox.sink?.emit(notification: NotificationEventRecord(
        generation: session.generation, subscriptionId: subscriptionId,
        value: BleConversions.bytes(characteristic["value"]) ?? Data(), error: nil
      ))
    }
  }
}
