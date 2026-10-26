import Foundation

/// Translates MultiplatformBleAdapter's untyped values (dictionaries, Base64 strings and the JSON
/// error strings it passes to `reject`) into the typed records. Nothing here escapes to JavaScript.
enum BleConversions {
  // MARK: Scalars

  static func dictionary(_ value: Any?) -> [String: Any]? {
    value as? [String: Any]
  }

  static func string(_ value: Any?) -> String? {
    value as? String
  }

  static func int(_ value: Any?) -> Int? {
    (value as? NSNumber)?.intValue
  }

  static func double(_ value: Any?) -> Double? {
    (value as? NSNumber)?.doubleValue
  }

  static func bool(_ value: Any?) -> Bool? {
    value as? Bool
  }

  static func strings(_ value: Any?) -> [String]? {
    value as? [String]
  }

  static func bytes(_ value: Any?) -> Data? {
    guard let base64 = value as? String else {
      return nil
    }
    return Data(base64Encoded: base64, options: .ignoreUnknownCharacters)
  }

  // MARK: Snapshots

  static func peripheral(_ value: Any?) -> PeripheralRecord? {
    guard let object = dictionary(value), let id = string(object["id"]) else {
      return nil
    }
    var serviceData: [String: Data]?
    if let encoded = object["serviceData"] as? [String: String] {
      serviceData = encoded.compactMapValues { Data(base64Encoded: $0, options: .ignoreUnknownCharacters) }
    }
    return PeripheralRecord(
      id: id,
      name: string(object["name"]),
      rssi: int(object["rssi"]),
      mtu: int(object["mtu"]) ?? 23,
      manufacturerData: bytes(object["manufacturerData"]),
      serviceData: serviceData,
      serviceUUIDs: strings(object["serviceUUIDs"]),
      localName: string(object["localName"]),
      txPowerLevel: int(object["txPowerLevel"]),
      solicitedServiceUUIDs: strings(object["solicitedServiceUUIDs"]),
      rawScanRecord: bytes(object["rawScanRecord"]),
      isConnectable: bool(object["isConnectable"]),
      overflowServiceUUIDs: strings(object["overflowServiceUUIDs"])
    )
  }

  static func peripherals(_ value: Any?) -> [PeripheralRecord]? {
    guard let items = value as? [Any] else {
      return nil
    }
    var result: [PeripheralRecord] = []
    for item in items {
      guard let device = peripheral(item) else {
        return nil
      }
      result.append(device)
    }
    return result
  }

  /// A snapshot for a device the adapter no longer reports, such as an abandoned connection attempt.
  static func minimalPeripheral(_ id: String) -> PeripheralRecord {
    PeripheralRecord(
      id: id, name: nil, rssi: nil, mtu: 23, manufacturerData: nil, serviceData: nil, serviceUUIDs: nil,
      localName: nil, txPowerLevel: nil, solicitedServiceUUIDs: nil, rawScanRecord: nil, isConnectable: nil,
      overflowServiceUUIDs: nil
    )
  }

  static func service(_ value: Any?) -> ServiceRecord? {
    guard let object = dictionary(value),
      let handle = double(object["id"]),
      let uuid = string(object["uuid"]),
      let deviceId = string(object["deviceID"])
    else {
      return nil
    }
    return ServiceRecord(deviceId: deviceId, handle: handle, uuid: uuid, isPrimary: bool(object["isPrimary"]) ?? true)
  }

  static func characteristic(_ value: Any?) -> CharacteristicRecord? {
    guard let object = dictionary(value),
      let handle = double(object["id"]),
      let uuid = string(object["uuid"]),
      let serviceHandle = double(object["serviceID"]),
      let serviceUUID = string(object["serviceUUID"]),
      let deviceId = string(object["deviceID"])
    else {
      return nil
    }
    return CharacteristicRecord(
      deviceId: deviceId,
      handle: handle,
      uuid: uuid,
      serviceHandle: serviceHandle,
      serviceUUID: serviceUUID,
      isReadable: bool(object["isReadable"]) ?? false,
      isWritableWithResponse: bool(object["isWritableWithResponse"]) ?? false,
      isWritableWithoutResponse: bool(object["isWritableWithoutResponse"]) ?? false,
      isNotifiable: bool(object["isNotifiable"]) ?? false,
      isNotifying: bool(object["isNotifying"]) ?? false,
      isIndicatable: bool(object["isIndicatable"]) ?? false,
      value: bytes(object["value"])
    )
  }

