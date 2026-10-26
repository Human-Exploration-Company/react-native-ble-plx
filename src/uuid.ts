import { BleError } from "./errors";
import type { Characteristic, GattTree } from "./types";

export function fullUUID(uuid: string): string {
  const value = uuid.toLowerCase();
  if (/^[0-9a-f]{4}$/.test(value))
    return `0000${value}-0000-1000-8000-00805f9b34fb`;
  if (/^[0-9a-f]{8}$/.test(value))
    return `${value}-0000-1000-8000-00805f9b34fb`;
  if (
    /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(value)
  )
    return value;
  throw new BleError("InvalidIdentifiers");
}

/** Returns all matches, preserving duplicate UUIDs and their distinct native handles. */
export function findCharacteristics(
  tree: GattTree,
  serviceUUID: string,
  characteristicUUID: string,
): readonly Characteristic[] {
  const service = fullUUID(serviceUUID);
  const characteristic = fullUUID(characteristicUUID);
  return tree.characteristics.filter(
    (value) =>
      fullUUID(value.serviceUUID) === service &&
      fullUUID(value.uuid) === characteristic,
  );
}
