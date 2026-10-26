import { describe, expect, mock, spyOn, test } from "bun:test";
import { BleSession, bytes } from "../src/session";
import { BleError } from "../src/errors";
import type { BleErrorDetails } from "../src/errors";
import type {
  NativeBlePlx,
  NativeBytes,
  NativeEvents,
  NativeGattTree,
  NativeOpenInfo,
  NativePeripheral,
  NativeResult,
} from "../src/NativeBlePlx";
import { findCharacteristics, fullUUID } from "../src/uuid";

const device: NativePeripheral = {
  id: "device",
  name: "Sensor",
  rssi: -50,
  mtu: 23,
  manufacturerData: null,
  serviceData: null,
  serviceUUIDs: null,
  localName: null,
  txPowerLevel: null,
  solicitedServiceUUIDs: null,
  rawScanRecord: null,
  isConnectable: true,
  overflowServiceUUIDs: null,
};
const characteristic = {
  deviceId: device.id,
  handle: 2,
  uuid: fullUUID("2a19"),
  serviceHandle: 1,
  serviceUUID: fullUUID("180f"),
  isReadable: true,
  isWritableWithResponse: true,
  isWritableWithoutResponse: false,
  isNotifiable: true,
  isNotifying: false,
  isIndicatable: false,
  value: null,
};
const tree: NativeGattTree = {
  deviceId: device.id,
  services: [
    { deviceId: device.id, handle: 1, uuid: fullUUID("180f"), isPrimary: true },
  ],
  characteristics: [characteristic, { ...characteristic, handle: 3 }],
  descriptors: [],
};
function result<T>(value: T, generation = 1): NativeResult<T> {
  return { generation, value, error: null };
}
const done = () => Promise.resolve({ generation: 1, error: null });
function deferred<T>() {
  let resolve: (value: T) => void = () => {
    throw new Error("Uninitialized promise");
  };
  const promise = new Promise<T>((yes) => {
    resolve = yes;
  });
  return { promise, resolve };
}
class FakeNative implements NativeBlePlx {
  readonly listeners: { [K in keyof NativeEvents]: Set<NativeEvents[K]> } = {
    stateChange: new Set(),
    scan: new Set(),
    notification: new Set(),
    disconnect: new Set(),
  };
  addListener<K extends keyof NativeEvents>(
    event: K,
    listener: NativeEvents[K],
  ) {
    this.listeners[event].add(listener);
    return {
      remove: () => {
        this.listeners[event].delete(listener);
      },
    };
  }
  open = mock((): Promise<NativeResult<NativeOpenInfo>> =>
    Promise.resolve(
      result({ state: "PoweredOn" as const, restored: [device] }),
    ),
  );
  close = mock(done);
  state = mock((): Promise<NativeResult<string>> =>
    Promise.resolve(result("PoweredOn")),
  );
  startScan = mock((_generation: number, _id: string) => done());
  stopScan = mock((_generation: number, _id: string) => done());
  connect = mock(() => Promise.resolve(result(device)));
  cancelConnection = mock(() => Promise.resolve(result(device)));
  isConnected = mock(() => Promise.resolve(result(true)));
  known = mock(() => Promise.resolve(result([device])));
  connected = mock(() => Promise.resolve(result([device])));
  discover = mock(() => Promise.resolve(result(tree)));
  read = mock(
    (
      _generation: number,
      _handle: number,
      _tx: string,
    ): Promise<NativeResult<NativeBytes>> =>
      Promise.resolve(result(new Uint8Array([42]).buffer)),
  );
  write = mock((_generation: number, _handle: number, _value: Uint8Array) =>
    done(),
  );
  readDescriptor = mock(() => Promise.resolve(result(new Uint8Array([0]))));
  writeDescriptor = mock(done);
  startMonitor = mock((_generation: number, _handle: number, _id: string) =>
    done(),
  );
  cancel = mock((_generation: number, _id: string) => done());
  rssi = mock(() => Promise.resolve(result(device)));
  requestMtu = mock(() => Promise.resolve(result(device)));
  requestPriority = mock(() => Promise.resolve(result(device)));
  setLogLevel = mock(done);
  logLevel = mock((): Promise<NativeResult<string>> =>
    Promise.resolve(result("None")),
  );
}
async function setup() {
  const native = new FakeNative();
  const session = await BleSession.open(native);
  const gatt = await session.discover(device.id);
  const ref = gatt.characteristics[0];
  if (!ref) throw new Error("Missing fixture characteristic");
  return { native, session, gatt, ref };
}
const flush = () => new Promise<void>((resolve) => queueMicrotask(resolve));

