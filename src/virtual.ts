/**
 * Virtual peripherals: a {@link NativeBlePlx} written in JavaScript, so an
 * app can run against peripherals it describes, with no radio, on a
 * simulator, in a browser, or in tests. A session opened here is the same
 * {@link BleSession} the native module gives: everything above it runs
 * unchanged.
 *
 * A peripheral is its services and characteristics, each a handler. It may
 * require an authenticated link for some operations: the first such
 * operation on an unbonded link pairs, as the system would, by passkey
 * entry. On Android an armed `answerPairing` answers it; otherwise the
 * `pairing` option stands in for the user at the system's dialog.
 */
import type { BleErrorDetails } from "./errors";
import type {
  NativeBlePlx,
  NativeCharacteristic,
  NativeConnectOptions,
  NativeEvents,
  NativeGattTree,
  NativeOpenInfo,
  NativeOpenOptions,
  NativePeripheral,
  NativeResult,
  NativeScanOptions,
  NativeVoidResult,
} from "./NativeBlePlx";
import { BleSession } from "./session";
import type { BluetoothState, LogLevel, OpenOptions } from "./types";
import { fullUUID } from "./uuid";

/** A protected operation: it needs an encrypted link with a bond. */
export type VirtualOperation = "read" | "write" | "subscribe";

export interface VirtualCharacteristic {
  readonly uuid: string;
  readonly read?: (link: VirtualLink) => Uint8Array | Promise<Uint8Array>;
  /** A write with response; a thrown {@link VirtualAttError} is its ATT error. */
  readonly write?: (
    value: Uint8Array,
    link: VirtualLink,
  ) => void | Promise<void>;
  readonly writeWithoutResponse?: (
    value: Uint8Array,
    link: VirtualLink,
  ) => void;
  /** Whether it notifies: the peripheral sends through {@link VirtualLink.notify}. */
  readonly notify?: boolean;
  /** The operations that need an authenticated link. */
  readonly authenticated?: readonly VirtualOperation[];
}

export interface VirtualService {
  readonly uuid: string;
  readonly characteristics: readonly VirtualCharacteristic[];
}

/** The peripheral's side of one link. */
export interface VirtualLink {
  readonly deviceId: string;
  /** Whether the link is encrypted with a bond. */
  readonly bonded: boolean;
  /** The ATT MTU the link settled on: a notification carries 3 bytes fewer. */
  readonly mtu: number;
  /** Notify every subscriber to the characteristic `uuid`. */
  notify(uuid: string, value: Uint8Array): void;
  /** Close the link from the peripheral's side. */
  disconnect(): void;
  /**
   * Indicate Service Changed, as after a firmware update that keeps the
   * link: on iOS, monitors on the device end with `ServicesChanged` and the
   * session hears it; Android's engine does not surface it.
   */
  servicesChanged(): void;
}

export interface VirtualPeripheral {
  /** The platform's identifier: an address on Android, a UUID on iOS. */
  readonly id: string;
  /** The advertised local name. */
  readonly name: string | null;
  readonly rssi?: number;
  /** The largest ATT MTU it takes. 247 by default. */
  readonly mtu?: number;
  readonly manufacturerData?: Uint8Array | null;
  readonly services: readonly VirtualService[];
  /** Whether it advertises and takes a connection now. Always, by default. */
  readonly present?: () => boolean;
  /** The passkey its pairing expects now; null pairs without one. */
  readonly passkey?: () => string | null;
  /** A central connected: the peripheral's side of the link. */
  readonly connected?: (link: VirtualLink) => void;
  /** The link closed, from either side. */
  readonly disconnected?: (link: VirtualLink) => void;
}

/** An ATT error a handler throws: 5 is insufficient authentication. */
export class VirtualAttError extends Error {
  constructor(readonly attErrorCode: number) {
    super(`ATT error ${attErrorCode}`);
  }
}

