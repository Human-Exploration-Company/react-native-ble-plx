// @generated from app.plugin.ts by bun run build; do not edit.
var __defProp = Object.defineProperty;
var __getOwnPropNames = Object.getOwnPropertyNames;
var __getOwnPropDesc = Object.getOwnPropertyDescriptor;
var __hasOwnProp = Object.prototype.hasOwnProperty;
function __accessProp(key) {
  return this[key];
}
var __toCommonJS = (from) => {
  var entry = (__moduleCache ??= new WeakMap()).get(from),
    desc;
  if (entry) return entry;
  entry = __defProp({}, "__esModule", { value: true });
  if ((from && typeof from === "object") || typeof from === "function") {
    for (var key of __getOwnPropNames(from))
      if (!__hasOwnProp.call(entry, key))
        __defProp(entry, key, {
          get: __accessProp.bind(from, key),
          enumerable: !(desc = __getOwnPropDesc(from, key)) || desc.enumerable,
        });
  }
  __moduleCache.set(from, entry);
  return entry;
};
var __moduleCache;
var __returnValue = (v) => v;
function __exportSetter(name, newValue) {
  this[name] = __returnValue.bind(null, newValue);
}
var __export = (target, all) => {
  for (var name in all)
    __defProp(target, name, {
      get: all[name],
      enumerable: true,
      configurable: true,
      set: __exportSetter.bind(all, name),
    });
};

// app.plugin.ts
var exports_app_plugin = {};
__export(exports_app_plugin, {
  default: () => app_plugin_default,
});
module.exports = __toCommonJS(exports_app_plugin);
var import_config_plugins = require("@expo/config-plugins");

// package.json
var name = "react-native-ble-plx";
var version = "4.0.0-alpha.1";

// app.plugin.ts
var withBle = (config, options = {}) => {
  const props = options ?? {};
  const neverForLocation = props.neverForLocation ?? true;
  config = import_config_plugins.withInfoPlist(config, (value) => {
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
  config = import_config_plugins.withAndroidManifest(config, (value) => {
    const manifest = value.modResults.manifest;
    import_config_plugins.AndroidConfig.Manifest.ensureToolsAvailable(
      value.modResults,
    );
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
var app_plugin_default = import_config_plugins.createRunOncePlugin(
  withBle,
  name,
  version,
);
