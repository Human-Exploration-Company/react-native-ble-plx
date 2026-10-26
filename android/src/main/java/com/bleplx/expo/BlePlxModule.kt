package com.bleplx.expo

import android.util.Base64
import com.bleplx.adapter.BleAdapter
import com.bleplx.adapter.BleModule
import com.bleplx.adapter.ConnectionOptions
import com.bleplx.adapter.ConnectionState
import com.bleplx.adapter.Device
import com.bleplx.adapter.OnErrorCallback
import com.bleplx.adapter.OnSuccessCallback
import com.bleplx.adapter.RefreshGattMoment
import com.bleplx.adapter.errors.BleError
import com.bleplx.adapter.errors.BleErrorCode
import io.github.expo.modules.v2.Event
import io.github.expo.modules.v2.ExpoModule
import io.github.expo.modules.v2.JS
import io.github.expo.modules.v2.Module
import io.github.expo.modules.v2.async.Promise
import io.github.expo.modules.v2.react.androidContext
import io.reactivex.schedulers.Schedulers
import java.util.concurrent.Executors
import java.util.concurrent.RejectedExecutionException

/** All adapter calls, callbacks, session state and pending operations share this executor. */
@ExpoModule("BlePlx")
class BlePlxModule : Module() {
  private val worker = Executors.newSingleThreadExecutor { task ->
    Thread(task, "BlePlx").apply { isDaemon = true }
  }
  private val scheduler = Schedulers.from(worker)
  private var adapter: BleAdapter? = null
  private var generation = 0
  private var requestCounter = 0
  private var scanId: String? = null
  private val monitors = mutableSetOf<String>()
  private val connectionTokens = mutableMapOf<String, Any>()
  private val pending = mutableMapOf<String, () -> Unit>()

  @Event(name = "stateChange") val stateChanged = event<StateEvent>()
  @Event(name = "scan") val scanResult = event<ScanEvent>()
  @Event(name = "notification") val notification = event<NotificationEvent>()
  @Event(name = "disconnect") val disconnected = event<DisconnectEvent>()

  @JS
  fun open(options: OpenOptions): Promise<OpenResult> {
    val promise = Promise<OpenResult>()
    val applicationContext = androidContext.applicationContext
    enqueue {
      if (adapter != null) {
        promise.resolve(OpenResult(generation, error = BleFailure("SessionAlreadyOpen")))
        return@enqueue
      }
      val current = ++generation
      try {
        val created = BleModule(applicationContext, scheduler)
        adapter = created
        created.createClient(options.restoreIdentifier, { state ->
          if (accept(current) && stateChanged.isObserved) stateChanged(StateEvent(current, state))
        }, { /* Android has no state restoration. */ })
        created.setLogLevel(options.logLevel)
        promise.resolve(OpenResult(current, OpenInfo(created.currentState, null)))
      } catch (error: Throwable) {
        dispose()
        promise.resolve(OpenResult(current, error = failure(error)))
      }
    }
    return promise
  }

  @JS
  fun close(generation: Int): Promise<VoidResult> {
    val promise = Promise<VoidResult>()
    enqueue {
      if (accept(generation)) dispose()
      promise.resolve(VoidResult(generation))
    }
    return promise
  }

  override fun onDestroy() {
    enqueue {
      dispose()
      worker.shutdown()
    }
  }

  @JS
  fun state(generation: Int): Promise<StringResult> = request(generation, failed = { StringResult(generation, error = it) }) { adapter, done, _ ->
    done(StringResult(generation, adapter.currentState))
  }

  @JS
  fun startScan(generation: Int, scanId: String, options: ScanOptions): Promise<VoidResult> =
    request(generation, failed = { VoidResult(generation, it) }) { adapter, done, _ ->
      adapter.stopDeviceScan()
      this.scanId = scanId
      adapter.startDeviceScan(options.services?.toTypedArray(), options.scanMode, options.callbackType, options.legacy, { device ->
        if (accept(generation) && this.scanId == scanId && scanResult.isObserved) {
          scanResult(ScanEvent(generation, scanId, device.record()))
        }
      }, { error ->
        if (accept(generation) && this.scanId == scanId) {
          this.scanId = null
          scanResult(ScanEvent(generation, scanId, error = error.record()))
        }
      })
      done(VoidResult(generation))
    }

  @JS
  fun stopScan(generation: Int, scanId: String): Promise<VoidResult> =
    request(generation, failed = { VoidResult(generation, it) }) { adapter, done, _ ->
      if (this.scanId == scanId) {
        this.scanId = null
        adapter.stopDeviceScan()
      }
      done(VoidResult(generation))
    }

