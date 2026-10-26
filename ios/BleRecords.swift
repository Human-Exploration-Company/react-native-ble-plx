import Foundation
import ExpoModulesCore

// Concrete records mirroring src/NativeBlePlx.ts. Optional properties encode as `null`, never
// `undefined`, so every key the TypeScript contract declares is present on the JavaScript object.

// MARK: - Errors

@Record
public struct BleErrorRecord {
  public var code: String
  public var reason: String?
  public var attErrorCode: Int?
  public var iosErrorCode: Int?
  public var androidErrorCode: Int?
  public var deviceId: String?
  public var serviceUUID: String?
  public var characteristicUUID: String?
  public var descriptorUUID: String?
}

// MARK: - Inputs

@Record
public struct OpenOptionsRecord {
  public var restoreIdentifier: String?
  public var logLevel: String
}

@Record
public struct ScanOptionsRecord {
  public var services: [String]?
  public var allowDuplicates: Bool = false
  public var scanMode: Int = 0
  public var callbackType: Int = 1
  public var legacy: Bool = true
}

@Record
public struct ConnectOptionsRecord {
  public var timeoutMs: Int?
  public var autoConnect: Bool = false
  public var requestMtu: Int = 0
  public var refreshGatt: Bool = false
  public var priority: Int = 0
}

// MARK: - Snapshots

@Record
public struct PeripheralRecord {
  public var id: String
  public var name: String?
  public var rssi: Int?
  public var mtu: Int
  public var manufacturerData: Data?
  public var serviceData: [String: Data]?
  public var serviceUUIDs: [String]?
  public var localName: String?
  public var txPowerLevel: Int?
  public var solicitedServiceUUIDs: [String]?
  public var rawScanRecord: Data?
  public var isConnectable: Bool?
  public var overflowServiceUUIDs: [String]?
}

@Record
public struct ServiceRecord {
  public var deviceId: String
  public var handle: Double
  public var uuid: String
  public var isPrimary: Bool
}

@Record
public struct CharacteristicRecord {
  public var deviceId: String
  public var handle: Double
  public var uuid: String
  public var serviceHandle: Double
  public var serviceUUID: String
  public var isReadable: Bool
  public var isWritableWithResponse: Bool
  public var isWritableWithoutResponse: Bool
  public var isNotifiable: Bool
  public var isNotifying: Bool
  public var isIndicatable: Bool
  public var value: Data?
}

@Record
public struct DescriptorRecord {
  public var deviceId: String
  public var handle: Double
  public var uuid: String
  public var characteristicHandle: Double
  public var characteristicUUID: String
  public var serviceHandle: Double
  public var serviceUUID: String
  public var value: Data?
}

@Record
public struct GattTreeRecord {
  public var deviceId: String
  public var services: [ServiceRecord]
  public var characteristics: [CharacteristicRecord]
  public var descriptors: [DescriptorRecord]
}

@Record
public struct OpenInfoRecord {
  public var state: String
  public var restored: [PeripheralRecord]?
}

// MARK: - Results

@Record
public struct VoidResultRecord {
  public var generation: Int
  public var error: BleErrorRecord?
}

@Record
public struct OpenResultRecord {
  public var generation: Int
  public var error: BleErrorRecord?
  public var value: OpenInfoRecord?
}

@Record
public struct StateResultRecord {
  public var generation: Int
  public var error: BleErrorRecord?
  public var value: String?
}

@Record
public struct PeripheralResultRecord {
  public var generation: Int
  public var error: BleErrorRecord?
  public var value: PeripheralRecord?
}

@Record
public struct PeripheralListResultRecord {
  public var generation: Int
  public var error: BleErrorRecord?
  public var value: [PeripheralRecord]?
}

@Record
public struct BoolResultRecord {
  public var generation: Int
  public var error: BleErrorRecord?
  public var value: Bool?
}

