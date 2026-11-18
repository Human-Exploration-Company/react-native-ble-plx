import {
  AndroidConfig,
  createRunOncePlugin,
  withAndroidManifest,
  withInfoPlist,
} from "@expo/config-plugins";
import type { ConfigPlugin } from "@expo/config-plugins";
import { name, version } from "./package.json";

export interface BlePluginOptions {
  readonly bluetoothPermission?: string;
  /** BLE central background mode on iOS. This library does not implement a peripheral. */
  readonly backgroundMode?: boolean;
  /** Android 12+: true asserts scans are never used to derive location; some beacons are filtered. */
  readonly neverForLocation?: boolean;
  readonly isBleRequired?: boolean;
}

const withBle: ConfigPlugin<BlePluginOptions | void> = (config, options) => {
  const props = options ?? {};
  const neverForLocation = props.neverForLocation ?? true;
  config = withInfoPlist(config, (value) => {
    value.modResults.NSBluetoothAlwaysUsageDescription =
      props.bluetoothPermission ??
      "Allow $(PRODUCT_NAME) to connect to Bluetooth devices.";
    if (props.backgroundMode)
      value.modResults.UIBackgroundModes = [
        ...new Set([
          ...(value.modResults.UIBackgroundModes ?? []),
          "bluetooth-central",
        ]),
      ];
    return value;
  });
  config = withAndroidManifest(config, (value) => {
    const manifest = value.modResults.manifest;
    AndroidConfig.Manifest.ensureToolsAvailable(value.modResults);
    const managed = new Set([
      "android.permission.BLUETOOTH",
      "android.permission.BLUETOOTH_ADMIN",
      "android.permission.BLUETOOTH_SCAN",
      "android.permission.BLUETOOTH_CONNECT",
      "android.permission.ACCESS_FINE_LOCATION",
    ]);
    const legacyBluetooth = [
      "android.permission.BLUETOOTH",
      "android.permission.BLUETOOTH_ADMIN",
    ].map((name) => ({
      $: { "android:name": name, "android:maxSdkVersion": "30" },
    }));
    manifest["uses-permission"] = [
      ...(manifest["uses-permission"] ?? []).filter(
        (permission) => !managed.has(permission.$["android:name"]),
      ),
      ...legacyBluetooth,
      {
        $: {
          "android:name": "android.permission.BLUETOOTH_SCAN",
          ...(neverForLocation
            ? { "android:usesPermissionFlags": "neverForLocation" }
            : {}),
        },
      },
      { $: { "android:name": "android.permission.BLUETOOTH_CONNECT" } },
      {
        $: {
          "android:name": "android.permission.ACCESS_FINE_LOCATION",
          ...(neverForLocation ? { "android:maxSdkVersion": "30" } : {}),
        },
      },
    ];
    manifest["uses-feature"] = [
      ...(manifest["uses-feature"] ?? []).filter(
        (feature) =>
          feature.$["android:name"] !== "android.hardware.bluetooth_le",
      ),
      {
        $: {
          "android:name": "android.hardware.bluetooth_le",
          "android:required": props.isBleRequired ? "true" : "false",
        },
      },
    ];
    return value;
  });
  return config;
};
export default createRunOncePlugin(withBle, name, version);
