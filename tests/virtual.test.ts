/** Virtual peripherals, through the same BleSession an app uses. */
import { describe, expect, test } from "bun:test";
import { BleError } from "../src/errors";
import { findCharacteristics } from "../src/uuid";
import {
  openVirtualBle,
  type VirtualLink,
  type VirtualPeripheral,
} from "../src/virtual";

const SERVICE = "0000ff00-0000-1000-8000-00805f9b34fb";
const OPEN = "0000ff01-0000-1000-8000-00805f9b34fb";
const SECURE = "0000ff02-0000-1000-8000-00805f9b34fb";

/** A peripheral with an open readable value and a protected notify-and-write channel. */
function echo(options: { present?: () => boolean } = {}) {
  const heard: Uint8Array[] = [];
  let link: VirtualLink | null = null;
  let closed = 0;
  const peripheral: VirtualPeripheral = {
    id: "AA:BB:CC:DD:EE:FF",
    name: "Echo 01",
    mtu: 100,
    passkey: () => "123456",
    ...(options.present ? { present: options.present } : {}),
    services: [
      {
        uuid: SERVICE,
        characteristics: [
          { uuid: OPEN, read: () => new Uint8Array([1, 2, 3]) },
          {
            uuid: SECURE,
            notify: true,
            authenticated: ["subscribe"],
            writeWithoutResponse: (value, from) => {
              heard.push(value);
              from.notify(SECURE, value.toReversed());
            },
          },
        ],
      },
    ],
    connected: (l) => {
      link = l;
    },
    disconnected: () => {
      closed++;
    },
  };
  return {
    peripheral,
    heard,
    link: () => link,
    closed: () => closed,
  };
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 10));

async function linked(
  platform: "ios" | "android",
  pairing?: () => Promise<string | null>,
) {
  const board = echo();
  const ble = await openVirtualBle({
    platform,
    peripherals: [board.peripheral],
    ...(pairing ? { pairing } : {}),
  });
  const device = await ble.connect(board.peripheral.id, {
    android: { requestMtu: 247 },
  });
  const tree = await ble.discover(device.id);
  const [open] = findCharacteristics(tree, SERVICE, OPEN);
  const [secure] = findCharacteristics(tree, SERVICE, SECURE);
  if (!open || !secure) throw new Error("the tree has both");
  return { ble, board, device, open, secure };
}

