The Bun suite runs against a typed fake of the exact native contract. It checks
session ownership, close and abort races, stale connection handles, duplicate
UUID discovery, event routing, binary normalization and native error detail
preservation. Plugin tests evaluate Expo's native mods through introspection.

These tests do not simulate a Bluetooth radio. Use the example on physical iOS
and Android devices before releasing. In particular, test permission denial,
Bluetooth power transitions, connection timeout, aborted reads and writes,
notifications during disconnect, rediscovery after reconnect, duplicate UUIDs,
nonzero byte-view offsets, background scanning and iOS restoration after an
OS-initiated relaunch. Test the minified Android release on a device too; a
successful R8 build alone cannot prove runtime registration.
