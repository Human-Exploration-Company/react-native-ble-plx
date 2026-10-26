import type { ExpoConfig } from "expo/config";

// SDK 58 supports this option; @expo/config-types has not exposed it yet.
const experiments: ExpoConfig["experiments"] & {
  noxcturnalTransformWorker: boolean;
} = { noxcturnalTransformWorker: true };

const config: ExpoConfig = {
  name: "BLE PLX",
  slug: "ble-plx-example",
  version: "1.0.0",
  ios: { bundleIdentifier: "company.hec.bleplx.example" },
  android: { package: "company.hec.bleplx.example" },
  plugins: [
    ["react-native-ble-plx", { backgroundMode: true, neverForLocation: true }],
  ],
  experiments,
};
export default config;