  @JS
  fun connect(generation: Int, deviceId: String, options: ConnectOptions): Promise<DeviceResult> =
    deviceRequest(generation, "connect:$deviceId") { adapter, success, error ->
      if (connectionTokens.containsKey(deviceId)) {
        error.onError(BleError(BleErrorCode.DeviceAlreadyConnected, "This session already owns the connection", null))
        return@deviceRequest
      }
      val connectionToken = Any()
      var didConnect = false
      connectionTokens[deviceId] = connectionToken
      try {
        adapter.connectToDevice(deviceId, ConnectionOptions(
          options.autoConnect, options.requestMtu,
          if (options.refreshGatt) RefreshGattMoment.ON_CONNECTED else null,
          options.timeoutMs?.toLong(), options.priority,
        ), OnSuccessCallback { device ->
          didConnect = true
          success.onSuccess(device)
        }, { state ->
          if (accept(generation) && connectionTokens[deviceId] === connectionToken && state == ConnectionState.DISCONNECTED) {
            connectionTokens.remove(deviceId)
            if (didConnect) disconnected(DisconnectEvent(generation, deviceId))
          }
        }, OnErrorCallback { failure ->
          if (!didConnect && connectionTokens[deviceId] === connectionToken) connectionTokens.remove(deviceId)
          error.onError(failure)
        })
      } catch (failure: Throwable) {
        if (!didConnect && connectionTokens[deviceId] === connectionToken) connectionTokens.remove(deviceId)
        throw failure
      }
    }

  @JS
  fun cancelConnection(generation: Int, deviceId: String): Promise<DeviceResult> =
    deviceRequest(generation) { adapter, success, error -> adapter.cancelDeviceConnection(deviceId, success, error) }

  @JS
  fun isConnected(generation: Int, deviceId: String): Promise<BooleanResult> =
    request(generation, failed = { BooleanResult(generation, error = it) }) { adapter, done, fail ->
      adapter.isDeviceConnected(deviceId, { done(BooleanResult(generation, it)) }, { fail(it.record()) })
    }

  @JS
  fun known(generation: Int, deviceIds: List<String>): Promise<DevicesResult> =
    request(generation, failed = { DevicesResult(generation, error = it) }) { adapter, done, fail ->
      adapter.getKnownDevices(deviceIds.toTypedArray(), { done(DevicesResult(generation, it.map(Device::record))) }, { fail(it.record()) })
    }

  @JS
  fun connected(generation: Int, services: List<String>): Promise<DevicesResult> =
    request(generation, failed = { DevicesResult(generation, error = it) }) { adapter, done, fail ->
      adapter.getConnectedDevices(services.toTypedArray(), { done(DevicesResult(generation, it.map(Device::record))) }, { fail(it.record()) })
    }

  @JS
  fun discover(generation: Int, deviceId: String, transactionId: String): Promise<TreeResult> =
    request(generation, transactionId, { TreeResult(generation, error = it) }) { adapter, done, fail ->
      adapter.discoverAllServicesAndCharacteristicsForDevice(deviceId, transactionId, {
        try {
          val services = adapter.getServicesForDevice(deviceId)
          val characteristics = services.flatMap { adapter.getCharacteristicsForService(it.id) }
          val descriptors = characteristics.flatMap { adapter.descriptorsForCharacteristic(it.id) }
          done(TreeResult(generation, GattTreeRecord(deviceId, services.map { it.record() }, characteristics.map { it.record() }, descriptors.map { it.record() })))
        } catch (error: Throwable) { fail(failure(error)) }
      }, { fail(it.record()) })
    }

  @JS
  fun read(generation: Int, handle: Int, transactionId: String): Promise<BytesResult> =
    request(generation, transactionId, { BytesResult(generation, error = it) }) { adapter, done, fail ->
      adapter.readCharacteristic(handle, transactionId, { done(BytesResult(generation, it.value?.clone() ?: byteArrayOf())) }, { fail(it.record()) })
    }

  @JS
  fun write(generation: Int, handle: Int, value: ByteArray, withResponse: Boolean, transactionId: String): Promise<VoidResult> =
    request(generation, transactionId, { VoidResult(generation, it) }) { adapter, done, fail ->
      adapter.writeCharacteristic(handle, Base64.encodeToString(value, Base64.NO_WRAP), withResponse, transactionId,
        { done(VoidResult(generation)) }, { fail(it.record()) })
    }

  @JS
  fun readDescriptor(generation: Int, handle: Int, transactionId: String): Promise<BytesResult> =
    request(generation, transactionId, { BytesResult(generation, error = it) }) { adapter, done, fail ->
      adapter.readDescriptor(handle, transactionId, { done(BytesResult(generation, it.value?.clone() ?: byteArrayOf())) }, { fail(it.record()) })
    }

  @JS
  fun writeDescriptor(generation: Int, handle: Int, value: ByteArray, transactionId: String): Promise<VoidResult> =
    request(generation, transactionId, { VoidResult(generation, it) }) { adapter, done, fail ->
      adapter.writeDescriptor(handle, Base64.encodeToString(value, Base64.NO_WRAP), transactionId,
        { done(VoidResult(generation)) }, { fail(it.record()) })
    }

