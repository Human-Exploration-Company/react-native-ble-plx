# 4.0.0-alpha.1

First alpha of the Expo-first clean-break migration. Targets Expo SDK 58,
React Native 0.88, and Expo Modules 2.0 beta.

- Swift/Kotlin Modules 2.0 bindings replace the legacy React Native bridge.
- Strict TypeScript sessions own BLE explicitly, use `Uint8Array` values and
  `AbortSignal`, and reject handles from an earlier connection or session.
- Bun canary and Nix replace the previous JavaScript tooling. One CNG Expo
  example uses Noxcturnal.
- A TypeScript config plugin generates its JavaScript entry with Bun, keeping
  package consumers working under both Bun and Node.
- Review fixes preserve connection ownership on repeated connect attempts,
  isolate listener exceptions, and validate native state/log-level strings.

This release breaks the previous `BleManager` API. See [README](README.md) for
installation and usage, and [MIGRATION](MIGRATION.md) for the reviewed plan and
validation evidence. Cancellation cannot undo a write already sent to a device.

Local checks cover strict types, lint, formatting, Bun regression tests, plugin
packaging, Expo Doctor, native bundle exports, and Android debug/release JVM
compilation. Xcode macro/CocoaPods builds, full Android APK/R8 builds and physical
BLE validation remain outstanding; see [the checklist](docs/VALIDATION.md).