export interface VirtualOptions extends OpenOptions {
  readonly peripherals: readonly VirtualPeripheral[];
  /** Whose behaviour to follow: Android has bonds and a foreground service. */
  readonly platform: "ios" | "android";
  /** The adapter's state. Powered on by default. */
  readonly state?: BluetoothState;
  /**
   * The user at the system's pairing dialog: the passkey typed, or null
   * for cancelled. By default the user types the peripheral's own.
   */
  readonly pairing?: (peripheral: VirtualPeripheral) => Promise<string | null>;
  /** The bonds the "system" holds, by peripheral id; kept across sessions if shared. */
  readonly bonds?: Set<string>;
}

/** A session over virtual peripherals: the same {@link BleSession} as `openBle`. */
export function openVirtualBle(options: VirtualOptions): Promise<BleSession> {
  return BleSession.open(new VirtualNative(options), options);
}

type Handle = {
  readonly peripheral: VirtualPeripheral;
  readonly serviceUuid: string;
  readonly serviceHandle: number;
  readonly characteristic: VirtualCharacteristic;
  readonly handle: number;
};

type Listeners = { [K in keyof NativeEvents]: Set<NativeEvents[K]> };

const failure = (
  code: string,
  details: Partial<Omit<BleErrorDetails, "code">> = {},
): BleErrorDetails => ({
  code,
  reason: details.reason ?? null,
  attErrorCode: details.attErrorCode ?? null,
  iosErrorCode: details.iosErrorCode ?? null,
  androidErrorCode: details.androidErrorCode ?? null,
  deviceId: details.deviceId ?? null,
  serviceUUID: details.serviceUUID ?? null,
  characteristicUUID: details.characteristicUUID ?? null,
  descriptorUUID: details.descriptorUUID ?? null,
});

const later = (run: () => void) => setTimeout(run, 0);

class VirtualNative implements NativeBlePlx {
  private readonly listeners: Listeners = {
    stateChange: new Set(),
    scan: new Set(),
    notification: new Set(),
    disconnect: new Set(),
    servicesChange: new Set(),
  };
  private generation = 0;
  private open_ = false;
  private level: LogLevel = "None";
  private readonly bonds: Set<string>;
  private readonly links = new Map<string, VirtualLink & { closed: boolean }>();
  private readonly mtus = new Map<string, number>();
  private readonly monitors = new Map<
    string,
    { readonly deviceId: string; readonly handle: number }
  >();
  private readonly answers = new Map<
    string,
    { passkey: string; until: number }
  >();
  private readonly connecting = new Map<string, () => void>();
  private scanTimer: ReturnType<typeof setInterval> | null = null;

  // Android only: present as properties, as the native module has them.
  readonly bondState?: NonNullable<NativeBlePlx["bondState"]>;
  readonly removeBond?: NonNullable<NativeBlePlx["removeBond"]>;
  readonly createBond?: NonNullable<NativeBlePlx["createBond"]>;
  readonly answerPairing?: NonNullable<NativeBlePlx["answerPairing"]>;
  readonly startForegroundService?: NonNullable<
    NativeBlePlx["startForegroundService"]
  >;
  readonly stopForegroundService?: NonNullable<
    NativeBlePlx["stopForegroundService"]
  >;

  constructor(private readonly options: VirtualOptions) {
    this.bonds = options.bonds ?? new Set();
    if (options.platform === "android") {
      this.bondState = async (g, id) =>
        this.ok(g, this.bonds.has(id) ? "bonded" : "none");
      this.removeBond = async (g, id) => this.ok(g, this.bonds.delete(id));
      this.createBond = async (g, id) => {
        const peripheral = this.peripheral(id);
        return this.ok(g, peripheral ? await this.pair(peripheral) : false);
      };
      this.answerPairing = async (g, id, passkey, timeoutMs) => {
        this.answers.set(id, { passkey, until: Date.now() + timeoutMs });
        return this.done(g);
      };
      this.startForegroundService = async (g) => this.done(g);
      this.stopForegroundService = async (g) => this.done(g);
    }
  }

  addListener<K extends keyof NativeEvents>(
    event: K,
    listener: NativeEvents[K],
  ) {
    const set: Set<NativeEvents[K]> = this.listeners[event];
    set.add(listener);
    return { remove: () => void set.delete(listener) };
  }

  /** Events arrive after the call that caused them returns, as the native module sends them. */
  private send<E>(listeners: Set<(event: E) => void>, event: E): void {
    later(() => {
      for (const listener of Array.from(listeners)) listener(event);
    });
  }

