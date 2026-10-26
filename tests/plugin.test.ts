import { expect, test } from "bun:test";
import { compileModsAsync } from "@expo/config-plugins";
import { resolveConfigPluginFunctionWithInfo } from "@expo/config-plugins/build/utils/plugin-resolver";
import withBle from "../app.plugin.ts";

test("Expo resolves the generated plugin entry without loading the radio", () => {
  const { plugin, pluginFile } = resolveConfigPluginFunctionWithInfo(
    `${import.meta.dir}/../example`,
    "react-native-ble-plx",
  );
  expect(pluginFile).toEndWith("/app.plugin.js");
  expect(typeof plugin).toBe("function");
  expect(plugin({ name: "BLE test", slug: "ble-test" }, {})).toMatchObject({
    name: "BLE test",
  });
});

async function introspect(neverForLocation: boolean) {
  return compileModsAsync(
    withBle(
      { name: "BLE test", slug: "ble-test" },
      { backgroundMode: true, neverForLocation },
    ),
    {
      projectRoot: `${import.meta.dir}/../example`,
      platforms: ["ios", "android"],
      introspect: true,
      ignoreExistingNativeFiles: true,
    },
  );
}
test("plugin emits the central background mode and scoped Android permissions", async () => {
  const config = await introspect(true);
  const manifest = config._internal?.modResults?.android?.manifest;
  expect(manifest).toBeDefined();
  // Introspection output is dependency-owned JSON; assert its observable structure.
  expect(manifest).toMatchObject({
    manifest: {
      "uses-permission": expect.arrayContaining([
        {
          $: {
            "android:name": "android.permission.BLUETOOTH_SCAN",
            "android:usesPermissionFlags": "neverForLocation",
          },
        },
        {
          $: {
            "android:name": "android.permission.ACCESS_FINE_LOCATION",
            "android:maxSdkVersion": "30",
          },
        },
      ]),
    },
  });
  expect(config._internal?.modResults?.ios?.infoPlist).toMatchObject({
    UIBackgroundModes: ["bluetooth-central"],
  });
});
test("location-enabled scans leave fine location available on Android 12+", async () => {
  const config = await introspect(false);
  expect(config._internal?.modResults?.android?.manifest).toMatchObject({
    manifest: {
      "uses-permission": expect.arrayContaining([
        { $: { "android:name": "android.permission.BLUETOOTH_SCAN" } },
        { $: { "android:name": "android.permission.ACCESS_FINE_LOCATION" } },
      ]),
    },
  });
});
