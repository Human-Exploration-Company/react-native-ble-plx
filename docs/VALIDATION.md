The Bun suite runs against a typed fake of the exact native contract. It checks
session ownership, close and abort races, stale connection handles, duplicate
UUID discovery, event routing, binary normalization and native error detail
preservation. Plugin tests evaluate Expo's native mods through introspection.

These tests do not simulate a Bluetooth radio. Use the example on physical iOS
and Android devices before releasing. In particular, test permission denial,
Bluetooth power transitions, connection timeout, aborted reads and writes,
notifications during disconnect, rediscovery after reconnect, duplicate UUIDs,
nonzero byte-view offsets, background scanning and iOS restoration after an
OS-initiated relaunch. On iOS, also check a protected subscription settles
only after pairing, and Service Changed (change a peripheral's table while
bonded and connected: monitors end with `ServicesChanged`, `onServicesChange`
fires, and a new discovery works). Test the minified Android release on a device too; a
successful R8 build alone cannot prove runtime registration.

## Compiling the Android sources without Gradle

On a host where Google's build tools do not run (ARM Linux), the module's
Kotlin and Java still compile with `kotlinc` and `javac` against the SDK's
`android.jar`, RxJava 2.2.21, Reactive Streams 1.0.3, RxAndroidBle 1.17.2
(the AAR's `classes.jar`), `androidx.annotation` and Expo Modules 2.0's
`expo-modules-v2-react` classes. This checks types and API levels only: it
does not run the Expo compiler plugin, R8 or the manifest merger, and proves
nothing about a device. The bonds, the passkey answer, the foreground
service and `onReady` were checked so, against Android 37 and
`expo-modules-v2-react` 0.2.5.

## Builds and simulators

The Iris Relax app's EAS development builds compile the library with Gradle
(Android) and Xcode (iOS, the CoreBluetooth engine), and both run on EAS's
simulators. On an iOS simulator, which has no Bluetooth radio, opening a
session with a restore identifier creates the manager and settles; that
check caught CoreBluetooth throwing when a manager with a restore
identifier is made without its delegate. Neither simulator has a radio, so
scanning, links, pairing and subscriptions still want a device.
