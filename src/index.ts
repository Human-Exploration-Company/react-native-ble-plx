import { requireNativeModule } from "expo";
import type { NativeBlePlx } from "./NativeBlePlx";
import { BleSession } from "./session";
import type { OpenOptions } from "./types";

export function openBle(options: OpenOptions = {}): Promise<BleSession> {
  return BleSession.open(requireNativeModule<NativeBlePlx>("BlePlx"), options);
}

export { BleSession } from "./session";
export { BleError, bleErrorCodes } from "./errors";
export type { BleErrorCode, BleErrorDetails } from "./errors";
export { fullUUID, findCharacteristics } from "./uuid";
export type * from "./types";