  private ok<T>(generation: number, value: T): NativeResult<T> {
    return generation === this.generation && this.open_
      ? { generation, value, error: null }
      : { generation, value: null, error: failure("SessionClosed") };
  }
  private done(
    generation: number,
    error: BleErrorDetails | null = null,
  ): NativeVoidResult {
    return generation === this.generation && this.open_
      ? { generation, error }
      : { generation, error: failure("SessionClosed") };
  }
  private fail<T>(generation: number, error: BleErrorDetails): NativeResult<T> {
    return { generation, value: null, error };
  }

  private peripheral(id: string): VirtualPeripheral | undefined {
    return this.options.peripherals.find((p) => p.id === id);
  }
  private present(p: VirtualPeripheral): boolean {
    return p.present?.() ?? true;
  }
  private record(p: VirtualPeripheral, mtu = 23): NativePeripheral {
    return {
      id: p.id,
      name: p.name,
      rssi: p.rssi ?? -60,
      mtu,
      manufacturerData: p.manufacturerData ?? null,
      serviceData: null,
      serviceUUIDs: p.services.map((s) => fullUUID(s.uuid)),
      localName: p.name,
      txPowerLevel: null,
      solicitedServiceUUIDs: null,
      rawScanRecord: null,
      isConnectable: true,
      overflowServiceUUIDs: null,
    };
  }

  /** Every characteristic of every peripheral, with stable handles. */
  private handles(): Handle[] {
    const all: Handle[] = [];
    for (const peripheral of this.options.peripherals) {
      let next = 1;
      for (const service of peripheral.services) {
        const serviceHandle = next++;
        for (const characteristic of service.characteristics)
          all.push({
            peripheral,
            serviceUuid: fullUUID(service.uuid),
            serviceHandle,
            characteristic,
            handle: next++ + this.offset(peripheral),
          });
      }
    }
    return all;
  }
  /** Handles are per session, not per device: peripherals' ranges do not overlap. */
  private offset(p: VirtualPeripheral): number {
    return this.options.peripherals.indexOf(p) * 0x1000;
  }
  private handle(handle: number): Handle | undefined {
    return this.handles().find((h) => h.handle === handle);
  }

  async open(
    options: NativeOpenOptions,
  ): Promise<NativeResult<NativeOpenInfo>> {
    if (this.open_)
      return this.fail(this.generation, failure("SessionAlreadyOpen"));
    this.open_ = true;
    this.level = options.logLevel;
    const generation = ++this.generation;
    return {
      generation,
      value: { state: this.options.state ?? "PoweredOn", restored: null },
      error: null,
    };
  }
  async close(generation: number): Promise<NativeVoidResult> {
    if (generation !== this.generation) return { generation, error: null };
    for (const id of Array.from(this.links.keys())) this.drop(id, false);
    if (this.scanTimer) clearInterval(this.scanTimer);
    this.scanTimer = null;
    this.monitors.clear();
    this.open_ = false;
    this.generation++;
    return { generation, error: null };
  }
  async state(generation: number) {
    return this.ok(generation, this.options.state ?? "PoweredOn");
  }

  async startScan(
    generation: number,
    scanId: string,
    options: NativeScanOptions,
  ): Promise<NativeVoidResult> {
    if (this.scanTimer) clearInterval(this.scanTimer);
    const wanted = options.services?.map(fullUUID) ?? null;
    const tick = () => {
      for (const p of this.options.peripherals) {
        if (!this.present(p) || this.links.has(p.id)) continue;
        const uuids = p.services.map((s) => fullUUID(s.uuid));
        if (wanted && !wanted.some((u) => uuids.includes(u))) continue;
        this.send(this.listeners.scan, {
          generation,
          scanId,
          device: this.record(p),
          error: null,
        });
      }
    };
    this.scanTimer = setInterval(tick, 1000);
    later(tick);
    return this.done(generation);
  }
  async stopScan(generation: number): Promise<NativeVoidResult> {
    if (this.scanTimer) clearInterval(this.scanTimer);
    this.scanTimer = null;
    return this.done(generation);
  }

