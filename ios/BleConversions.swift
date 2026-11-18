import CoreBluetooth
import Foundation

/// Translates CoreBluetooth's values (manager states, UUIDs, advertisement dictionaries, descriptor
/// values and `NSError`s) into the typed records. Nothing here escapes to JavaScript.
enum BleConversions {
  // MARK: State

  /// The TypeScript `BluetoothState` literal for a manager state.
  static func state(_ state: CBManagerState) -> String {
    switch state {
    case .resetting: return "Resetting"
    case .unsupported: return "Unsupported"
    case .unauthorized: return "Unauthorized"
    case .poweredOff: return "PoweredOff"
    case .poweredOn: return "PoweredOn"
    case .unknown: return "Unknown"
    @unknown default: return "Unknown"
    }
  }

  /// Why the radio cannot serve a request in `state`, or nil when it is on.
  static func unavailable(_ state: CBManagerState) -> BleErrorRecord? {
    switch state {
    case .poweredOn: return nil
    case .poweredOff: return .make("BluetoothPoweredOff")
    case .unauthorized: return .make("BluetoothUnauthorized")
    case .unsupported: return .make("BluetoothUnsupported")
    case .resetting: return .make("BluetoothResetting")
    case .unknown: return .make("BluetoothInUnknownState")
    @unknown default: return .make("BluetoothInUnknownState")
    }
  }

  // MARK: UUIDs

  private static let base = "-0000-1000-8000-00805f9b34fb"

  /// Whether CBUUID accepts `text`: 16-bit, 32-bit or 128-bit, as `CBUUID(string:)` takes them.
  static func isUUID(_ text: String) -> Bool {
    let hex = text.allSatisfy(\.isHexDigit)
    switch text.count {
    case 4, 8: return hex
    case 36: return UUID(uuidString: text) != nil
    default: return false
    }
  }

  /// A UUID as the library reports every one: 128-bit, lowercase.
  static func uuid(_ uuid: CBUUID) -> String {
    let text = uuid.uuidString.lowercased()
    switch text.count {
    case 4: return "0000\(text)\(base)"
    case 8: return "\(text)\(base)"
    default: return text
    }
  }

  // MARK: Snapshots

  /// A snapshot of what a peripheral advertised.
  static func advertised(_ id: String, _ name: String?, _ data: [String: Any], _ rssi: Int) -> PeripheralRecord {
    let uuids = { (key: String) in (data[key] as? [CBUUID])?.map(uuid) }
    let serviceData = (data[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data]).map { entries in
      Dictionary(uniqueKeysWithValues: entries.map { (uuid($0.key), $0.value) })
    }
    return PeripheralRecord(
      id: id,
      name: name,
      // CoreBluetooth reports 127 when it could not measure the signal.
      rssi: rssi == 127 ? nil : rssi,
      mtu: 23,
      manufacturerData: data[CBAdvertisementDataManufacturerDataKey] as? Data,
      serviceData: serviceData,
      serviceUUIDs: uuids(CBAdvertisementDataServiceUUIDsKey),
      localName: data[CBAdvertisementDataLocalNameKey] as? String,
      txPowerLevel: (data[CBAdvertisementDataTxPowerLevelKey] as? NSNumber)?.intValue,
      solicitedServiceUUIDs: uuids(CBAdvertisementDataSolicitedServiceUUIDsKey),
      rawScanRecord: nil,
      isConnectable: (data[CBAdvertisementDataIsConnectable] as? NSNumber)?.boolValue,
      overflowServiceUUIDs: uuids(CBAdvertisementDataOverflowServiceUUIDsKey)
    )
  }

  /// A snapshot for a peripheral seen in no advertisement: one known by identifier or restored.
  static func minimalPeripheral(_ id: String) -> PeripheralRecord {
    PeripheralRecord(
      id: id, name: nil, rssi: nil, mtu: 23, manufacturerData: nil, serviceData: nil, serviceUUIDs: nil,
      localName: nil, txPowerLevel: nil, solicitedServiceUUIDs: nil, rawScanRecord: nil, isConnectable: nil,
      overflowServiceUUIDs: nil
    )
  }

  /// A descriptor's value as bytes. CoreBluetooth decodes some descriptors itself: the client
  /// configuration and extended properties as numbers, the user description as a string.
  static func descriptorValue(_ value: Any?) -> Data? {
    switch value {
    case let data as Data:
      return data
    case let text as String:
      return Data(text.utf8)
    case let number as NSNumber:
      let raw = number.uint16Value
      return Data([UInt8(raw & 0xff), UInt8(raw >> 8)])
    default:
      return nil
    }
  }

  // MARK: Errors

  /// A CoreBluetooth failure as a record of `defaultCode`, keeping the ATT or CoreBluetooth code:
  /// an ATT error (insufficient authentication, say) is the peripheral's answer, the rest the system's.
  static func error(_ error: Error?, _ defaultCode: String, deviceId: String?) -> BleErrorRecord {
    var record = BleErrorRecord.make(defaultCode, deviceId: deviceId)
    guard let error else {
      return record
    }
    let ns = error as NSError
    record.reason = ns.localizedDescription
    switch ns.domain {
    case CBATTErrorDomain:
      record.attErrorCode = ns.code
    case CBErrorDomain:
      record.iosErrorCode = ns.code
      if ns.code == CBError.operationCancelled.rawValue {
        record.code = "OperationCancelled"
      } else if ns.code == CBError.connectionTimeout.rawValue, defaultCode == "DeviceConnectionFailed" {
        record.code = "OperationTimedOut"
      }
    default:
      break
    }
    return record
  }
}
