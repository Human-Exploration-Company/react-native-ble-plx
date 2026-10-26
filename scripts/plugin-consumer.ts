import { strict as assert } from "node:assert";
import { existsSync } from "node:fs";
import { dirname, join } from "node:path";
import { compileModsAsync } from "@expo/config-plugins";
import { resolveConfigPluginFunctionWithInfo } from "@expo/config-plugins/build/utils/plugin-resolver.js";

// Copied into an isolated packed consumer by verify-package.ts, then run with Bun and Node.
const { plugin, pluginFile } = resolveConfigPluginFunctionWithInfo(
  process.cwd(),
  "react-native-ble-plx",
);
assert(pluginFile.endsWith("/app.plugin.ts"));
assert.equal(existsSync(join(dirname(pluginFile), "app.plugin.js")), false);
assert.equal(typeof plugin, "function");
const config = await compileModsAsync(
  plugin(
    { name: "Packed BLE consumer", slug: "packed-ble-consumer" },
    { backgroundMode: true, neverForLocation: true },
  ),
  {
    projectRoot: process.cwd(),
    platforms: ["ios", "android"],
    introspect: true,
    ignoreExistingNativeFiles: true,
  },
);
assert.deepEqual(
  config._internal?.modResults?.ios?.infoPlist?.UIBackgroundModes,
  ["bluetooth-central"],
);
assert(config._internal?.modResults?.android?.manifest);
console.log(
  `${process.versions.bun ? "Bun" : "Node"}: packed app.plugin.ts resolves and applies native mods`,
);
