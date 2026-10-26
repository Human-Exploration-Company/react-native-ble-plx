import { useEffect, useRef, useState } from "react";
import {
  Button,
  PermissionsAndroid,
  Platform,
  ScrollView,
  StyleSheet,
  Text,
  TextInput,
  View,
} from "react-native";
import { openBle } from "react-native-ble-plx";
import type {
  BleSession,
  Characteristic,
  GattTree,
  Peripheral,
  Subscription,
} from "react-native-ble-plx";

async function permissions(): Promise<void> {
  if (Platform.OS !== "android") return;
  const requested =
    Number(Platform.Version) >= 31
      ? [
          PermissionsAndroid.PERMISSIONS.BLUETOOTH_SCAN,
          PermissionsAndroid.PERMISSIONS.BLUETOOTH_CONNECT,
        ]
      : [PermissionsAndroid.PERMISSIONS.ACCESS_FINE_LOCATION];
  const result = await PermissionsAndroid.requestMultiple(requested);
  if (
    requested.some(
      (permission) => result[permission] !== PermissionsAndroid.RESULTS.GRANTED,
    )
  ) {
    throw new Error("Bluetooth permissions were denied");
  }
}
function hex(value: Uint8Array): string {
  return Array.from(value, (byte) => byte.toString(16).padStart(2, "0")).join(
    " ",
  );
}
function parseHex(value: string): Uint8Array {
  const compact = value.replace(/\s/g, "");
  if (!/^(?:[0-9a-fA-F]{2})*$/.test(compact))
    throw new Error("Enter pairs of hexadecimal digits, for example 01 ff");
  return Uint8Array.from(compact.match(/../g) ?? [], (byte) =>
    Number.parseInt(byte, 16),
  );
}

