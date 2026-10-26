export const bleErrorCodes = [
  "UnknownError",
  "BluetoothManagerDestroyed",
  "OperationCancelled",
  "OperationTimedOut",
  "OperationStartFailed",
  "InvalidIdentifiers",
  "BluetoothUnsupported",
  "BluetoothUnauthorized",
  "BluetoothPoweredOff",
  "BluetoothInUnknownState",
  "BluetoothResetting",
  "BluetoothStateChangeFailed",
  "DeviceConnectionFailed",
  "DeviceDisconnected",
  "DeviceRSSIReadFailed",
  "DeviceAlreadyConnected",
  "DeviceNotFound",
  "DeviceNotConnected",
  "DeviceMTUChangeFailed",
  "ServicesDiscoveryFailed",
  "IncludedServicesDiscoveryFailed",
  "ServiceNotFound",
  "ServicesNotDiscovered",
  "CharacteristicsDiscoveryFailed",
  "CharacteristicWriteFailed",
  "CharacteristicReadFailed",
  "CharacteristicNotifyChangeFailed",
  "CharacteristicNotFound",
  "CharacteristicsNotDiscovered",
  "CharacteristicInvalidDataFormat",
  "DescriptorsDiscoveryFailed",
  "DescriptorWriteFailed",
  "DescriptorReadFailed",
  "DescriptorNotFound",
  "DescriptorsNotDiscovered",
  "DescriptorInvalidDataFormat",
  "DescriptorWriteNotAllowed",
  "ScanStartFailed",
  "LocationServicesDisabled",
  "SessionClosed",
  "SessionAlreadyOpen",
  "StaleHandle",
  "InvalidNativeResult",
  "InvalidArgument",
] as const;
export type BleErrorCode = (typeof bleErrorCodes)[number];

export interface BleErrorDetails {
  readonly code: string;
  readonly reason: string | null;
  readonly attErrorCode: number | null;
  readonly iosErrorCode: number | null;
  readonly androidErrorCode: number | null;
  readonly deviceId: string | null;
  readonly serviceUUID: string | null;
  readonly characteristicUUID: string | null;
  readonly descriptorUUID: string | null;
}

export class BleError extends Error implements BleErrorDetails {
  readonly code: BleErrorCode;
  readonly reason: string | null;
  readonly attErrorCode: number | null;
  readonly iosErrorCode: number | null;
  readonly androidErrorCode: number | null;
  readonly deviceId: string | null;
  readonly serviceUUID: string | null;
  readonly characteristicUUID: string | null;
  readonly descriptorUUID: string | null;

  constructor(details: BleErrorCode | BleErrorDetails, cause?: unknown) {
    const data = typeof details === "string" ? null : details;
    const code =
      typeof details === "string"
        ? details
        : (bleErrorCodes.find((value) => value === details.code) ??
          "UnknownError");
    super(data?.reason ?? code, { cause });
    this.name = "BleError";
    this.code = code;
    this.reason = data?.reason ?? null;
    this.attErrorCode = data?.attErrorCode ?? null;
    this.iosErrorCode = data?.iosErrorCode ?? null;
    this.androidErrorCode = data?.androidErrorCode ?? null;
    this.deviceId = data?.deviceId ?? null;
    this.serviceUUID = data?.serviceUUID ?? null;
    this.characteristicUUID = data?.characteristicUUID ?? null;
    this.descriptorUUID = data?.descriptorUUID ?? null;
  }
}

export function toBleError(cause: unknown): BleError {
  return cause instanceof BleError
    ? cause
    : new BleError("UnknownError", cause);
}