  async connect(
    generation: number,
    deviceId: string,
    options: NativeConnectOptions,
  ): Promise<NativeResult<NativePeripheral>> {
    const p = this.peripheral(deviceId);
    if (!p)
      return this.fail(generation, failure("DeviceNotFound", { deviceId }));
    if (this.links.has(deviceId))
      return this.fail(
        generation,
        failure("DeviceAlreadyConnected", { deviceId }),
      );
    // A connect waits for the peripheral: up to its timeout, or until cancelled.
    const arrived = await new Promise<boolean>((resolve) => {
      if (this.present(p)) return resolve(true);
      const timer = setInterval(() => {
        if (this.present(p)) finish(true);
      }, 250);
      const timeout =
        options.timeoutMs === null
          ? null
          : setTimeout(() => finish(false), options.timeoutMs);
      const finish = (value: boolean) => {
        clearInterval(timer);
        if (timeout) clearTimeout(timeout);
        this.connecting.delete(deviceId);
        resolve(value);
      };
      this.connecting.set(deviceId, () => finish(false));
    });
    if (!arrived)
      return this.fail(
        generation,
        failure(
          options.timeoutMs === null
            ? "OperationCancelled"
            : "OperationTimedOut",
          {
            deviceId,
          },
        ),
      );
    if (generation !== this.generation || !this.open_)
      return this.fail(generation, failure("SessionClosed"));
    const most = p.mtu ?? 247;
    const mtu =
      this.options.platform === "android"
        ? options.requestMtu > 0
          ? Math.min(options.requestMtu, most)
          : 23
        : Math.min(185, most);
    this.mtus.set(deviceId, mtu);
    const bonds = this.bonds;
    const link: VirtualLink & { closed: boolean } = {
      deviceId,
      closed: false,
      get bonded() {
        return bonds.has(deviceId) && !this.closed;
      },
      mtu,
      notify: (uuid, value) => this.notifyFrom(p, uuid, value),
      disconnect: () => later(() => this.drop(deviceId, true)),
      servicesChanged: () => later(() => this.changeServices(deviceId)),
    };
    this.links.set(deviceId, link);
    p.connected?.(link);
    return this.ok(generation, this.record(p, mtu));
  }

  private drop(deviceId: string, emit: boolean): void {
    const link = this.links.get(deviceId);
    if (!link) return;
    link.closed = true;
    this.links.delete(deviceId);
    for (const [id, m] of this.monitors)
      if (m.deviceId === deviceId) this.monitors.delete(id);
    this.peripheral(deviceId)?.disconnected?.(link);
    if (emit)
      this.send(this.listeners.disconnect, {
        generation: this.generation,
        deviceId,
        error: null,
      });
  }

  private changeServices(deviceId: string): void {
    if (this.options.platform !== "ios" || !this.links.has(deviceId)) return;
    for (const [subscriptionId, m] of this.monitors) {
      if (m.deviceId !== deviceId) continue;
      this.monitors.delete(subscriptionId);
      this.send(this.listeners.notification, {
        generation: this.generation,
        subscriptionId,
        value: null,
        error: failure("ServicesChanged", { deviceId }),
      });
    }
    this.send(this.listeners.servicesChange, {
      generation: this.generation,
      deviceId,
    });
  }

  async cancelConnection(generation: number, deviceId: string) {
    this.connecting.get(deviceId)?.();
    const p = this.peripheral(deviceId);
    if (!p)
      return this.fail<NativePeripheral>(
        generation,
        failure("DeviceNotFound", { deviceId }),
      );
    this.drop(deviceId, true);
    return this.ok(generation, this.record(p));
  }
  async isConnected(generation: number, deviceId: string) {
    return this.ok(generation, this.links.has(deviceId));
  }
  async known(generation: number, deviceIds: readonly string[]) {
    return this.ok(
      generation,
      this.options.peripherals
        .filter((p) => deviceIds.includes(p.id))
        .map((p) => this.record(p)),
    );
  }
  async connected(generation: number, services: readonly string[]) {
    const wanted = services.map(fullUUID);
    return this.ok(
      generation,
      this.options.peripherals
        .filter(
          (p) =>
            this.links.has(p.id) &&
            p.services.some((s) => wanted.includes(fullUUID(s.uuid))),
        )
        .map((p) => this.record(p, this.mtus.get(p.id))),
    );
  }