describe("session ownership", () => {
  test("a restored peripheral disconnected during open is not returned as connected", async () => {
    const native = new FakeNative();
    native.open.mockImplementation(() => {
      for (const send of native.listeners.disconnect)
        send({ generation: 1, deviceId: device.id, error: null });
      return Promise.resolve(
        result({ state: "PoweredOn", restored: [device] }),
      );
    });
    const session = await BleSession.open(native);
    expect(session.restored).toEqual([]);
    await expect(session.discover(device.id)).rejects.toMatchObject({
      code: "DeviceNotConnected",
    });
    await session.close();
  });
  test("failed open removes temporary listeners without closing another session", async () => {
    const native = new FakeNative();
    native.open.mockImplementation(() =>
      Promise.resolve({
        generation: 1,
        value: null,
        error: new BleError("SessionAlreadyOpen"),
      }),
    );
    await expect(BleSession.open(native)).rejects.toMatchObject({
      code: "SessionAlreadyOpen",
    });
    expect(
      Object.values(native.listeners).every((value) => value.size === 0),
    ).toBe(true);
    expect(native.close).not.toHaveBeenCalled();
  });
  test("invalid successful open results release the native session", async () => {
    const native = new FakeNative();
    native.open.mockImplementation(() =>
      Promise.resolve({ generation: 1, value: null, error: null }),
    );
    await expect(BleSession.open(native)).rejects.toMatchObject({
      code: "InvalidNativeResult",
    });
    expect(native.close).toHaveBeenCalledTimes(1);
    expect(
      Object.values(native.listeners).every((value) => value.size === 0),
    ).toBe(true);
  });
  test("state changes emitted while opening take precedence over the initial snapshot", async () => {
    const native = new FakeNative();
    native.open.mockImplementation(() => {
      for (const send of native.listeners.stateChange)
        send({ generation: 1, state: "PoweredOff" });
      return Promise.resolve(
        result({ state: "PoweredOn" as const, restored: [device] }),
      );
    });
    const session = await BleSession.open(native);
    const states: string[] = [];
    session.onStateChange((state) => states.push(state), { emitCurrent: true });
    expect(states).toEqual(["PoweredOff"]);
    expect(native.listeners.stateChange.size).toBe(1);
    await session.close();
  });
  test("disconnect before a connect continuation prevents resurrecting a connection", async () => {
    const native = new FakeNative();
    native.open.mockImplementation(() =>
      Promise.resolve(result({ state: "PoweredOn", restored: null })),
    );
    const session = await BleSession.open(native);
    const connecting = deferred<NativeResult<NativePeripheral>>();
    native.connect.mockImplementation(() => connecting.promise);
    const operation = session.connect(device.id);
    connecting.resolve(result(device));
    for (const send of native.listeners.disconnect)
      send({ generation: 1, deviceId: device.id, error: null });
    await expect(operation).rejects.toMatchObject({
      code: "DeviceDisconnected",
    });
    await expect(session.discover(device.id)).rejects.toMatchObject({
      code: "DeviceNotConnected",
    });
    await session.close();
  });
  test("connecting an owned device is rejected without disturbing its disconnect listener", async () => {
    const { native, session, ref } = await setup();
    const disconnected = mock(() => {});
    session.onDisconnect(disconnected);
    await expect(session.connect(device.id)).rejects.toMatchObject({
      code: "DeviceAlreadyConnected",
    });
    expect(native.connect).not.toHaveBeenCalled();
    for (const send of native.listeners.disconnect)
      send({ generation: 1, deviceId: device.id, error: null });
    expect(disconnected).toHaveBeenCalledTimes(1);
    await expect(session.read(ref)).rejects.toMatchObject({
      code: "StaleHandle",
    });
    await session.close();
  });
  test("discover reports a closed session before a missing connection", async () => {
    const { session } = await setup();
    await session.close();
    await expect(session.discover(device.id)).rejects.toMatchObject({
      code: "SessionClosed",
    });
  });
  test("restoration is returned by open, and duplicate UUIDs retain distinct handles", async () => {
    const { session, gatt } = await setup();
    expect(session.restored?.[0]?.id).toBe(device.id);
    expect(
      findCharacteristics(gatt, "180f", "2a19").map((value) => value.handle),
    ).toEqual([2, 3]);
    await session.close();
  });
  test("close rejects pending operations, removes listeners, and is idempotent", async () => {
    const { native, session, ref } = await setup();
    const pending = deferred<NativeResult<NativeBytes>>();
    native.read.mockImplementation(() => pending.promise);
    const operation = session.read(ref);
    const rejected = operation.catch((error: unknown) => error);
    const close = session.close();
    expect(session.close()).toBe(close);
    expect(await rejected).toMatchObject({ code: "SessionClosed" });
    pending.resolve(result(new Uint8Array([99])));
    await close;
    expect(native.close).toHaveBeenCalledTimes(1);
    expect(
      Object.values(native.listeners).every((value) => value.size === 0),
    ).toBe(true);
    await expect(session.state()).rejects.toMatchObject({
      code: "SessionClosed",
    });
  });
  test("disconnect and reconnect invalidate previously discovered handles", async () => {
    const { native, session, ref } = await setup();
    for (const listener of native.listeners.disconnect)
      listener({ generation: 1, deviceId: device.id, error: null });
    await session.connect(device.id);
    await expect(session.read(ref)).rejects.toMatchObject({
      code: "StaleHandle",
    });
    expect(native.read).not.toHaveBeenCalled();
    await session.close();
  });
  test("late discovery cannot bind handles to a new connection", async () => {
    const { native, session } = await setup();
    const pending = deferred<NativeResult<NativeGattTree>>();
    native.discover.mockImplementation(() => pending.promise);
    const discovery = session.discover(device.id);
    for (const listener of native.listeners.disconnect)
      listener({ generation: 1, deviceId: device.id, error: null });
    await session.connect(device.id);
    pending.resolve(result(tree));
    await expect(discovery).rejects.toMatchObject({ code: "StaleHandle" });
    await session.close();
  });
});

