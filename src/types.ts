import type { BleError } from "./errors";

export const bluetoothStates = [
  "Unknown",
  "Resetting",
  "Unsupported",
  "Unauthorized",
  "PoweredOff",
  "PoweredOn",
] as const;
export type BluetoothState = (typeof bluetoothStates)[number];
export const logLevels = [
  "None",
  "Verbose",
  "Debug",
  "Info",
  "Warning",
  "Error",
] as const;
export type LogLevel = (typeof logLevels)[number];
export type ConnectionPriority = "balanced" | "high" | "lowPower";

export interface OperationOptions {
  readonly signal?: AbortSignal;
}
export interface OpenOptions {
  /** Open early during app launch and reuse this identifier for iOS restoration. */
  readonly restoreIdentifier?: string;
  readonly logLevel?: LogLevel;
}
export interface ConnectOptions extends OperationOptions {
  readonly timeoutMs?: number;
  readonly android?: {
    readonly autoConnect?: boolean;
    readonly requestMtu?: number;
    readonly refreshGatt?: boolean;
    readonly priority?: ConnectionPriority;
  };
}
export interface ScanOptions extends OperationOptions {
  readonly services?: readonly string[];
  readonly allowDuplicates?: boolean;
  readonly android?: {
    readonly mode?: "lowPower" | "balanced" | "lowLatency";
    readonly callbackType?: "allMatches" | "firstMatch" | "matchLost";
    readonly legacy?: boolean;
  };
}
export interface Peripheral {
  readonly id: string;
  readonly name: string | null;
  readonly rssi: number | null;
  readonly mtu: number;
  readonly manufacturerData: Uint8Array | null;
  readonly serviceData: Readonly<Record<string, Uint8Array>> | null;
  readonly serviceUUIDs: readonly string[] | null;
  readonly localName: string | null;
  readonly txPowerLevel: number | null;
  readonly solicitedServiceUUIDs: readonly string[] | null;
  readonly rawScanRecord: Uint8Array | null;
  readonly isConnectable: boolean | null;
  readonly overflowServiceUUIDs: readonly string[] | null;
}

/** Handles belong to one session and one connection. Rediscover after reconnecting. */
export interface GattReference {
  readonly generation: number;
  readonly connectionId: number;
  readonly deviceId: string;
  readonly handle: number;
  readonly uuid: string;
}
export interface Descriptor extends GattReference {
  readonly characteristicHandle: number;
  readonly characteristicUUID: string;
  readonly serviceHandle: number;
  readonly serviceUUID: string;
  readonly value: Uint8Array | null;
}
export interface Characteristic extends GattReference {
  readonly serviceHandle: number;
  readonly serviceUUID: string;
  readonly isReadable: boolean;
  readonly isWritableWithResponse: boolean;
  readonly isWritableWithoutResponse: boolean;
  readonly isNotifiable: boolean;
  readonly isNotifying: boolean;
  readonly isIndicatable: boolean;
  readonly value: Uint8Array | null;
}
export interface Service extends GattReference {
  readonly isPrimary: boolean;
}
export interface GattTree {
  readonly deviceId: string;
  readonly services: readonly Service[];
  readonly characteristics: readonly Characteristic[];
  readonly descriptors: readonly Descriptor[];
}
export interface Subscription {
  readonly closed: boolean;
  /** Idempotent. Stops native work and detaches its abort listener. */
  remove(): void;
}
export type ScanResult =
  | { readonly device: Peripheral; readonly error: null }
  | { readonly device: null; readonly error: BleError };
export type NotificationResult =
  | { readonly value: Uint8Array; readonly error: null }
  | { readonly value: null; readonly error: BleError };
export interface Disconnection {
  readonly deviceId: string;
  readonly error: BleError | null;
}
export interface WriteOptions extends OperationOptions {
  readonly withResponse?: boolean;
}
export interface MonitorOptions extends OperationOptions {
  readonly androidSubscriptionType?: "notification" | "indication";
}
