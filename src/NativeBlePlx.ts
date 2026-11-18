import type { BleErrorDetails } from "./errors";
import type {
  Characteristic,
  Descriptor,
  LogLevel,
  Peripheral,
  Service,
} from "./types";

/** Apple Data encodes as Uint8Array; Android ByteArray encodes as ArrayBuffer. */
export type NativeBytes = Uint8Array | ArrayBuffer;
export type NativePeripheral = Omit<
  Peripheral,
  "manufacturerData" | "serviceData" | "rawScanRecord"
> & {
  readonly manufacturerData: NativeBytes | null;
  readonly serviceData: Readonly<Record<string, NativeBytes>> | null;
  readonly rawScanRecord: NativeBytes | null;
};
export type NativeCharacteristic = Omit<
  Characteristic,
  "generation" | "connectionId" | "value"
> & { readonly value: NativeBytes | null };
export type NativeDescriptor = Omit<
  Descriptor,
  "generation" | "connectionId" | "value"
> & { readonly value: NativeBytes | null };
export type NativeService = Omit<Service, "generation" | "connectionId">;
export interface NativeGattTree {
  readonly deviceId: string;
  readonly services: readonly NativeService[];
  readonly characteristics: readonly NativeCharacteristic[];
  readonly descriptors: readonly NativeDescriptor[];
}
export interface NativeVoidResult {
  readonly generation: number;
  readonly error: BleErrorDetails | null;
}
export interface NativeResult<T> extends NativeVoidResult {
  readonly value: T | null;
}
export interface NativeOpenInfo {
  readonly state: string;
  readonly restored: readonly NativePeripheral[] | null;
}
export interface NativeOpenOptions {
  readonly restoreIdentifier: string | null;
  readonly logLevel: LogLevel;
}
export interface NativeScanOptions {
  readonly services: readonly string[] | null;
  readonly allowDuplicates: boolean;
  readonly scanMode: number;
  readonly callbackType: number;
  readonly legacy: boolean;
}
export interface NativeConnectOptions {
  readonly timeoutMs: number | null;
  readonly autoConnect: boolean;
  readonly requestMtu: number;
  readonly refreshGatt: boolean;
  readonly priority: number;
}
export interface NativeEvents {
  stateChange: (event: {
    readonly generation: number;
    readonly state: string;
  }) => void;
  scan: (event: {
    readonly generation: number;
    readonly scanId: string;
    readonly device: NativePeripheral | null;
    readonly error: BleErrorDetails | null;
  }) => void;
  notification: (event: {
    readonly generation: number;
    readonly subscriptionId: string;
    readonly value: NativeBytes | null;
    readonly error: BleErrorDetails | null;
  }) => void;
  disconnect: (event: {
    readonly generation: number;
    readonly deviceId: string;
    readonly error: BleErrorDetails | null;
  }) => void;
  /** iOS: the peripheral's Service Changed; its handles under the changed services are gone. */
  servicesChange: (event: {
    readonly generation: number;
    readonly deviceId: string;
  }) => void;
}

/** Mirrors the annotated native surface; deliberately no React Native bridge types. */
export interface NativeBlePlx {
  addListener<K extends keyof NativeEvents>(
    event: K,
    listener: NativeEvents[K],
  ): { remove(): void };
  open(options: NativeOpenOptions): Promise<NativeResult<NativeOpenInfo>>;
  close(generation: number): Promise<NativeVoidResult>;
  state(generation: number): Promise<NativeResult<string>>;
  startScan(
    generation: number,
    scanId: string,
    options: NativeScanOptions,
  ): Promise<NativeVoidResult>;
  stopScan(generation: number, scanId: string): Promise<NativeVoidResult>;
  connect(
    generation: number,
    deviceId: string,
    options: NativeConnectOptions,
  ): Promise<NativeResult<NativePeripheral>>;
  cancelConnection(
    generation: number,
    deviceId: string,
  ): Promise<NativeResult<NativePeripheral>>;
  isConnected(
    generation: number,
    deviceId: string,
  ): Promise<NativeResult<boolean>>;
  known(
    generation: number,
    deviceIds: readonly string[],
  ): Promise<NativeResult<readonly NativePeripheral[]>>;
  connected(
    generation: number,
    services: readonly string[],
  ): Promise<NativeResult<readonly NativePeripheral[]>>;
  discover(
    generation: number,
    deviceId: string,
    transactionId: string,
  ): Promise<NativeResult<NativeGattTree>>;
  read(
    generation: number,
    handle: number,
    transactionId: string,
  ): Promise<NativeResult<NativeBytes>>;
  write(
    generation: number,
    handle: number,
    value: Uint8Array,
    withResponse: boolean,
    transactionId: string,
  ): Promise<NativeVoidResult>;
  readDescriptor(
    generation: number,
    handle: number,
    transactionId: string,
  ): Promise<NativeResult<NativeBytes>>;
  writeDescriptor(
    generation: number,
    handle: number,
    value: Uint8Array,
    transactionId: string,
  ): Promise<NativeVoidResult>;
  startMonitor(
    generation: number,
    handle: number,
    subscriptionId: string,
    subscriptionType: string | null,
  ): Promise<NativeVoidResult>;
  cancel(generation: number, transactionId: string): Promise<NativeVoidResult>;
  rssi(
    generation: number,
    deviceId: string,
    transactionId: string,
  ): Promise<NativeResult<NativePeripheral>>;
  requestMtu(
    generation: number,
    deviceId: string,
    mtu: number,
    transactionId: string,
  ): Promise<NativeResult<NativePeripheral>>;
  requestPriority(
    generation: number,
    deviceId: string,
    priority: number,
    transactionId: string,
  ): Promise<NativeResult<NativePeripheral>>;
  setLogLevel(generation: number, level: LogLevel): Promise<NativeVoidResult>;
  logLevel(generation: number): Promise<NativeResult<string>>;
  /**
   * Android only: the system's bonds and the foreground service. Absent
   * elsewhere. Properties, not methods: the session checks each is there
   * and calls it with the module as `this`.
   */
  readonly bondState?: (
    generation: number,
    deviceId: string,
  ) => Promise<NativeResult<string>>;
  readonly removeBond?: (
    generation: number,
    deviceId: string,
  ) => Promise<NativeResult<boolean>>;
  readonly createBond?: (
    generation: number,
    deviceId: string,
  ) => Promise<NativeResult<boolean>>;
  readonly answerPairing?: (
    generation: number,
    deviceId: string,
    passkey: string,
    timeoutMs: number,
  ) => Promise<NativeVoidResult>;
  readonly startForegroundService?: (
    generation: number,
    title: string,
    text: string,
  ) => Promise<NativeVoidResult>;
  readonly stopForegroundService?: (
    generation: number,
  ) => Promise<NativeVoidResult>;
}
