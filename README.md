# BLE PLX for Expo

An independently maintained fork of `react-native-ble-plx`, rebuilt for **Expo SDK
58 / React Native 0.88 and Expo Modules 2.0 beta**. Version 4 is a clean API break.
Swift and Kotlin annotations replace the React Native bridge. TypeScript source
is the public implementation; Bun handles installs, checks, linting, formatting,
tests and package verification.

The radio engines are CoreBluetooth, used directly, on iOS and RxAndroidBle
1.17.2 on Android. RxAndroidBle's internal Base64 and callback formats stop at
the native boundary. Public values are `Uint8Array`, errors retain platform/GATT details,
and discovery preserves numeric handles for duplicate UUIDs.

## Use in an Expo app

Install this fork, rather than the upstream npm release:

```sh
bun add github:Human-Exploration-Company/react-native-ble-plx#v4.0.0-alpha.1
```

This is the first alpha of version 4. The config plugin ships as TypeScript;
consumers do not need a build or install lifecycle script. See the
[release notes](RELEASE.md) and validation limits before using it with hardware.

For Bun apps, apply the included Expo loader patch in the **app's** package.json.
It makes Expo use Bun's native TypeScript loader, matching `slopper-topper`.
Dependency patches do not propagate from this library into consuming apps.
After installing the library, copy the patch matching your installed
`@expo/require-utils` version (58.0.4 and 58.0.6 are included). For 58.0.6:

```sh
mkdir -p patches
cp node_modules/react-native-ble-plx/patches/@expo%2Frequire-utils@58.0.6.patch patches/expo-bun-loader.patch
```

Merge this entry into your app's `patchedDependencies`, then run `bun install`:

```json
{
  "patchedDependencies": {
    "@expo/require-utils@58.0.6": "patches/expo-bun-loader.patch"
  }
}
```

Keep the patch and updated lockfile in your app's repository. Apps already using
the same reference patch need no additional patch. Node uses Expo's own TypeScript
loader without the Bun workaround.

```ts
// app.config.ts
import type { ExpoConfig } from "expo/config";

export default {
  name: "My BLE app",
  slug: "my-ble-app",
  plugins: [
    [
      "react-native-ble-plx",
      {
        bluetoothPermission: "Connect to your sensor.",
        backgroundMode: true,
        neverForLocation: true,
        isBleRequired: false,
      },
    ],
  ],
} satisfies ExpoConfig;
```

Use an Expo development build or a production native build. Expo Go and web do
not include this module. Rebuild after changing plugin options or native code.
Before opening the session, Android requires runtime `BLUETOOTH_SCAN` / `BLUETOOTH_CONNECT` permission on
Android 12+, or fine location on earlier supported versions. When scans derive
location, set `neverForLocation: false` and request fine location too. The default
`neverForLocation: true` can filter some beacons. The example demonstrates the
runtime permission flow. iOS asks through CoreBluetooth using the plugin's
usage description.

## Own one session

```ts
import { findCharacteristics, openBle } from "react-native-ble-plx";

const ble = await openBle({ restoreIdentifier: "my-app.bluetooth" });
const stateListener = ble.onStateChange((state) => console.log(state), {
  emitCurrent: true,
});
const scan = ble.scan({ services: ["180f"] }, (result) => {
  if (result.error) console.error(result.error.code, result.error.reason);
  else console.log(result.device.id, result.device.rssi);
});

// Once a peripheral is selected, stop scanning and connect.
scan.remove();
const device = await ble.connect(selectedDeviceId, { timeoutMs: 15_000 });
const gatt = await ble.discover(device.id);
const battery = findCharacteristics(gatt, "180f", "2a19")[0];
if (battery) {
  const controller = new AbortController();
  const value = await ble.read(battery, { signal: controller.signal });
  console.log(value[0]);
  const monitor = ble.monitor(battery, (result) => {
    if (result.error) console.error(result.error);
    else console.log(result.value);
  });
  monitor.remove();
}

await ble.cancelConnection(device.id);
stateListener.remove();
await ble.close();
```

`selectedDeviceId` comes from your scan UI. Wait for `PoweredOn` before scanning
or connecting. `close()` is idempotent; await it before opening another session.
Subscriptions have idempotent `remove()`. Abort rejects with
`BleError.code === 'OperationCancelled'`; session close rejects pending work with
`SessionClosed`. A disconnect terminates affected monitors. Rediscover after
reconnecting: previous handles reject with `StaleHandle`.

An aborted or timed-out write may already have reached the peripheral. Cancellation
stops waiting and requests cancellation; it cannot undo a transmitted write. Check
the peripheral's state before deciding whether to retry. A repeated `connect()` on
an owned link rejects with `DeviceAlreadyConnected` without disturbing that link.
Consumer callback exceptions are reported asynchronously, after listener dispatch
and lifecycle cleanup have continued.

`ble.restored` contains iOS peripherals delivered during state restoration, or
`null` when no restoration occurred. Open early at launch with the same restore
identifier, inspect these peripherals and rediscover their GATT tree. Android
returns `null`. iOS background execution/restoration still follows system rules;
this library cannot make an app run after the user force-quits it.

The session also provides `state`, `onDisconnect`, `known`, `connected`,
`isConnected`, `readDescriptor`, `writeDescriptor`, `rssi`, `requestMtu`,
`requestPriority`, `setLogLevel`, and `logLevel`. `write` accepts
`{ withResponse: false }`; Android-specific scan/connect/monitor options are
explicitly scoped. MTU and connection-priority requests are Android operations;
the Apple engine retains its platform behavior. Read the exported types in
[`src/types.ts`](src/types.ts) and methods in [`src/session.ts`](src/session.ts).

