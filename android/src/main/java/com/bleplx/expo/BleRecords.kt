package com.bleplx.expo

import com.bleplx.adapter.Characteristic
import com.bleplx.adapter.Descriptor
import com.bleplx.adapter.Device
import com.bleplx.adapter.ScanResult
import com.bleplx.adapter.Service
import com.bleplx.adapter.errors.BleError
import io.github.expo.modules.v2.Record

@Record
data class BleFailure(
  val code: String,
  val reason: String? = null,
  val attErrorCode: Int? = null,
  val iosErrorCode: Int? = null,
  val androidErrorCode: Int? = null,
  val deviceId: String? = null,
  val serviceUUID: String? = null,
  val characteristicUUID: String? = null,
  val descriptorUUID: String? = null,
)

@Record
data class PeripheralRecord(
  val id: String,
  val name: String? = null,
  val rssi: Int? = null,
  val mtu: Int = 23,
  val manufacturerData: ByteArray? = null,
  val serviceData: Map<String, ByteArray>? = null,
  val serviceUUIDs: List<String>? = null,
  val localName: String? = null,
  val txPowerLevel: Int? = null,
  val solicitedServiceUUIDs: List<String>? = null,
  val rawScanRecord: ByteArray? = null,
  val isConnectable: Boolean? = null,
  val overflowServiceUUIDs: List<String>? = null,
)

@Record
data class ServiceRecord(val handle: Int, val uuid: String, val deviceId: String, val isPrimary: Boolean)

@Record
data class CharacteristicRecord(
  val handle: Int, val uuid: String, val deviceId: String,
  val serviceHandle: Int, val serviceUUID: String,
  val isReadable: Boolean, val isWritableWithResponse: Boolean,
  val isWritableWithoutResponse: Boolean, val isNotifiable: Boolean,
  val isNotifying: Boolean, val isIndicatable: Boolean, val value: ByteArray?,
)

@Record
data class DescriptorRecord(
  val handle: Int, val uuid: String, val deviceId: String,
  val serviceHandle: Int, val serviceUUID: String,
  val characteristicHandle: Int, val characteristicUUID: String, val value: ByteArray?,
)

@Record
data class GattTreeRecord(
  val deviceId: String, val services: List<ServiceRecord>,
  val characteristics: List<CharacteristicRecord>, val descriptors: List<DescriptorRecord>,
)

@Record
data class OpenOptions(val restoreIdentifier: String?, val logLevel: String)
@Record
data class OpenInfo(val state: String, val restored: List<PeripheralRecord>?)
@Record
data class ScanOptions(val services: List<String>?, val allowDuplicates: Boolean, val scanMode: Int, val callbackType: Int, val legacy: Boolean)
@Record
data class ConnectOptions(val timeoutMs: Int?, val autoConnect: Boolean, val requestMtu: Int, val refreshGatt: Boolean, val priority: Int)

@Record
data class VoidResult(val generation: Int, val error: BleFailure? = null)
@Record
data class OpenResult(val generation: Int, val value: OpenInfo? = null, val error: BleFailure? = null)
@Record
data class StringResult(val generation: Int, val value: String? = null, val error: BleFailure? = null)
@Record
data class BooleanResult(val generation: Int, val value: Boolean? = null, val error: BleFailure? = null)
@Record
data class DeviceResult(val generation: Int, val value: PeripheralRecord? = null, val error: BleFailure? = null)
@Record
data class DevicesResult(val generation: Int, val value: List<PeripheralRecord>? = null, val error: BleFailure? = null)
@Record
data class TreeResult(val generation: Int, val value: GattTreeRecord? = null, val error: BleFailure? = null)
@Record
data class BytesResult(val generation: Int, val value: ByteArray? = null, val error: BleFailure? = null)

@Record
data class StateEvent(val generation: Int, val state: String)
@Record
data class ScanEvent(val generation: Int, val scanId: String, val device: PeripheralRecord? = null, val error: BleFailure? = null)
@Record
data class NotificationEvent(val generation: Int, val subscriptionId: String, val value: ByteArray? = null, val error: BleFailure? = null)
@Record
data class DisconnectEvent(val generation: Int, val deviceId: String, val error: BleFailure? = null)
/** Declared so the event set matches iOS; RxAndroidBle does not surface Service Changed, so it is never sent. */
@Record
data class ServicesChangeEvent(val generation: Int, val deviceId: String)

internal fun BleError.record() = BleFailure(
  code = errorCode.name,
  reason = reason ?: internalMessage,
  attErrorCode = androidCode?.takeIf { it in 0..127 },
  androidErrorCode = androidCode?.takeIf { it >= 128 },
  deviceId = deviceID, serviceUUID = serviceUUID,
  characteristicUUID = characteristicUUID, descriptorUUID = descriptorUUID,
)

internal fun Device.record() = PeripheralRecord(
  id = id, name = name, rssi = rssi, mtu = mtu ?: 23,
  serviceUUIDs = servicesUUIDs?.map { it.toString() },
)

internal fun ScanResult.record(): PeripheralRecord {
  val advertisement = advertisementData
  return PeripheralRecord(
    id = deviceId, name = deviceName, rssi = rssi, mtu = mtu,
    manufacturerData = advertisement.manufacturerData?.clone(),
    serviceData = advertisement.serviceData?.mapKeys { it.key.toString() }?.mapValues { it.value.clone() },
    serviceUUIDs = advertisement.serviceUUIDs?.map { it.toString() },
    localName = advertisement.localName, txPowerLevel = advertisement.txPowerLevel,
    solicitedServiceUUIDs = advertisement.solicitedServiceUUIDs?.map { it.toString() },
    rawScanRecord = advertisement.rawScanRecord?.clone(), isConnectable = isConnectable,
    overflowServiceUUIDs = overflowServiceUUIDs?.map { it.toString() },
  )
}

internal fun Service.record() = ServiceRecord(id, uuid.toString(), deviceID, isPrimary)
internal fun Characteristic.record() = CharacteristicRecord(
  id, uuid.toString(), deviceId, serviceID, serviceUUID.toString(),
  isReadable, isWritableWithResponse, isWritableWithoutResponse, isNotifiable,
  isNotifying, isIndicatable, value?.clone(),
)
internal fun Descriptor.record() = DescriptorRecord(
  id, uuid.toString(), deviceId, serviceId, serviceUuid.toString(),
  characteristicId, characteristicUuid.toString(), value?.clone(),
)