  async discover(
    generation: number,
    deviceId: string,
  ): Promise<NativeResult<NativeGattTree>> {
    if (!this.links.has(deviceId))
      return this.fail(generation, failure("DeviceNotConnected", { deviceId }));
    const mine = this.handles().filter((h) => h.peripheral.id === deviceId);
    const services = [
      ...new Map(mine.map((h) => [h.serviceHandle, h])).values(),
    ].map((h) => ({
      deviceId,
      handle: h.serviceHandle + this.offset(h.peripheral),
      uuid: h.serviceUuid,
      isPrimary: true,
    }));
    const characteristics: NativeCharacteristic[] = mine.map((h) => ({
      deviceId,
      handle: h.handle,
      uuid: fullUUID(h.characteristic.uuid),
      serviceHandle: h.serviceHandle + this.offset(h.peripheral),
      serviceUUID: h.serviceUuid,
      isReadable: Boolean(h.characteristic.read),
      isWritableWithResponse: Boolean(h.characteristic.write),
      isWritableWithoutResponse: Boolean(h.characteristic.writeWithoutResponse),
      isNotifiable: Boolean(h.characteristic.notify),
      isNotifying: false,
      isIndicatable: false,
      value: null,
    }));
    return this.ok(generation, {
      deviceId,
      services,
      characteristics,
      descriptors: [],
    });
  }

  /** The link, once a protected operation is allowed on it: pairs if it must. */
  private async admit(
    h: Handle,
    operation: VirtualOperation,
  ): Promise<{ link: VirtualLink } | { error: BleErrorDetails }> {
    const deviceId = h.peripheral.id;
    const link = this.links.get(deviceId);
    const at = {
      deviceId,
      serviceUUID: h.serviceUuid,
      characteristicUUID: fullUUID(h.characteristic.uuid),
    };
    if (!link) return { error: failure("DeviceNotConnected", at) };
    if (!h.characteristic.authenticated?.includes(operation) || link.bonded)
      return { link };
    if (await this.pair(h.peripheral)) return { link };
    // A failed pairing ends the link, as the peripheral closes it.
    link.disconnect();
    const code =
      operation === "read"
        ? "CharacteristicReadFailed"
        : operation === "write"
          ? "CharacteristicWriteFailed"
          : "CharacteristicNotifyChangeFailed";
    return {
      error: failure(code, {
        ...at,
        attErrorCode: 5,
        reason: "Insufficient authentication",
      }),
    };
  }

  /** Passkey entry: Android's armed answer, or the user at the dialog. */
  private async pair(p: VirtualPeripheral): Promise<boolean> {
    const expected = p.passkey?.() ?? null;
    let typed: string | null;
    const answer = this.answers.get(p.id);
    if (answer && answer.until >= Date.now()) {
      this.answers.delete(p.id);
      typed = answer.passkey;
    } else typed = (await this.options.pairing?.(p)) ?? expected;
    const paired = expected === null || typed === expected;
    if (paired) this.bonds.add(p.id);
    return paired;
  }

  async read(generation: number, handle: number) {
    const h = this.handle(handle);
    if (!h?.characteristic.read)
      return this.fail<Uint8Array>(
        generation,
        failure("CharacteristicReadFailed"),
      );
    const admitted = await this.admit(h, "read");
    if ("error" in admitted)
      return this.fail<Uint8Array>(generation, admitted.error);
    try {
      return this.ok(
        generation,
        new Uint8Array(await h.characteristic.read(admitted.link)),
      );
    } catch (thrown) {
      return this.fail<Uint8Array>(
        generation,
        this.attFailure("CharacteristicReadFailed", h, thrown),
      );
    }
  }