export default function App() {
  const session = useRef<BleSession | null>(null);
  const scan = useRef<Subscription | null>(null);
  const monitor = useRef<Subscription | null>(null);
  const [state, setState] = useState("Opening Bluetooth…");
  const [devices, setDevices] = useState<readonly Peripheral[]>([]);
  const [connected, setConnected] = useState<Peripheral | null>(null);
  const [tree, setTree] = useState<GattTree | null>(null);
  const [selected, setSelected] = useState<Characteristic | null>(null);
  const [input, setInput] = useState("01");
  const [value, setValue] = useState("");
  const [message, setMessage] = useState(
    "Use a BLE test peripheral. Writes change the selected characteristic.",
  );
  const [busy, setBusy] = useState(false);

  useEffect(() => {
    let disposed = false;
    let owned: BleSession | undefined;
    void permissions()
      .then(() =>
        disposed
          ? null
          : openBle({ restoreIdentifier: "company.hec.bleplx.example" }),
      )
      .then(async (opened) => {
        if (!opened) return;
        owned = opened;
        if (disposed) {
          await opened.close();
          return;
        }
        session.current = opened;
        opened.onStateChange(setState, { emitCurrent: true });
        opened.onDisconnect((event) => {
          setConnected((current) =>
            current?.id === event.deviceId ? null : current,
          );
          setTree(null);
          setSelected(null);
          setMessage(
            `Disconnected ${event.deviceId}: ${event.error?.message ?? "complete"}`,
          );
        });
        if (opened.restored?.length) {
          setDevices(opened.restored);
          setMessage(
            `${opened.restored.length} restored peripheral(s); select one to rediscover.`,
          );
        }
      })
      .catch((error: unknown) => {
        if (!disposed) {
          setState("Unavailable");
          setMessage(String(error));
        }
      });
    return () => {
      disposed = true;
      session.current = null;
      scan.current?.remove();
      monitor.current?.remove();
      if (owned) void owned.close();
    };
  }, []);

  function ble(): BleSession {
    if (!session.current) throw new Error("Bluetooth session is not ready");
    return session.current;
  }
  async function run(action: () => Promise<void>) {
    setBusy(true);
    try {
      await action();
    } catch (error) {
      setMessage(String(error));
    } finally {
      setBusy(false);
    }
  }
  async function startScan() {
    await permissions();
    setDevices([]);
    scan.current = ble().scan({ android: { mode: "lowLatency" } }, (result) => {
      if (result.error) {
        setMessage(result.error.message);
        return;
      }
      setDevices((current) => [
        ...current.filter((device) => device.id !== result.device.id),
        result.device,
      ]);
    });
    setMessage("Scanning. Stop when your peripheral appears.");
  }
  async function connect(device: Peripheral) {
    scan.current?.remove();
    monitor.current?.remove();
    if (connected && connected.id !== device.id)
      await ble().cancelConnection(connected.id);
    const active = (await ble().isConnected(device.id))
      ? device
      : await ble().connect(device.id, { timeoutMs: 15000 });
    setConnected(active);
    setTree(await ble().discover(active.id));
    setSelected(null);
    setMessage(`Connected ${active.name ?? active.id}`);
  }
  function select(characteristic: Characteristic) {
    monitor.current?.remove();
    setSelected(characteristic);
    setValue("");
  }
  function startMonitor() {
    if (!selected) return;
    monitor.current?.remove();
    monitor.current = ble().monitor(selected, (result) => {
      if (result.error) setMessage(result.error.message);
      else setValue(hex(result.value));
    });
    setMessage("Monitoring selected characteristic");
  }

  return (
    <ScrollView contentContainerStyle={styles.screen}>
      <Text style={styles.title}>BLE PLX · Expo Modules 2.0</Text>
      <Text accessibilityLiveRegion="polite">Bluetooth: {state}</Text>
      <Text selectable accessibilityLiveRegion="polite">
        {message}
      </Text>
      <View style={styles.row}>
        <Button
          title="Scan"
          disabled={busy || state !== "PoweredOn"}
          onPress={() => {
            void run(startScan);
          }}
        />
        <Button
          title="Stop scan"
          onPress={() => {
            scan.current?.remove();
            setMessage("Scan stopped");
          }}
        />
      </View>
      {devices.map((device) => (
        <View key={device.id} style={styles.card}>
          <Text>
            {device.name ?? device.localName ?? "Unnamed"} · RSSI{" "}
            {device.rssi ?? "?"}
          </Text>
          <Text selectable>{device.id}</Text>
          <Button
            title="Connect & discover"
            disabled={busy || state !== "PoweredOn"}
            onPress={() => {
              void run(() => connect(device));
            }}
          />
        </View>
      ))}
      {connected && (
        <View style={styles.card}>
          <Text>
            Connected: {connected.id} · MTU {connected.mtu}
          </Text>
          <View style={styles.row}>
            <Button
              title="RSSI"
              disabled={busy}
              onPress={() => {
                void run(async () => {
                  setConnected(await ble().rssi(connected.id));
                });
              }}
            />
            {Platform.OS === "android" && (
              <Button
                title="MTU 247"
                disabled={busy}
                onPress={() => {
                  void run(async () => {
                    setConnected(await ble().requestMtu(connected.id, 247));
                  });
                }}
              />
            )}
            <Button
              title="Disconnect"
              disabled={busy}
              onPress={() => {
                void run(async () => {
                  await ble().cancelConnection(connected.id);
                  setConnected(null);
                  setTree(null);
                  setSelected(null);
                });
              }}
            />
          </View>
        </View>
      )}
      {tree?.services.map((service) => (
        <View key={service.handle} style={styles.card}>
          <Text selectable>
            Service {service.uuid} · handle {service.handle}
          </Text>
          {tree.characteristics
            .filter((item) => item.serviceHandle === service.handle)
            .map((item) => (
              <Button
                key={item.handle}
                title={`${selected?.handle === item.handle ? "✓ " : ""}${item.uuid} · ${item.handle}`}
                onPress={() => select(item)}
              />
            ))}
        </View>
      ))}
      {selected && (
        <View style={styles.card}>
          <Text selectable>Characteristic {selected.uuid}</Text>
          <Text selectable>Value (hex): {value || "—"}</Text>
          <Button
            title="Read"
            disabled={busy || !selected.isReadable}
            onPress={() => {
              void run(async () => {
                setValue(hex(await ble().read(selected)));
              });
            }}
          />
          <TextInput
            accessibilityLabel="Write value in hexadecimal"
            autoCapitalize="none"
            value={input}
            onChangeText={setInput}
            style={styles.input}
          />
          <Button
            title="Write hex value"
            disabled={
              busy ||
              !(
                selected.isWritableWithResponse ||
                selected.isWritableWithoutResponse
              )
            }
            onPress={() => {
              void run(async () => {
                await ble().write(selected, parseHex(input), {
                  withResponse: selected.isWritableWithResponse,
                });
                setMessage("Write completed");
              });
            }}
          />
          <Button
            title="Monitor"
            disabled={!(selected.isNotifiable || selected.isIndicatable)}
            onPress={startMonitor}
          />
          <Button
            title="Stop monitoring"
            onPress={() => {
              monitor.current?.remove();
              setMessage("Monitor stopped");
            }}
          />
        </View>
      )}
    </ScrollView>
  );
}
const styles = StyleSheet.create({
  screen: { padding: 24, paddingTop: 64, gap: 16 },
  title: { fontSize: 24, fontWeight: "600" },
  row: { flexDirection: "row", flexWrap: "wrap", gap: 12 },
  card: {
    borderWidth: 1,
    borderColor: "#aaa",
    borderRadius: 12,
    padding: 12,
    gap: 8,
  },
  input: { borderWidth: 1, borderColor: "#888", borderRadius: 6, padding: 10 },
});