describe("virtual peripherals", () => {
  test("are found by a scan filtered by their service", async () => {
    const board = echo();
    const ble = await openVirtualBle({
      platform: "ios",
      peripherals: [board.peripheral],
    });
    const names: (string | null)[] = [];
    const scan = ble.scan({ services: [SERVICE] }, (r) =>
      names.push(r.device?.localName ?? null),
    );
    await settle();
    scan.remove();
    expect(names).toEqual(["Echo 01"]);
    await ble.close();
  });

  test("connect, discover and read, with the MTU each platform settles on", async () => {
    const android = await linked("android");
    expect(android.device.mtu).toBe(100);
    expect(await android.ble.read(android.open)).toEqual(
      new Uint8Array([1, 2, 3]),
    );
    expect(android.secure.isNotifiable).toBe(true);
    expect(android.secure.isWritableWithoutResponse).toBe(true);
    await android.ble.close();
    const ios = await linked("ios");
    expect(ios.device.mtu).toBe(100);
    await ios.ble.close();
  });

  test("a protected subscription pairs by passkey; the bond lasts", async () => {
    const { ble, board, device, secure } = await linked("ios");
    const values: Uint8Array[] = [];
    let ready = false;
    ble.monitor(
      secure,
      (r) => {
        if (r.value) values.push(r.value);
      },
      { onReady: () => (ready = true) },
    );
    await settle();
    expect(ready).toBe(true);
    expect(board.link()?.bonded).toBe(true);
    await ble.write(secure, new Uint8Array([1, 2]), { withResponse: false });
    await settle();
    expect(board.heard).toEqual([new Uint8Array([1, 2])]);
    expect(values).toEqual([new Uint8Array([2, 1])]);
    await ble.cancelConnection(device.id);
    expect(board.closed()).toBe(1);
    await ble.close();
  });

  test("a wrong passkey refuses the subscription as insufficient authentication and ends the link", async () => {
    const { ble, board, secure } = await linked("ios", async () => "000000");
    const errors: BleError[] = [];
    const disconnected: string[] = [];
    ble.onDisconnect((d) => disconnected.push(d.deviceId));
    ble.monitor(secure, (r) => {
      if (r.error) errors.push(r.error);
    });
    await settle();
    expect(errors[0]?.attErrorCode).toBe(5);
    expect(board.link()?.bonded).toBe(false);
    expect(disconnected).toEqual([board.peripheral.id]);
    await ble.close();
  });

  test("Android answers the pairing with the armed passkey, and holds the bond", async () => {
    const { ble, board, secure } = await linked("android", async () => {
      throw new Error("the system dialog never shows");
    });
    const android = ble.android;
    if (!android) throw new Error("Android has bonds");
    expect(await android.bondState(board.peripheral.id)).toBe("none");
    await android.answerPairing(board.peripheral.id, "123456");
    ble.monitor(secure, () => {});
    await settle();
    expect(await android.bondState(board.peripheral.id)).toBe("bonded");
    expect(await android.removeBond(board.peripheral.id)).toBe(true);
    expect(await android.bondState(board.peripheral.id)).toBe("none");
    await ble.close();
  });

  test("iOS has no bonds to see", async () => {
    const { ble } = await linked("ios");
    expect(ble.android).toBeNull();
    await ble.close();
  });

  test("the peripheral closes the link", async () => {
    const { ble, board } = await linked("ios");
    const disconnected: string[] = [];
    ble.onDisconnect((d) => disconnected.push(d.deviceId));
    board.link()?.disconnect();
    await settle();
    expect(disconnected).toEqual([board.peripheral.id]);
    await ble.close();
  });

  test("on iOS, Service Changed ends the device's monitors and is heard; the device discovers again", async () => {
    const { ble, board, device, secure } = await linked("ios");
    const errors: BleError[] = [];
    const changed: string[] = [];
    ble.onServicesChange((c) => changed.push(c.deviceId));
    ble.monitor(secure, (r) => {
      if (r.error) errors.push(r.error);
    });
    await settle();
    board.link()?.servicesChanged();
    await settle();
    expect(errors.map((e) => e.code)).toEqual(["ServicesChanged"]);
    expect(changed).toEqual([board.peripheral.id]);
    const tree = await ble.discover(device.id);
    expect(findCharacteristics(tree, SERVICE, SECURE)).toHaveLength(1);
    await ble.close();
  });

  test("Android's engine does not surface Service Changed", async () => {
    const { ble, board, secure } = await linked("android");
    const changed: string[] = [];
    const errors: BleError[] = [];
    ble.onServicesChange((c) => changed.push(c.deviceId));
    await ble.android?.answerPairing(board.peripheral.id, "123456");
    ble.monitor(secure, (r) => {
      if (r.error) errors.push(r.error);
    });
    await settle();
    board.link()?.servicesChanged();
    await settle();
    expect(changed).toEqual([]);
    expect(errors).toEqual([]);
    await ble.close();
  });

  test("a connect waits for an absent peripheral until its timeout", async () => {
    let here = false;
    const board = echo({ present: () => here });
    const ble = await openVirtualBle({
      platform: "android",
      peripherals: [board.peripheral],
    });
    const failed = await ble
      .connect(board.peripheral.id, { timeoutMs: 50 })
      .then(
        () => null,
        (e: unknown) => e,
      );
    expect(failed instanceof BleError && failed.code).toBe("OperationTimedOut");
    const later = ble.connect(board.peripheral.id, { timeoutMs: 2000 });
    here = true;
    expect((await later).id).toBe(board.peripheral.id);
    await ble.close();
  });
});
