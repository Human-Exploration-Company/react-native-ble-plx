# Expo-first BLE migration plan

Status: implemented and reviewed with Opus 5.5; supported-host native builds and
physical-device validation remain before release.

## Direction

Maintain this repository as an independent Expo-native BLE library, targeting Expo
SDK 58 / React Native 0.88 and the Expo Modules 2.0 beta. Keep the package identity
for the fork, but make a major-version break rather than retaining a second legacy
React Native bridge. JavaScript-facing implementation, examples, plugins, tooling,
and tests will be strict TypeScript, executed with Bun.

The existing code has separate Flow implementation and handwritten TypeScript
declarations, Objective-C RCT exports, Java ReactContextBaseJavaModule exports,
bridge-specific map/array conversions, global device events, two old example apps,
and Yarn/Babel/Jest/Bob/ESLint/Flow build chains. Replace these rather than layering
Expo registration over the old bridge.

## Implementation sequence

1. **Reproducible tooling.** Adapt `~/slopper-topper`'s locked Nix flake: the same
   dated Bun canary mechanism on Linux x64/ARM64 and Apple ARM64, Node 24 for native tooling,
   and a separate native shell with JDK, Android SDK/NDK and CocoaPods on macOS.
   Pin Bun consistently in Nix, package metadata, local scripts and CI. Use Bun's
   built-in check/lint/fmt/test and a single workspace lockfile. Copy only relevant
   agent instructions; omit Convex, UI-framework and unrelated app conventions.
2. **Verify the real native surface.** Inspect the installed SDK 58 modules core,
   Swift macros, Android v2 compiler and upstream module examples. Record native
   operations, event/error payloads, cancellation, restoration and threading before
   migration. Scaffold a temporary standalone Expo module to confirm current
   packaging and build integration; do not replace this library with an app.
3. **One typed public contract.** Replace Flow and duplicated `.d.ts` files with
   TypeScript source and inferred implementation declarations. Preserve useful BLE
   operations (scanning, connection/disconnection, discovery, GATT read/write/
   notifications, transactions, RSSI, MTU, priority, restoration and logging).
   Remove obsolete platform APIs and compatibility fallbacks. Use typed Expo native
   bindings and named object event payloads instead of ambient DeviceEventEmitter,
   stringified JSON errors and positional event arrays. Prefer typed records and
   native binary values where verified on both platforms; avoid unchecked `any`.
4. **Expo Modules 2.0 bindings.** Replace Objective-C and React Java module exports
   with annotated Swift and Kotlin classes (`@ExpoModule`, `@JS`, typed events and
   records). Enable the actual Android v2 compiler and Expo autolinking. Retain the
   existing proven BLE engines (MultiplatformBleAdapter 0.2.0 on Apple and the
   internal RxAndroidBle adapter), removing bridge-specific conversions. Serialize
   native state appropriately, keep blocking work off the JS thread, settle each
   operation once, cancel subscriptions/operations and clean up on module teardown.
   Do not handwrite macro/compiler-generated internals or use the old Expo DSL as
   a fallback without documenting an actual API gap.
5. **One Expo integration app.** Replace both old examples with a Bun workspace Expo
   SDK 58 development-build app using CNG. Exercise permissions, state, scan,
   connect/discover/read/write/notify/disconnect and cleanup. Modernize the config
   plugin, package exports and packed loading. Remove obsolete generated app native
   projects, legacy tooling, obsolete CI matrices and stale setup instructions.
6. **Behavior and distribution verification.** Use Bun tests for lifecycle races,
   cancellation, errors, event routing, notification cleanup and typed public usage.
   Run Bun check/lint/fmt, frozen install, package packing/inspection, Expo config,
   Doctor, autolinking and iOS/Android JS exports. Build native example targets where
   the host supports them; validate minified Android release registration as well
   as debug. Clearly distinguish static/package checks from actual native builds
   and physical BLE testing. Update README, migration guidance and CI with the
   commands that actually work.

## Accepted Opus 5.5 review decisions

- Replace the old convenience classes with `openBle()` and one explicitly owned
  `BleSession`. Use readonly peripheral/GATT snapshots and native numeric handles
  to support duplicate UUIDs. Keep transaction identifiers internal and accept
  `AbortSignal` for cancellation. Use callbacks for scan/notification subscriptions.
- Use one module session, not SharedObject: explicit close is necessary either way,
  and the adapter ownership does not benefit from another GC-driven lifecycle.
  Native generation IDs guard every operation/event, with a TS guard as a backstop.
- Use `Uint8Array` publicly, Swift `Data`, and Kotlin `ByteArray`. Both runtimes copy
  inputs during decoding. Android returns `ArrayBuffer`, Apple returns `Uint8Array`;
  normalize once in TypeScript. Base64 conversion stays inside the retained engines.
- Return concrete native result records and unwrap into a typed `BleError` in TS.
  Native thrown errors carry only code/message/stack, so do not rely on arbitrary
  native exception properties to preserve GATT/platform error details.
- Return buffered restored peripherals from `openBle()`, rather than an event that
  can disappear before listeners exist. Open early with the same restore identifier.