@Record
public struct GattTreeResultRecord {
  public var generation: Int
  public var error: BleErrorRecord?
  public var value: GattTreeRecord?
}

@Record
public struct BytesResultRecord {
  public var generation: Int
  public var error: BleErrorRecord?
  public var value: Data?
}

@Record
public struct LogLevelResultRecord {
  public var generation: Int
  public var error: BleErrorRecord?
  public var value: String?
}

// MARK: - Events

@Record
public struct StateChangeEventRecord {
  public var generation: Int
  public var state: String
}

@Record
public struct ScanEventRecord {
  public var generation: Int
  public var scanId: String
  public var device: PeripheralRecord?
  public var error: BleErrorRecord?
}

@Record
public struct NotificationEventRecord {
  public var generation: Int
  public var subscriptionId: String
  public var value: Data?
  public var error: BleErrorRecord?
}

@Record
public struct DisconnectEventRecord {
  public var generation: Int
  public var deviceId: String
  public var error: BleErrorRecord?
}

// MARK: - Sendability

// Records cross from the adapter queue to the JavaScript thread. Public structs don't infer
// `Sendable`, so state it; every stored property is a value type.
extension BleErrorRecord: Sendable {}
extension OpenOptionsRecord: Sendable {}
extension ScanOptionsRecord: Sendable {}
extension ConnectOptionsRecord: Sendable {}
extension PeripheralRecord: Sendable {}
extension ServiceRecord: Sendable {}
extension CharacteristicRecord: Sendable {}
extension DescriptorRecord: Sendable {}
extension GattTreeRecord: Sendable {}
extension OpenInfoRecord: Sendable {}
extension StateChangeEventRecord: Sendable {}
extension ScanEventRecord: Sendable {}
extension NotificationEventRecord: Sendable {}
extension DisconnectEventRecord: Sendable {}

// MARK: - Result construction

/// A result envelope that can report a failure for its generation.
protocol BleResult: Sendable {
  static func failure(_ generation: Int, _ error: BleErrorRecord) -> Self
}

/// A result envelope carrying an optional value; the macro's memberwise initializer satisfies `init`.
protocol BleValueResult: BleResult {
  associatedtype Value
  init(generation: Int, error: BleErrorRecord?, value: Value?)
}

extension BleValueResult {
  static func failure(_ generation: Int, _ error: BleErrorRecord) -> Self {
    Self(generation: generation, error: error, value: nil)
  }

  static func success(_ generation: Int, _ value: Value) -> Self {
    Self(generation: generation, error: nil, value: value)
  }
}

extension VoidResultRecord: BleResult {
  static func failure(_ generation: Int, _ error: BleErrorRecord) -> Self {
    Self(generation: generation, error: error)
  }

  static func ok(_ generation: Int) -> Self {
    Self(generation: generation, error: nil)
  }
}

extension OpenResultRecord: BleValueResult {}
extension StateResultRecord: BleValueResult {}
extension PeripheralResultRecord: BleValueResult {}
extension PeripheralListResultRecord: BleValueResult {}
extension BoolResultRecord: BleValueResult {}
extension GattTreeResultRecord: BleValueResult {}
extension BytesResultRecord: BleValueResult {}
extension LogLevelResultRecord: BleValueResult {}

extension BleErrorRecord {
  static func make(
    _ code: String,
    reason: String? = nil,
    deviceId: String? = nil,
    serviceUUID: String? = nil,
    characteristicUUID: String? = nil,
    descriptorUUID: String? = nil
  ) -> BleErrorRecord {
    BleErrorRecord(
      code: code,
      reason: reason,
      attErrorCode: nil,
      iosErrorCode: nil,
      androidErrorCode: nil,
      deviceId: deviceId,
      serviceUUID: serviceUUID,
      characteristicUUID: characteristicUUID,
      descriptorUUID: descriptorUUID
    )
  }

  static let sessionClosed = make("SessionClosed")
}
