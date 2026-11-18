import ExpoModulesCore
import Foundation

/// The Expo Modules 2.0 binding for src/NativeBlePlx.ts. Each `@JS` method starts on the JavaScript
/// thread, hands its work to the engine's serial CoreBluetooth queue and returns a result record; BLE
/// failures travel inside the record, so the returned promises never reject for radio errors.
@ExpoModule("BlePlx")
public final class BlePlxModule: Module {
  private let engine = BleEngine()

  @Event
  var onStateChange: (StateChangeEventRecord) -> Void

  @Event
  var onScan: (ScanEventRecord) -> Void

  @Event
  var onNotification: (NotificationEventRecord) -> Void

  @Event
  var onDisconnect: (DisconnectEventRecord) -> Void

  /// A peripheral's Service Changed: its handles under the changed services are gone.
  @Event
  var onServicesChange: (ServicesChangeEventRecord) -> Void

  public override func willDestroy() {
    engine.destroy()
  }

  // MARK: Session

  @JS
  func open(_ options: OpenOptionsRecord) async -> OpenResultRecord {
    engine.attach(self)
    return await engine.open(options)
  }

  @JS
  func close(_ generation: Int) async -> VoidResultRecord {
    await engine.close(generation)
  }

  @JS
  func state(_ generation: Int) async -> StateResultRecord {
    await engine.state(generation)
  }

  @JS
  func setLogLevel(_ generation: Int, _ level: String) async -> VoidResultRecord {
    await engine.setLogLevel(generation, level)
  }

  @JS
  func logLevel(_ generation: Int) async -> LogLevelResultRecord {
    await engine.logLevel(generation)
  }

  // MARK: Scanning

  @JS
  func startScan(_ generation: Int, _ scanId: String, _ options: ScanOptionsRecord) async -> VoidResultRecord {
    await engine.startScan(generation, scanId, options)
  }

  @JS
  func stopScan(_ generation: Int, _ scanId: String) async -> VoidResultRecord {
    await engine.stopScan(generation, scanId)
  }

  // MARK: Connections

  @JS
  func connect(_ generation: Int, _ deviceId: String, _ options: ConnectOptionsRecord) async -> PeripheralResultRecord {
    await engine.connect(generation, deviceId, options)
  }

  @JS
  func cancelConnection(_ generation: Int, _ deviceId: String) async -> PeripheralResultRecord {
    await engine.cancelConnection(generation, deviceId)
  }

  @JS
  func isConnected(_ generation: Int, _ deviceId: String) async -> BoolResultRecord {
    await engine.isConnected(generation, deviceId)
  }

  @JS
  func known(_ generation: Int, _ deviceIds: [String]) async -> PeripheralListResultRecord {
    await engine.known(generation, deviceIds)
  }

  @JS
  func connected(_ generation: Int, _ services: [String]) async -> PeripheralListResultRecord {
    await engine.connected(generation, services)
  }

  // MARK: GATT

  @JS
  func discover(_ generation: Int, _ deviceId: String, _ transactionId: String) async -> GattTreeResultRecord {
    await engine.discover(generation, deviceId, transactionId)
  }

  @JS
  func read(_ generation: Int, _ handle: Double, _ transactionId: String) async -> BytesResultRecord {
    await engine.read(generation, handle, transactionId)
  }

  @JS
  func write(
    _ generation: Int, _ handle: Double, _ value: Data, _ withResponse: Bool, _ transactionId: String
  ) async -> VoidResultRecord {
    await engine.write(generation, handle, value, withResponse, transactionId)
  }

  @JS
  func readDescriptor(_ generation: Int, _ handle: Double, _ transactionId: String) async -> BytesResultRecord {
    await engine.readDescriptor(generation, handle, transactionId)
  }

  @JS
  func writeDescriptor(_ generation: Int, _ handle: Double, _ value: Data, _ transactionId: String) async -> VoidResultRecord {
    await engine.writeDescriptor(generation, handle, value, transactionId)
  }

  /// `subscriptionType` selects notification or indication on Android; CoreBluetooth chooses itself.
  @JS
  func startMonitor(
    _ generation: Int, _ handle: Double, _ subscriptionId: String, _ subscriptionType: String?
  ) async -> VoidResultRecord {
    await engine.startMonitor(generation, handle, subscriptionId)
  }

  @JS
  func cancel(_ generation: Int, _ transactionId: String) async -> VoidResultRecord {
    await engine.cancel(generation, transactionId)
  }

  // MARK: Device requests

  @JS
  func rssi(_ generation: Int, _ deviceId: String, _ transactionId: String) async -> PeripheralResultRecord {
    await engine.rssi(generation, deviceId, transactionId)
  }

  /// CoreBluetooth negotiates the MTU itself; this reports the current value.
  @JS
  func requestMtu(_ generation: Int, _ deviceId: String, _ mtu: Int, _ transactionId: String) async -> PeripheralResultRecord {
    await engine.requestMtu(generation, deviceId, mtu, transactionId)
  }

  /// Connection priority is Android-only; iOS reports the current peripheral.
  @JS
  func requestPriority(_ generation: Int, _ deviceId: String, _ priority: Int, _ transactionId: String) async -> PeripheralResultRecord {
    await engine.requestPriority(generation, deviceId, priority, transactionId)
  }
}

// Events are emitted from the CoreBluetooth queue; the default `@Event` schedules onto the JS thread.
extension BlePlxModule: BleEventSink {
  func emit(stateChange event: StateChangeEventRecord) { onStateChange(event) }
  func emit(scan event: ScanEventRecord) { onScan(event) }
  func emit(notification event: NotificationEventRecord) { onNotification(event) }
  func emit(disconnect event: DisconnectEventRecord) { onDisconnect(event) }
  func emit(servicesChange event: ServicesChangeEventRecord) { onServicesChange(event) }
}