- Ship strict TypeScript source, compatible with exact optional property types and
  unchecked index access. SDK type generation is not authoritative: the verified
  scanner emits `unknown` for Data and non-erasable enums. Handwrite a precise native
  binding and verify native build compatibility separately.
- Ship the TypeScript config plugin directly and include the tracked Expo loader
  patch from `slopper-topper`. Bun consumer apps apply it through their own
  `patchedDependencies`; packed loading must pass under patched Bun and Node.
- Pin the current dated Bun canary, `1.4.4-canary.20261025.1`, in Nix/package/CI.
- Swift callback adaptation must settle once under a lock and dispatch adapter work
  onto its serial queue. Android v2 Promise already settles once; native teardown
  must also settle pending operations and suppress obsolete callbacks.
- Native compilation, the old Apple adapter under current Xcode, and minified R8
  registration remain explicit verification requirements; TS tests cannot prove them.

## Evidence

- [Expo SDK 58 release notes](https://expo.dev/changelog/sdk-58): Modules 2.0 beta
  on iOS and Android; faster direct native calls; SDK 58 uses React Native 0.88.
- [Expo Modules 2.0 introduction](https://expo.dev/blog/an-early-look-at-expo-modules-2-0):
  annotated native classes, typed records/events, and build-time bindings.
- Locally installed `~/slopper-topper/node_modules/expo-modules-core@58.0.24` has
  the Swift macros and Android v2 runtime/Gradle integration. Android uses
  `io.github.expo.modules.v2` and `expoModule { v2 true }`, not the 1.0 DSL.
- The local host is ARM64 Linux: Apple builds require macOS/Xcode; Google's
  Android NDK/build-tools are x64 on Linux. Native validation needs a supported
  builder, and cannot be replaced by passing TypeScript tests.

## Verification record

Verified locally on ARM64 Linux with Bun `1.4.4-canary.20261025.1`
(`bun --revision`: `1.4.4-canary.1+a8fcd319b`):

- Locked install; strict Bun type checking, lint and formatting.
- 26 Bun tests covering session/open/close/disconnect races, abort cancellation,
  obsolete events, duplicate UUIDs, binary views, error fields and Expo plugin mods.
- Expo Doctor: 20/20 checks pass.
- Expo CNG prebuild for iOS and Android; no checked-in generated app projects.
- Noxcturnal exports both iOS and Android Hermes bundles.
- Nix evaluates both development shells and Hermes packages on all three hosts.
- Android debug **and** release Kotlin/Java compile successfully. This runs the
  real v2 compiler and generates record codecs and module discovery hints.
- Expo's Android `compileDebugKotlin` succeeds. Disassembling the generated
  `ExpoModulesV2ModuleList.getModules()` confirms it contains `BlePlxModule`.
- Apple autolinking resolves the `BlePlx` pod and `BlePlxModule` class. The podspec
  lives in `ios/BlePlx.podspec`, matching its actual CocoaPods module name.
- All Swift files pass `swiftc -parse` with Swift 6.2.4. Opus also typechecked the
  engine, conversions and records against stand-in adapter/lock modules with the
  Expo macro attributes removed, in Swift 5 and Swift 6 language modes. These
  checks catch syntax and engine type errors, but do **not** validate Expo macros,
  the real Apple adapter, CocoaPods or CoreBluetooth.
- The packed archive includes native sources, TypeScript exports, `app.plugin.ts`
  and the Expo loader patch. An isolated consumer applies the shipped patch, then
  resolves the TypeScript plugin and applies iOS/Android mods under Bun and Node.

The native shell includes build-tools 36 and 37: AGP defaults library targets to
36, while the Expo SDK 58 app template explicitly selects 37. Both must exist in
Nix's read-only SDK; Gradle cannot install a missing component into `/nix/store`.

Remaining external validation: iOS Swift/macro compilation and CocoaPods under
Xcode, complete Android APK builds including R8, and physical BLE behavior. CI
contains the supported-host native build jobs; those jobs have not been run from
this working tree. A compile or bundle export is not evidence of radio behavior.
See [the device checklist](docs/VALIDATION.md).

## First alpha review fixes

`4.0.0-alpha.1` includes the migration and the follow-up Claude Opus 5.5 review
fixes. Established connections reject repeat connect attempts without replacing
their ownership token; failed Android attempts release their token. Disconnect
bookkeeping finishes before consumer callbacks run, and callback exceptions are
reported asynchronously so other listeners and subscriptions can finish cleanup.
Native state/log-level strings are checked before entering public literal unions.
Closed discovery consistently reports `SessionClosed`; native session injection
is marked internal, and write cancellation uncertainty is documented.

The config plugin ships directly as `app.plugin.ts`. SDK 58 discovers and loads
that source under Node 24; the tracked `@expo/require-utils@58.0.4` patch from
`slopper-topper` makes its synchronous loader use native `require()` under Bun
instead of `Module._compile`. The patch is included in the archive. Bun consumer
apps must apply it through their own `patchedDependencies`; dependency patches do
not propagate.
There is no JavaScript plugin entry or plugin build step. `bun run verify:package`
checks the actual packed TypeScript entry and native mods in an isolated patched
consumer under Bun and Node. CI runs the same package check.