  @JS
  fun startMonitor(generation: Int, handle: Int, subscriptionId: String, subscriptionType: String?): Promise<VoidResult> =
    request(generation, failed = { VoidResult(generation, it) }) { adapter, done, _ ->
      monitors.add(subscriptionId)
      adapter.monitorCharacteristic(handle, subscriptionId, subscriptionType, { characteristic ->
        if (accept(generation) && monitors.contains(subscriptionId) && notification.isObserved) {
          notification(NotificationEvent(generation, subscriptionId, characteristic.value?.clone() ?: byteArrayOf()))
        }
      }, { error ->
        if (accept(generation) && monitors.remove(subscriptionId)) notification(NotificationEvent(generation, subscriptionId, error = error.record()))
      })
      done(VoidResult(generation))
    }

  @JS
  fun cancel(generation: Int, transactionId: String): Promise<VoidResult> =
    request(generation, failed = { VoidResult(generation, it) }) { adapter, done, _ ->
      monitors.remove(transactionId)
      pending.remove(transactionId)?.invoke()
      adapter.cancelTransaction(transactionId)
      done(VoidResult(generation))
    }

  @JS
  fun rssi(generation: Int, deviceId: String, transactionId: String): Promise<DeviceResult> =
    deviceRequest(generation, transactionId) { adapter, success, error -> adapter.readRSSIForDevice(deviceId, transactionId, success, error) }

  @JS
  fun requestMtu(generation: Int, deviceId: String, mtu: Int, transactionId: String): Promise<DeviceResult> =
    deviceRequest(generation, transactionId) { adapter, success, error -> adapter.requestMTUForDevice(deviceId, mtu, transactionId, success, error) }

  @JS
  fun requestPriority(generation: Int, deviceId: String, priority: Int, transactionId: String): Promise<DeviceResult> =
    deviceRequest(generation, transactionId) { adapter, success, error -> adapter.requestConnectionPriorityForDevice(deviceId, priority, transactionId, success, error) }

  @JS
  fun setLogLevel(generation: Int, level: String): Promise<VoidResult> =
    request(generation, failed = { VoidResult(generation, it) }) { adapter, done, _ ->
      adapter.setLogLevel(level)
      done(VoidResult(generation))
    }

  @JS
  fun logLevel(generation: Int): Promise<StringResult> = request(generation, failed = { StringResult(generation, error = it) }) { adapter, done, _ ->
    done(StringResult(generation, adapter.logLevel))
  }

  private fun deviceRequest(generation: Int, token: String? = null, body: (BleAdapter, OnSuccessCallback<Device>, OnErrorCallback) -> Unit): Promise<DeviceResult> =
    request(generation, token, { DeviceResult(generation, error = it) }) { adapter, done, fail ->
      body(adapter, OnSuccessCallback { done(DeviceResult(generation, it.record())) }, OnErrorCallback { fail(it.record()) })
    }

  private fun <R> request(generation: Int, token: String? = null, failed: (BleFailure) -> R, body: (BleAdapter, (R) -> Unit, (BleFailure) -> Unit) -> Unit): Promise<R> {
    val promise = Promise<R>()
    enqueue {
      val active = adapter
      if (active == null || !accept(generation)) {
        promise.resolve(failed(BleFailure("SessionClosed")))
        return@enqueue
      }
      val key = token ?: "request:${++requestCounter}"
      if (pending.containsKey(key)) {
        promise.resolve(failed(BleFailure("OperationStartFailed", "An operation with this identifier is already pending")))
        return@enqueue
      }
      val cancellation = { promise.resolve(failed(BleFailure(if (accept(generation)) "OperationCancelled" else "SessionClosed"))); Unit }
      pending[key] = cancellation
      val done: (R) -> Unit = { result -> enqueue {
        if (pending[key] === cancellation) {
          pending.remove(key)
          promise.resolve(result)
        }
      } }
      val fail: (BleFailure) -> Unit = { done(failed(it)) }
      try { body(active, done, fail) } catch (error: Throwable) { fail(failure(error)) }
    }
    return promise
  }

  private fun accept(generation: Int) = adapter != null && this.generation == generation

  private fun dispose() {
    val active = adapter
    adapter = null
    generation++
    scanId = null
    monitors.clear()
    connectionTokens.clear()
    val cancellations = pending.values.toList()
    pending.clear()
    cancellations.forEach { it() }
    active?.destroyClient()
  }

  private fun enqueue(body: () -> Unit) {
    try { worker.execute(body) } catch (_: RejectedExecutionException) { /* Runtime has already been destroyed. */ }
  }

  private fun failure(error: Throwable): BleFailure = when (error) {
    is BleError -> error.record()
    is SecurityException -> BleFailure("BluetoothUnauthorized", error.message)
    else -> BleFailure("UnknownError", error.message ?: error.javaClass.simpleName)
  }
}
