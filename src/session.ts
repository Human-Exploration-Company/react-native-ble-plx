import { BleError, toBleError } from "./errors";
import type {
  NativeBlePlx,
  NativeBytes,
  NativeCharacteristic,
  NativeDescriptor,
  NativeEvents,
  NativePeripheral,
  NativeResult,
  NativeVoidResult,
} from "./NativeBlePlx";
import type {
  AndroidBonds,
  BluetoothState,
  Characteristic,
  ConnectOptions,
  ConnectionPriority,
  Descriptor,
  Disconnection,
  ServicesChange,
  GattReference,
  GattTree,
  LogLevel,
  MonitorOptions,
  NotificationResult,
  OpenOptions,
  OperationOptions,
  Peripheral,
  ScanOptions,
  ScanResult,
  Subscription,
  WriteOptions,
} from "./types";
import { fullUUID } from "./uuid";
import { bluetoothStates, bondStates, logLevels } from "./types";

function nativeEnum<T extends string>(value: unknown, values: readonly T[]): T {
  const match = values.find((item) => item === value);
  if (match === undefined) throw new BleError("InvalidNativeResult");
  return match;
}

/** Report consumer exceptions without interrupting lifecycle bookkeeping or other listeners. */
function reportException(error: unknown): void {
  queueMicrotask(() => {
    throw error;
  });
}
function notify<T>(listener: (value: T) => void, value: T): void {
  try {
    listener(value);
  } catch (error) {
    reportException(error);
  }
}

export function bytes(value: NativeBytes): Uint8Array {
  return value instanceof Uint8Array ? value : new Uint8Array(value);
}
function peripheral(value: NativePeripheral): Peripheral {
  let serviceData: Record<string, Uint8Array> | null = null;
  if (value.serviceData !== null) {
    serviceData = {};
    for (const [key, data] of Object.entries(value.serviceData))
      serviceData[key] = bytes(data);
  }
  return {
    ...value,
    serviceData,
    manufacturerData:
      value.manufacturerData === null ? null : bytes(value.manufacturerData),
    rawScanRecord:
      value.rawScanRecord === null ? null : bytes(value.rawScanRecord),
  };
}
const priorities = { balanced: 0, high: 1, lowPower: 2 } as const;
const scanModes = { lowPower: 0, balanced: 1, lowLatency: 2 } as const;
const callbackTypes = { allMatches: 1, firstMatch: 2, matchLost: 4 } as const;

class ListenerSubscription implements Subscription {
  closed = false;
  constructor(private readonly cleanup: () => void) {}
  remove(): void {
    if (this.closed) return;
    this.closed = true;
    this.cleanup();
  }
}
interface Stream<T> {
  readonly subscription: Subscription;
  readonly listener: (result: T) => void;
}
type QueuedEvent = {
  [K in keyof NativeEvents]: { name: K; data: Parameters<NativeEvents[K]>[0] };
}[keyof NativeEvents];

/** One explicitly owned radio session. Always await close() before opening another. */
export class BleSession {
  readonly generation: number;
  readonly restored: readonly Peripheral[] | null;
  private currentState: BluetoothState;
  private isClosed = false;
  private closePromise: Promise<void> | undefined;
  private counter = 0;
  private connectionCounter = 0;
  private readonly connections = new Map<string, number>();
  private readonly connectionAttempts = new Map<string, number>();
  private readonly pending = new Map<string, (error: BleError) => void>();
  private readonly subscriptions = new Set<Subscription>();
  private readonly nativeListeners: { remove(): void }[] = [];
  private readonly scans = new Map<string, Stream<ScanResult>>();
  private readonly monitors = new Map<
    string,
    Stream<NotificationResult> & { readonly deviceId: string }
  >();
  private readonly stateListeners = new Set<(state: BluetoothState) => void>();
  private readonly disconnectListeners = new Set<
    (event: Disconnection) => void
  >();
  private readonly servicesChangeListeners = new Set<
    (event: ServicesChange) => void
  >();

  private constructor(
    private readonly native: NativeBlePlx,
    generation: number,
    state: BluetoothState,
    restored: readonly NativePeripheral[] | null,
    listeners: { remove(): void }[],
  ) {
    this.generation = generation;
    this.currentState = state;
    this.restored = restored?.map(peripheral) ?? null;
    for (const device of this.restored ?? [])
      this.connections.set(device.id, ++this.connectionCounter);
    this.nativeListeners.push(...listeners);
  }