  static func descriptor(_ value: Any?) -> DescriptorRecord? {
    guard let object = dictionary(value),
      let handle = double(object["id"]),
      let uuid = string(object["uuid"]),
      let characteristicHandle = double(object["characteristicID"]),
      let characteristicUUID = string(object["characteristicUUID"]),
      let serviceHandle = double(object["serviceID"]),
      let serviceUUID = string(object["serviceUUID"]),
      let deviceId = string(object["deviceID"])
    else {
      return nil
    }
    return DescriptorRecord(
      deviceId: deviceId,
      handle: handle,
      uuid: uuid,
      characteristicHandle: characteristicHandle,
      characteristicUUID: characteristicUUID,
      serviceHandle: serviceHandle,
      serviceUUID: serviceUUID,
      value: bytes(object["value"])
    )
  }

  static func list<T>(_ value: Any?, _ convert: (Any?) -> T?) -> [T]? {
    guard let items = value as? [Any] else {
      return nil
    }
    var result: [T] = []
    for item in items {
      guard let converted = convert(item) else {
        return nil
      }
      result.append(converted)
    }
    return result
  }

  // MARK: Errors

  /// MultiplatformBleAdapter's numeric codes mapped to the TypeScript `BleErrorCode` literals.
  private static let codes: [Int: String] = [
    0: "UnknownError", 1: "BluetoothManagerDestroyed", 2: "OperationCancelled", 3: "OperationTimedOut",
    4: "OperationStartFailed", 5: "InvalidIdentifiers",
    100: "BluetoothUnsupported", 101: "BluetoothUnauthorized", 102: "BluetoothPoweredOff",
    103: "BluetoothInUnknownState", 104: "BluetoothResetting", 105: "BluetoothStateChangeFailed",
    200: "DeviceConnectionFailed", 201: "DeviceDisconnected", 202: "DeviceRSSIReadFailed",
    203: "DeviceAlreadyConnected", 204: "DeviceNotFound", 205: "DeviceNotConnected", 206: "DeviceMTUChangeFailed",
    300: "ServicesDiscoveryFailed", 301: "IncludedServicesDiscoveryFailed", 302: "ServiceNotFound",
    303: "ServicesNotDiscovered",
    400: "CharacteristicsDiscoveryFailed", 401: "CharacteristicWriteFailed", 402: "CharacteristicReadFailed",
    403: "CharacteristicNotifyChangeFailed", 404: "CharacteristicNotFound", 405: "CharacteristicsNotDiscovered",
    406: "CharacteristicInvalidDataFormat",
    500: "DescriptorsDiscoveryFailed", 501: "DescriptorWriteFailed", 502: "DescriptorReadFailed",
    503: "DescriptorNotFound", 504: "DescriptorsNotDiscovered", 505: "DescriptorInvalidDataFormat",
    506: "DescriptorWriteNotAllowed",
    600: "ScanStartFailed", 601: "LocationServicesDisabled",
  ]

  /// Parses the adapter's error JSON. The adapter builds it by string interpolation without escaping,
  /// so a reason containing quotes produces invalid JSON; then the numeric code is still recovered.
  static func error(_ message: String?) -> BleErrorRecord {
    guard let message else {
      return .make("UnknownError")
    }
    guard let data = message.data(using: .utf8),
      let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else {
      return .make(scannedCode(message).flatMap { codes[$0] } ?? "UnknownError", reason: message)
    }
    let code = int(object["errorCode"]).flatMap { codes[$0] } ?? "UnknownError"
    return BleErrorRecord(
      code: code,
      reason: string(object["reason"]) ?? string(object["internalMessage"]),
      attErrorCode: int(object["attErrorCode"]),
      iosErrorCode: int(object["iosErrorCode"]),
      androidErrorCode: nil,
      deviceId: string(object["deviceID"]),
      serviceUUID: string(object["serviceUUID"]),
      characteristicUUID: string(object["characteristicUUID"]),
      descriptorUUID: string(object["descriptorUUID"])
    )
  }

  private static func scannedCode(_ message: String) -> Int? {
    guard let key = message.range(of: "\"errorCode\":") else {
      return nil
    }
    let digits = message[key.upperBound...].drop { $0 == " " }.prefix { $0.isNumber }
    return Int(digits)
  }
}