  async write(
    generation: number,
    handle: number,
    value: Uint8Array,
    withResponse: boolean,
  ): Promise<NativeVoidResult> {
    const h = this.handle(handle);
    const handler = withResponse
      ? h?.characteristic.write
      : h?.characteristic.writeWithoutResponse;
    if (!h || !handler)
      return this.done(generation, failure("CharacteristicWriteFailed"));
    const link = this.links.get(h.peripheral.id);
    if (!link) return this.done(generation, failure("DeviceNotConnected"));
    // A write without response gets no error back: an unauthenticated one is the peripheral's to handle.
    if (!withResponse) {
      const bytes = new Uint8Array(value);
      later(() => h.characteristic.writeWithoutResponse?.(bytes, link));
      return this.done(generation);
    }
    const admitted = await this.admit(h, "write");
    if ("error" in admitted) return this.done(generation, admitted.error);
    try {
      await h.characteristic.write?.(new Uint8Array(value), admitted.link);
      return this.done(generation);
    } catch (thrown) {
      return this.done(
        generation,
        this.attFailure("CharacteristicWriteFailed", h, thrown),
      );
    }
  }

  private attFailure(
    code: string,
    h: Handle,
    thrown: unknown,
  ): BleErrorDetails {
    return failure(code, {
      deviceId: h.peripheral.id,
      serviceUUID: h.serviceUuid,
      characteristicUUID: fullUUID(h.characteristic.uuid),
      attErrorCode:
        thrown instanceof VirtualAttError ? thrown.attErrorCode : null,
      reason: thrown instanceof Error ? thrown.message : String(thrown),
    });
  }

  async readDescriptor(generation: number) {
    return this.fail<Uint8Array>(generation, failure("DescriptorNotFound"));
  }
  async writeDescriptor(generation: number) {
    return this.done(generation, failure("DescriptorNotFound"));
  }

  async startMonitor(
    generation: number,
    handle: number,
    subscriptionId: string,
  ): Promise<NativeVoidResult> {
    const h = this.handle(handle);
    if (!h?.characteristic.notify)
      return this.done(generation, failure("CharacteristicNotifyChangeFailed"));
    this.monitors.set(subscriptionId, { deviceId: h.peripheral.id, handle });
    const admitted = await this.admit(h, "subscribe");
    if ("error" in admitted) {
      // A refused subscription arrives as an error on the stream, as on the device.
      this.monitors.delete(subscriptionId);
      this.send(this.listeners.notification, {
        generation,
        subscriptionId,
        value: null,
        error: admitted.error,
      });
      return this.done(generation);
    }
    return this.done(generation);
  }

  private notifyFrom(
    p: VirtualPeripheral,
    uuid: string,
    value: Uint8Array,
  ): void {
    const handles = this.handles().filter(
      (h) =>
        h.peripheral.id === p.id &&
        fullUUID(h.characteristic.uuid) === fullUUID(uuid),
    );
    for (const [subscriptionId, m] of this.monitors)
      if (handles.some((h) => h.handle === m.handle))
        this.send(this.listeners.notification, {
          generation: this.generation,
          subscriptionId,
          value: new Uint8Array(value),
          error: null,
        });
  }

  async cancel(
    generation: number,
    transactionId: string,
  ): Promise<NativeVoidResult> {
    this.monitors.delete(transactionId);
    return this.done(generation);
  }
  async rssi(generation: number, deviceId: string) {
    const p = this.peripheral(deviceId);
    return p
      ? this.ok(generation, this.record(p, this.mtus.get(deviceId)))
      : this.fail<NativePeripheral>(generation, failure("DeviceNotFound"));
  }
  async requestMtu(generation: number, deviceId: string, mtu: number) {
    const p = this.peripheral(deviceId);
    if (!p)
      return this.fail<NativePeripheral>(generation, failure("DeviceNotFound"));
    const value = Math.min(mtu, p.mtu ?? 247);
    this.mtus.set(deviceId, value);
    return this.ok(generation, this.record(p, value));
  }
  async requestPriority(generation: number, deviceId: string) {
    return this.rssi(generation, deviceId);
  }
  async setLogLevel(generation: number, level: LogLevel) {
    this.level = level;
    return this.done(generation);
  }
  async logLevel(generation: number) {
    return this.ok(generation, this.level);
  }
}

// Usable without the native module: the helpers a session's user needs.
export { BleSession } from "./session";
export { BleError } from "./errors";
export { findCharacteristics, fullUUID } from "./uuid";