describe("listener isolation and native validation", () => {
  test("throwing monitor and disconnect callbacks do not interrupt cleanup or other listeners", async () => {
    const { native, session, ref } = await setup();
    const reported: (() => void)[] = [];
    const queue = spyOn(globalThis, "queueMicrotask").mockImplementation(
      (callback) => {
        reported.push(callback);
      },
    );
    try {
      const first = session.monitor(ref, () => {
        throw new Error("monitor callback");
      });
      const monitorListener = mock(() => {});
      const other = session.monitor(ref, monitorListener);
      session.onDisconnect(() => {
        throw new Error("disconnect callback");
      });
      const disconnected = mock(() => {});
      session.onDisconnect(disconnected);
      for (const send of native.listeners.disconnect)
        send({ generation: 1, deviceId: device.id, error: null });
      expect(first.closed).toBe(true);
      expect(other.closed).toBe(true);
      expect(monitorListener).toHaveBeenCalledTimes(1);
      expect(disconnected).toHaveBeenCalledTimes(1);
      expect(native.cancel).toHaveBeenCalledTimes(2);
      expect(reported).toHaveLength(2);
      for (const report of reported) expect(report).toThrow(/callback/);
    } finally {
      queue.mockRestore();
      await session.close();
    }
  });
  test("throwing state callbacks are reported without blocking later callbacks", async () => {
    const { native, session } = await setup();
    const reported: (() => void)[] = [];
    const queue = spyOn(globalThis, "queueMicrotask").mockImplementation(
      (callback) => {
        reported.push(callback);
      },
    );
    try {
      session.onStateChange(
        () => {
          throw new Error("state callback");
        },
        { emitCurrent: true },
      );
      const listener = mock(() => {});
      session.onStateChange(listener);
      for (const send of native.listeners.stateChange)
        send({ generation: 1, state: "PoweredOff" });
      expect(listener).toHaveBeenCalledWith("PoweredOff");
      expect(reported).toHaveLength(2);
      for (const report of reported) expect(report).toThrow("state callback");
    } finally {
      queue.mockRestore();
      await session.close();
    }
  });
  test("unknown native states cannot open a session and release its native owner", async () => {
    const native = new FakeNative();
    native.open.mockImplementation(() =>
      Promise.resolve(result({ state: "FutureState", restored: null })),
    );
    await expect(BleSession.open(native)).rejects.toMatchObject({
      code: "InvalidNativeResult",
    });
    expect(native.close).toHaveBeenCalledTimes(1);
  });
  test("native state and log-level strings are validated before becoming public unions", async () => {
    const { native, session } = await setup();
    native.state.mockImplementation(() =>
      Promise.resolve(result("FutureState")),
    );
    await expect(session.state()).rejects.toMatchObject({
      code: "InvalidNativeResult",
    });
    native.logLevel.mockImplementation(() =>
      Promise.resolve(result("FutureLevel")),
    );
    await expect(session.logLevel()).rejects.toMatchObject({
      code: "InvalidNativeResult",
    });
    await session.close();
  });
  test("malformed state events are reported without corrupting the current state", async () => {
    const { native, session } = await setup();
    const reported: (() => void)[] = [];
    const queue = spyOn(globalThis, "queueMicrotask").mockImplementation(
      (callback) => {
        reported.push(callback);
      },
    );
    try {
      const listener = mock(() => {});
      session.onStateChange(listener);
      for (const send of native.listeners.stateChange)
        send({ generation: 1, state: "FutureState" });
      expect(listener).not.toHaveBeenCalled();
      session.onStateChange(listener, { emitCurrent: true });
      expect(listener).toHaveBeenCalledWith("PoweredOn");
      expect(reported).toHaveLength(1);
      for (const report of reported) expect(report).toThrow(BleError);
    } finally {
      queue.mockRestore();
      await session.close();
    }
  });
});