  #receive(event: QueuedEvent): void {
    if (!this.accept(event.data.generation)) return;
    switch (event.name) {
      case "stateChange": {
        try {
          this.currentState = nativeEnum(event.data.state, bluetoothStates);
        } catch (error) {
          reportException(error);
          return;
        }
        // A snapshot: a listener added by a listener waits for the next event.
        for (const listener of Array.from(this.stateListeners))
          notify(listener, this.currentState);
        break;
      }
      case "scan": {
        const data = event.data;
        const stream = this.scans.get(data.scanId);
        if (!stream) return;
        if (data.error !== null) {
          stream.subscription.remove();
          notify(stream.listener, {
            device: null,
            error: new BleError(data.error),
          });
        } else if (data.device !== null)
          notify(stream.listener, {
            device: peripheral(data.device),
            error: null,
          });
        break;
      }
      case "notification": {
        const data = event.data;
        const stream = this.monitors.get(data.subscriptionId);
        if (!stream) return;
        if (data.error !== null) {
          stream.subscription.remove();
          notify(stream.listener, {
            value: null,
            error: new BleError(data.error),
          });
        } else if (data.value !== null)
          notify(stream.listener, { value: bytes(data.value), error: null });
        break;
      }
      case "disconnect": {
        const data = event.data;
        this.connections.delete(data.deviceId);
        this.connectionAttempts.delete(data.deviceId);
        const monitors = [...this.monitors.values()].filter(
          (stream) => stream.deviceId === data.deviceId,
        );
        for (const stream of monitors) stream.subscription.remove();
        for (const stream of monitors) {
          notify(stream.listener, {
            value: null,
            error:
              data.error === null
                ? new BleError("DeviceDisconnected")
                : new BleError(data.error),
          });
        }
        const disconnection = {
          deviceId: data.deviceId,
          error: data.error === null ? null : new BleError(data.error),
        };
        for (const listener of Array.from(this.disconnectListeners))
          notify(listener, disconnection);
        break;
      }
      case "servicesChange": {
        // The native side has already ended the monitors on the changed services.
        const change = { deviceId: event.data.deviceId };
        for (const listener of Array.from(this.servicesChangeListeners))
          notify(listener, change);
        break;
      }
    }
  }

  /** @internal Native injection point for Bun tests; public callers use openBle(). */
  static async open(
    native: NativeBlePlx,
    options: OpenOptions = {},
  ): Promise<BleSession> {
    let session: BleSession | undefined;
    let openedGeneration: number | undefined;
    const earlyEvents: QueuedEvent[] = [];
    const listeners: { remove(): void }[] = [];
    const receive = (event: QueuedEvent) => {
      if (session) session.#receive(event);
      else earlyEvents.push(event);
    };
    try {
      listeners.push(
        native.addListener("stateChange", (data) =>
          receive({ name: "stateChange", data }),
        ),
      );
      listeners.push(
        native.addListener("scan", (data) => receive({ name: "scan", data })),
      );
      listeners.push(
        native.addListener("notification", (data) =>
          receive({ name: "notification", data }),
        ),
      );
      listeners.push(
        native.addListener("disconnect", (data) =>
          receive({ name: "disconnect", data }),
        ),
      );
      listeners.push(
        native.addListener("servicesChange", (data) =>
          receive({ name: "servicesChange", data }),
        ),
      );
      const result = await native.open({
        restoreIdentifier: options.restoreIdentifier ?? null,
        logLevel: options.logLevel ?? "None",
      });
      if (result.error !== null) throw new BleError(result.error);
      openedGeneration = result.generation;
      if (result.value === null) throw new BleError("InvalidNativeResult");
      const disconnected = new Set(
        earlyEvents.flatMap((event) =>
          event.name === "disconnect" &&
          event.data.generation === result.generation
            ? [event.data.deviceId]
            : [],
        ),
      );
      session = new BleSession(
        native,
        result.generation,
        nativeEnum(result.value.state, bluetoothStates),
        result.value.restored?.filter(
          (device) => !disconnected.has(device.id),
        ) ?? null,
        listeners,
      );
      for (const event of earlyEvents) session.#receive(event);
      earlyEvents.length = 0;
      return session;
    } catch (error) {
      for (const listener of listeners) listener.remove();
      if (openedGeneration !== undefined)
        await native.close(openedGeneration).catch(() => {});
      throw error;
    }
  }

  get closed(): boolean {
    return this.isClosed;
  }

  /** Android only: the system's bonds and the foreground service. Null where the platform has none. */
  get android(): AndroidBonds | null {
    const n = this.native;
    const {
      bondState,
      removeBond,
      createBond,
      answerPairing,
      startForegroundService,
      stopForegroundService,
    } = n;
    if (
      !bondState ||
      !removeBond ||
      !createBond ||
      !answerPairing ||
      !startForegroundService ||
      !stopForegroundService
    )
      return null;
    const g = this.generation;
    return {
      bondState: (id) =>
        this.operation(() =>
          bondState
            .call(n, g, id)
            .then((r) => nativeEnum(this.value(r), bondStates)),
        ),
      removeBond: (id) =>
        this.operation(() =>
          removeBond.call(n, g, id).then((r) => this.value(r)),
        ),
      createBond: (id) =>
        this.operation(() =>
          createBond.call(n, g, id).then((r) => this.value(r)),
        ),
      answerPairing: (id, passkey, options = {}) => {
        if (!/^\d{6}$/.test(passkey))
          return Promise.reject(new BleError("InvalidArgument"));
        return this.operation(() =>
          answerPairing
            .call(n, g, id, passkey, options.timeoutMs ?? 30_000)
            .then((r) => this.check(r)),
        );
      },
      startForegroundService: ({ title, text }) =>
        this.operation(() =>
          startForegroundService
            .call(n, g, title, text)
            .then((r) => this.check(r)),
        ),
      stopForegroundService: () =>
        this.operation(() =>
          stopForegroundService.call(n, g).then((r) => this.check(r)),
        ),
    };
  }

  close(): Promise<void> {
    if (this.closePromise) return this.closePromise;
    this.isClosed = true;
    for (const reject of this.pending.values())
      reject(new BleError("SessionClosed"));
    for (const subscription of this.subscriptions) subscription.remove();
    for (const subscription of this.nativeListeners) subscription.remove();
    this.connections.clear();
    this.connectionAttempts.clear();
    this.closePromise = this.native.close(this.generation).then((result) => {
      this.check(result);
    });
    return this.closePromise;
  }

  state(options: OperationOptions = {}): Promise<BluetoothState> {
    return this.operation(
      () =>
        this.native.state(this.generation).then((result) => {
          const state = nativeEnum(this.value(result), bluetoothStates);
          this.currentState = state;
          return state;
        }),
      options,
    );
  }

  onStateChange(
    listener: (state: BluetoothState) => void,
    options: { readonly emitCurrent?: boolean } = {},
  ): Subscription {
    this.assertOpen();
    this.stateListeners.add(listener);
    const subscription = this.subscription(() => {
      this.stateListeners.delete(listener);
    });
    if (options.emitCurrent) notify(listener, this.currentState);
    return subscription;
  }

  onDisconnect(listener: (event: Disconnection) => void): Subscription {
    this.assertOpen();
    this.disconnectListeners.add(listener);
    return this.subscription(() => {
      this.disconnectListeners.delete(listener);
    });
  }

  /**
   * A connected peripheral's Service Changed. Its handles under the changed
   * services are gone, and monitors on them have ended with `ServicesChanged`:
   * discover the device again. iOS and virtual peripherals; Android's engine
   * (RxAndroidBle) does not surface it.
   */
  onServicesChange(listener: (event: ServicesChange) => void): Subscription {
    this.assertOpen();
    this.servicesChangeListeners.add(listener);
    return this.subscription(() => {
      this.servicesChangeListeners.delete(listener);
    });
  }

  scan(
    options: ScanOptions,
    listener: (result: ScanResult) => void,
  ): Subscription {
    this.assertOpen();
    this.assertSignal(options.signal);
    const services = options.services?.map(fullUUID) ?? null;
    for (const stream of this.scans.values()) stream.subscription.remove();
    const scanId = this.nextId();
    let removeAbort = () => {};
    const subscription = this.subscription(() => {
      removeAbort();
      this.scans.delete(scanId);
      if (!this.closed)
        this.ignore(this.native.stopScan(this.generation, scanId));
    });
    this.scans.set(scanId, { subscription, listener });
    removeAbort = this.abortSubscription(subscription, options.signal, () =>
      notify(listener, {
        device: null,
        error: new BleError("OperationCancelled"),
      }),
    );
    this.native
      .startScan(this.generation, scanId, {
        services,
        allowDuplicates: options.allowDuplicates ?? false,
        scanMode: scanModes[options.android?.mode ?? "lowPower"],
        callbackType:
          callbackTypes[options.android?.callbackType ?? "allMatches"],
        legacy: options.android?.legacy ?? true,
      })
      .then((result) => {
        this.check(result);
      })
      .catch((error) => {
        if (subscription.closed) return;
        subscription.remove();
        notify(listener, { device: null, error: toBleError(error) });
      });
    return subscription;
  }

  async connect(
    deviceId: string,
    options: ConnectOptions = {},
  ): Promise<Peripheral> {
    this.assertOpen();
    this.assertSignal(options.signal);
    if (this.connections.has(deviceId))
      throw new BleError("DeviceAlreadyConnected");
    if (this.connectionAttempts.has(deviceId))
      throw new BleError("OperationStartFailed");
    if (options.timeoutMs !== undefined) positiveInteger(options.timeoutMs);
    if (options.android?.requestMtu !== undefined)
      mtuValue(options.android.requestMtu);
    const attempt = ++this.connectionCounter;
    this.connectionAttempts.set(deviceId, attempt);
    try {
      const device = await this.operation(
        () =>
          this.native
            .connect(this.generation, deviceId, {
              timeoutMs: options.timeoutMs ?? null,
              autoConnect: options.android?.autoConnect ?? false,
              requestMtu: options.android?.requestMtu ?? 0,
              refreshGatt: options.android?.refreshGatt ?? false,
              priority: priorities[options.android?.priority ?? "balanced"],
            })
            .then((result) => peripheral(this.value(result))),
        options,
        () =>
          this.ignore(this.native.cancelConnection(this.generation, deviceId)),
      );
      if (this.closed) throw new BleError("SessionClosed");
      if (this.connectionAttempts.get(deviceId) !== attempt)
        throw new BleError("DeviceDisconnected");
      this.connections.set(deviceId, attempt);
      return device;
    } finally {
      if (this.connectionAttempts.get(deviceId) === attempt)
        this.connectionAttempts.delete(deviceId);
    }
  }

  async cancelConnection(
    deviceId: string,
    options: OperationOptions = {},
  ): Promise<Peripheral> {
    this.assertOpen();
    this.assertSignal(options.signal);
    const connectionId = this.connections.get(deviceId);
    this.connectionAttempts.delete(deviceId);
    const value = await this.operation(
      () =>
        this.native
          .cancelConnection(this.generation, deviceId)
          .then((result) => peripheral(this.value(result))),
      options,
    );
    if (this.connections.get(deviceId) === connectionId)
      this.connections.delete(deviceId);
    return value;
  }

  isConnected(
    deviceId: string,
    options: OperationOptions = {},
  ): Promise<boolean> {
    return this.operation(
      () =>
        this.native
          .isConnected(this.generation, deviceId)
          .then((result) => this.value(result)),
      options,
    );
  }
  known(
    deviceIds: readonly string[],
    options: OperationOptions = {},
  ): Promise<readonly Peripheral[]> {
    return this.operation(
      () =>
        this.native
          .known(this.generation, deviceIds)
          .then((result) => this.value(result).map(peripheral)),
      options,
    );
  }
  connected(
    services: readonly string[],
    options: OperationOptions = {},
  ): Promise<readonly Peripheral[]> {
    const uuids = services.map(fullUUID);
    return this.operation(
      () =>
        this.native
          .connected(this.generation, uuids)
          .then((result) => this.value(result).map(peripheral)),
      options,
    );
  }

  async discover(
    deviceId: string,
    options: OperationOptions = {},
  ): Promise<GattTree> {
    this.assertOpen();
    const connectionId = this.connections.get(deviceId);
    if (connectionId === undefined) throw new BleError("DeviceNotConnected");
    const tree = await this.transaction(
      (id) =>
        this.native
          .discover(this.generation, deviceId, id)
          .then((result) => this.value(result)),
      options,
    );
    if (this.connections.get(deviceId) !== connectionId)
      throw new BleError("StaleHandle");
    return {
      deviceId,
      services: tree.services.map((value) => ({
        ...value,
        generation: this.generation,
        connectionId,
      })),
      characteristics: tree.characteristics.map((value) =>
        this.characteristic(value, connectionId),
      ),
      descriptors: tree.descriptors.map((value) =>
        this.descriptor(value, connectionId),
      ),
    };
  }

  async read(
    characteristic: Characteristic,
    options: OperationOptions = {},
  ): Promise<Uint8Array> {
    this.assertReference(characteristic);
    return this.transaction(
      (id) =>
        this.native
          .read(this.generation, characteristic.handle, id)
          .then((result) => bytes(this.value(result))),
      options,
    );
  }
  async write(
    characteristic: Characteristic,
    value: Uint8Array,
    options: WriteOptions = {},
  ): Promise<void> {
    this.assertReference(characteristic);
    return this.transaction(
      (id) =>
        this.native
          .write(
            this.generation,
            characteristic.handle,
            value,
            options.withResponse ?? true,
            id,
          )
          .then((result) => {
            this.check(result);
          }),
      options,
    );
  }
  async readDescriptor(
    descriptor: Descriptor,
    options: OperationOptions = {},
  ): Promise<Uint8Array> {
    this.assertReference(descriptor);
    return this.transaction(
      (id) =>
        this.native
          .readDescriptor(this.generation, descriptor.handle, id)
          .then((result) => bytes(this.value(result))),
      options,
    );
  }
  async writeDescriptor(
    descriptor: Descriptor,
    value: Uint8Array,
    options: OperationOptions = {},
  ): Promise<void> {
    this.assertReference(descriptor);
    return this.transaction(
      (id) =>
        this.native
          .writeDescriptor(this.generation, descriptor.handle, value, id)
          .then((result) => {
            this.check(result);
          }),
      options,
    );
  }

  monitor(
    characteristic: Characteristic,
    listener: (result: NotificationResult) => void,
    options: MonitorOptions = {},
  ): Subscription {
    this.assertOpen();
    this.assertSignal(options.signal);
    this.assertReference(characteristic);
    const id = this.nextId();
    let removeAbort = () => {};
    const subscription = this.subscription(() => {
      removeAbort();
      this.monitors.delete(id);
      if (!this.closed) this.ignore(this.native.cancel(this.generation, id));
    });
    this.monitors.set(id, {
      subscription,
      listener,
      deviceId: characteristic.deviceId,
    });
    removeAbort = this.abortSubscription(subscription, options.signal, () =>
      notify(listener, {
        value: null,
        error: new BleError("OperationCancelled"),
      }),
    );
    this.native
      .startMonitor(
        this.generation,
        characteristic.handle,
        id,
        options.androidSubscriptionType ?? null,
      )
      .then((result) => {
        this.check(result);
        if (!subscription.closed && options.onReady)
          notify(options.onReady, undefined);
      })
      .catch((error) => {
        if (subscription.closed) return;
        subscription.remove();
        notify(listener, { value: null, error: toBleError(error) });
      });
    return subscription;
  }

  rssi(deviceId: string, options: OperationOptions = {}): Promise<Peripheral> {
    return this.transaction(
      (id) =>
        this.native
          .rssi(this.generation, deviceId, id)
          .then((result) => peripheral(this.value(result))),
      options,
    );
  }
  requestMtu(
    deviceId: string,
    mtu: number,
    options: OperationOptions = {},
  ): Promise<Peripheral> {
    mtuValue(mtu);
    return this.transaction(
      (id) =>
        this.native
          .requestMtu(this.generation, deviceId, mtu, id)
          .then((result) => peripheral(this.value(result))),
      options,
    );
  }
  requestPriority(
    deviceId: string,
    priority: ConnectionPriority,
    options: OperationOptions = {},
  ): Promise<Peripheral> {
    return this.transaction(
      (id) =>
        this.native
          .requestPriority(this.generation, deviceId, priorities[priority], id)
          .then((result) => peripheral(this.value(result))),
      options,
    );
  }
  setLogLevel(level: LogLevel): Promise<void> {
    return this.operation(() =>
      this.native.setLogLevel(this.generation, level).then((result) => {
        this.check(result);
      }),
    );
  }
  logLevel(): Promise<LogLevel> {
    return this.operation(() =>
      this.native
        .logLevel(this.generation)
        .then((result) => nativeEnum(this.value(result), logLevels)),
    );
  }

  private accept(generation: number): boolean {
    return !this.closed && generation === this.generation;
  }
  private assertOpen(): void {
    if (this.closed) throw new BleError("SessionClosed");
  }
  private assertSignal(signal: AbortSignal | undefined): void {
    if (signal?.aborted)
      throw new BleError("OperationCancelled", signal.reason);
  }
  private assertReference(value: GattReference): void {
    this.assertOpen();
    if (
      value.generation !== this.generation ||
      value.connectionId !== this.connections.get(value.deviceId)
    )
      throw new BleError("StaleHandle");
  }
  private nextId(): string {
    return `${this.generation}:${++this.counter}`;
  }
  private check(result: NativeVoidResult): void {
    if (result.generation !== this.generation)
      throw new BleError("SessionClosed");
    if (result.error !== null) throw new BleError(result.error);
  }
  private value<T>(result: NativeResult<T>): T {
    this.check(result);
    if (result.value === null) throw new BleError("InvalidNativeResult");
    return result.value;
  }
  private characteristic(
    value: NativeCharacteristic,
    connectionId: number,
  ): Characteristic {
    return {
      ...value,
      generation: this.generation,
      connectionId,
      value: value.value === null ? null : bytes(value.value),
    };
  }
  private descriptor(
    value: NativeDescriptor,
    connectionId: number,
  ): Descriptor {
    return {
      ...value,
      generation: this.generation,
      connectionId,
      value: value.value === null ? null : bytes(value.value),
    };
  }
  private subscription(cleanup: () => void): Subscription {
    const subscription = new ListenerSubscription(() => {
      this.subscriptions.delete(subscription);
      cleanup();
    });
    this.subscriptions.add(subscription);
    return subscription;
  }
  private abortSubscription(
    subscription: Subscription,
    signal: AbortSignal | undefined,
    notify: () => void,
  ): () => void {
    const abort = () => {
      subscription.remove();
      notify();
    };
    signal?.addEventListener("abort", abort, { once: true });
    return () => {
      signal?.removeEventListener("abort", abort);
    };
  }
  private ignore(promise: Promise<unknown>): void {
    void promise.catch(() => {});
  }
  private transaction<T>(
    start: (id: string) => Promise<T>,
    options: OperationOptions,
  ): Promise<T> {
    const id = this.nextId();
    return this.operation(
      () => start(id),
      options,
      () => this.ignore(this.native.cancel(this.generation, id)),
    );
  }
  private async operation<T>(
    start: () => Promise<T>,
    options: OperationOptions = {},
    cancel?: () => void,
  ): Promise<T> {
    this.assertOpen();
    this.assertSignal(options.signal);
    const id = this.nextId();
    let abort = () => {};
    try {
      return await new Promise<T>((resolve, reject) => {
        let settled = false;
        const fail = (error: BleError) => {
          if (!settled) {
            settled = true;
            reject(error);
          }
        };
        this.pending.set(id, fail);
        abort = () => {
          if (settled) return;
          fail(new BleError("OperationCancelled", options.signal?.reason));
          cancel?.();
        };
        options.signal?.addEventListener("abort", abort, { once: true });
        try {
          start().then(
            (value) => {
              if (settled) return;
              settled = true;
              resolve(value);
            },
            (error) => {
              fail(toBleError(error));
            },
          );
        } catch (error) {
          fail(toBleError(error));
        }
      });
    } finally {
      this.pending.delete(id);
      options.signal?.removeEventListener("abort", abort);
    }
  }
}

function positiveInteger(value: number): void {
  if (!Number.isSafeInteger(value) || value <= 0)
    throw new BleError("InvalidArgument");
}
function mtuValue(value: number): void {
  if (!Number.isInteger(value) || value < 23 || value > 517)
    throw new BleError("InvalidArgument");
}