`monitor()` takes `onReady`, called once the peripheral accepted the
subscription: its CCCD write succeeded, after any pairing that write started
(Android's descriptor write; CoreBluetooth's `didUpdateNotificationStateFor`).
A refusal arrives as the monitor's error instead.

`onServicesChange()` hears a connected peripheral's Service Changed on iOS
(CoreBluetooth's `didModifyServices`). The handles under the changed services
are gone, and monitors on them have already ended with `ServicesChanged`:
discover the device again and subscribe again.

### Android: bonds and the foreground service

`ble.android` is `null` on iOS. On Android it gives what the GATT layer does
not expose:

```ts
const android = ble.android;
if (android) {
  await android.bondState(device.id); // "none" | "bonding" | "bonded"
  // Answer this device's pairing request with a passkey the app knows, so the
  // system shows no dialog; then the protected operation that pairs.
  await android.answerPairing(device.id, "812839");
  const subscription = ble.monitor(characteristic, listener, {
    onReady: () => console.log("paired and subscribed"),
  });
  await android.removeBond(device.id); // a hidden platform method; false if refused
  await android.startForegroundService({ title: "My app", text: "Connected" });
  await android.stopForegroundService();
}
```

The library's manifest declares the `connectedDevice` foreground service and
its permissions; ask for `POST_NOTIFICATIONS` on Android 13+ if the
notification should show. Closing the session stops the service.

### Known gaps

- Android: a peripheral's Service Changed is not surfaced.
  `BluetoothGattCallback.onServiceChanged` (Android 12+) is not forwarded by
  RxAndroidBle 1.17.2's callback, and its `discoverServices()` keeps the
  services it found on a connection. An operation on an invalidated handle
  fails: reconnect, and discover on the new connection.

## Virtual peripherals

`react-native-ble-plx/virtual` opens the same `BleSession` over peripherals
described in JavaScript: no radio, on a simulator, in a browser or in tests.
Each characteristic is a handler; the peripheral notifies through its side
of the link and can close it.

```ts
import { openVirtualBle } from "react-native-ble-plx/virtual";

const ble = await openVirtualBle({
  platform: "android", // follow Android: bonds, answerPairing, MTU requests
  peripherals: [
    {
      id: "AA:BB:CC:DD:EE:FF",
      name: "Thermometer",
      passkey: () => "123456", // pairing by passkey entry
      services: [
        {
          uuid: "181a",
          characteristics: [
            { uuid: "2a6e", read: () => new Uint8Array([0x10, 0x09]) },
            {
              uuid: "ff01",
              notify: true,
              authenticated: ["subscribe"], // the first subscription pairs
              writeWithoutResponse: (value, link) => link.notify("ff01", value),
            },
          ],
        },
      ],
    },
  ],
});
```

A protected operation on an unbonded link pairs, as the system would: on
Android an armed `answerPairing` answers it; otherwise `pairing` stands in
for the user at the dialog (by default typing the right passkey). A wrong
passkey fails the operation with ATT error 5 and ends the link. `present`
takes a peripheral off the air: a scan misses it and a connect waits for it.

## Develop with Bun and Nix

```sh
nix develop
bun install --frozen-lockfile
bun run verify
bun run verify:package
bun run doctor
bun run export:native

# Supported native build host: x64 Linux or Apple ARM64 with Xcode
nix develop .#native
bun run android
# or: bun run ios
```

`.bun-version`, `packageManager` and the Nix archives pin the same dated Bun
canary. `bun check`, `bun lint`, `bun fmt`, and `bun test` are built-ins. There is
no project Babel, Jest, ESLint, Prettier, Flow or Bob configuration. The example
uses Noxcturnal. Node 24 remains available for native tooling that requires it.
A narrow locked patch lets Expo's config loader use Bun's native TypeScript
loader; it is copied from `slopper-topper`.

The config plugin ships directly as `app.plugin.ts`. There is no generated
JavaScript entry point or plugin build step. The tracked Expo loader patch makes
this work with Bun. `bun run verify:package` packs the library, installs it in an
isolated app with the shipped patch, and checks plugin loading and native mods
under both Bun and Node. CI runs the same check.
`bun pm pack --destination dist` builds a distributable archive.
`bun run agents:setup` installs relevant Expo agent skills locally.

ARM Linux can run all TypeScript checks and export both Hermes bundles using the
pinned source-built compiler. Google's Linux native build-tools/NDK require x64.
iOS builds require macOS, full Xcode and CocoaPods. CI builds debug and minified
release Android targets and the iOS simulator target on supported hosts.

## Migration and validation

There is no `BleManager` compatibility facade, device class hierarchy, public
transaction ID, or Base64 public API. Replace manager construction with
`await openBle()`, explicit session ownership, flat GATT snapshots and
`AbortSignal`. Historical documentation and native example projects were removed.
See [the reviewed plan and verification record](MIGRATION.md).

This migration targets the APIs introduced in [Expo Modules 2.0](https://expo.dev/blog/an-early-look-at-expo-modules-2-0)
and [SDK 58](https://expo.dev/changelog/sdk-58). Native compilation and physical
BLE validation are separate from TypeScript tests and Metro exports. Before
shipping, run the native CI targets and test scanning, cancellation, duplicate
UUIDs, notification teardown, reconnect, background restoration, and permissions
on real iOS and Android devices.

Apache-2.0. Original BLE work by Polidea and dotintent; see [LICENSE](LICENSE).