describe("cancellation and streams", () => {
  test("pre-aborted operations never start native work", async () => {
    const { native, session, ref } = await setup();
    await expect(
      session.read(ref, { signal: AbortSignal.abort() }),
    ).rejects.toMatchObject({ code: "OperationCancelled" });
    expect(native.read).not.toHaveBeenCalled();
    await session.close();
  });
  test("abort cancels the exact transaction and ignores its late result", async () => {
    const { native, session, ref } = await setup();
    const pending = deferred<NativeResult<NativeBytes>>();
    native.read.mockImplementation(() => pending.promise);
    const controller = new AbortController();
    const operation = session.read(ref, { signal: controller.signal });
    controller.abort("screen left");
    await expect(operation).rejects.toMatchObject({
      code: "OperationCancelled",
      cause: "screen left",
    });
    expect(native.cancel.mock.calls[0]?.[1]).toBe(
      native.read.mock.calls[0]?.[2],
    );
    pending.resolve(result(new Uint8Array([99])));
    await flush();
    await session.close();
  });
  test("replacing a scan and obsolete generations cannot deliver results", async () => {
    const { native, session } = await setup();
    const oldListener = mock(() => {});
    const old = session.scan({}, oldListener);
    const oldId = native.startScan.mock.calls[0]?.[1];
    const listener = mock(() => {});
    const current = session.scan({}, listener);
    const id = native.startScan.mock.calls[1]?.[1];
    if (!oldId || !id) throw new Error("Missing scan identifiers");
    for (const send of native.listeners.scan) {
      send({ generation: 1, scanId: oldId, device, error: null });
      send({ generation: 0, scanId: id, device, error: null });
      send({ generation: 1, scanId: id, device, error: null });
    }
    expect(old.closed).toBe(true);
    expect(oldListener).not.toHaveBeenCalled();
    expect(listener).toHaveBeenCalledTimes(1);
    current.remove();
    current.remove();
    expect(native.stopScan).toHaveBeenCalledTimes(2);
    await session.close();
  });
  test("notifications route by subscription and disconnect terminates them once", async () => {
    const { native, session, ref } = await setup();
    const listener = mock(() => {});
    const stream = session.monitor(ref, listener);
    const id = native.startMonitor.mock.calls[0]?.[2];
    if (!id) throw new Error("Missing monitor identifier");
    for (const send of native.listeners.notification)
      send({
        generation: 1,
        subscriptionId: id,
        value: new Uint8Array([7]).buffer,
        error: null,
      });
    for (const send of native.listeners.disconnect)
      send({ generation: 1, deviceId: device.id, error: null });
    for (const send of native.listeners.notification)
      send({
        generation: 1,
        subscriptionId: id,
        value: new Uint8Array([8]),
        error: null,
      });
    expect(stream.closed).toBe(true);
    expect(listener).toHaveBeenCalledTimes(2);
    expect(native.cancel).toHaveBeenCalledWith(1, id);
    await session.close();
  });
});

test("binary views retain their offset and Android buffers normalize", async () => {
  const { native, session, ref } = await setup();
  const view = new Uint8Array([0, 1, 2, 3]).subarray(1, 3);
  await session.write(ref, view);
  expect(native.write.mock.calls[0]?.[2]).toBe(view);
  expect(bytes(view)).toEqual(new Uint8Array([1, 2]));
  expect(await session.read(ref)).toEqual(new Uint8Array([42]));
  await session.close();
});
test("native error details survive without JSON or untyped exception properties", async () => {
  const { native, session, ref } = await setup();
  const details: BleErrorDetails = {
    code: "CharacteristicReadFailed",
    reason: "Authentication required",
    attErrorCode: 5,
    iosErrorCode: null,
    androidErrorCode: 133,
    deviceId: device.id,
    serviceUUID: characteristic.serviceUUID,
    characteristicUUID: characteristic.uuid,
    descriptorUUID: null,
  };
  native.read.mockImplementation(() =>
    Promise.resolve({ generation: 1, value: null, error: details }),
  );
  await expect(session.read(ref)).rejects.toMatchObject({
    ...details,
    name: "BleError",
  });
  expect(new BleError("DeviceNotConnected")).toBeInstanceOf(Error);
  await session.close();
});
test("UUID normalization rejects malformed identifiers", () => {
  expect(fullUUID("180F")).toBe("0000180f-0000-1000-8000-00805f9b34fb");
  expect(() => fullUUID("nope")).toThrow(BleError);
});
