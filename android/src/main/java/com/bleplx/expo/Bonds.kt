package com.bleplx.expo

import android.annotation.SuppressLint
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.os.Build
import android.os.Handler
import android.os.Looper

/**
 * The system's bonds, which the GATT layer does not expose: the bond state
 * of a device, removing a bond, and answering the next pairing request for a
 * device with a passkey the app already knows, so the system shows no
 * dialog. Every callback settles once.
 */
internal class Bonds(private val context: Context) {
  private val main = Handler(Looper.getMainLooper())

  private fun device(id: String): BluetoothDevice? {
    val adapter: BluetoothAdapter? = context.getSystemService(BluetoothManager::class.java)?.adapter
    return try { adapter?.getRemoteDevice(id) } catch (_: IllegalArgumentException) { null }
  }

  /** "none", "bonding" or "bonded"; null for an address that is not one. */
  @SuppressLint("MissingPermission")
  fun state(id: String): String? = device(id)?.let { name(it.bondState) }

  /** Removes the system's bond. A hidden method, so it may be refused. */
  @SuppressLint("MissingPermission")
  fun remove(id: String): Boolean {
    val device = device(id) ?: return false
    if (device.bondState == BluetoothDevice.BOND_NONE) return true
    return try {
      device.javaClass.getMethod("removeBond").invoke(device) as? Boolean ?: false
    } catch (_: ReflectiveOperationException) {
      false
    }
  }

  /**
   * Answers pairing requests for `id` with `passkey` (6 digits) until the
   * pairing ends or `timeoutMs` passes. It does not start pairing: the
   * caller's next operation does (a protected read, write or subscription),
   * or [create]. False for an address that is not one.
   */
  @SuppressLint("MissingPermission")
  fun answer(id: String, passkey: String, timeoutMs: Long): Boolean {
    val target = device(id) ?: return false
    var settled = false
    lateinit var receiver: BroadcastReceiver
    val finish = {
      if (!settled) {
        settled = true
        main.removeCallbacksAndMessages(receiver)
        try { context.unregisterReceiver(receiver) } catch (_: IllegalArgumentException) {}
      }
    }
    receiver = object : BroadcastReceiver() {
      override fun onReceive(context: Context, intent: Intent) {
        val device = intent.device() ?: return
        if (device.address != target.address) return
        when (intent.action) {
          BluetoothDevice.ACTION_PAIRING_REQUEST -> {
            val variant = intent.getIntExtra(BluetoothDevice.EXTRA_PAIRING_VARIANT, BluetoothDevice.ERROR)
            // LE passkey entry arrives as the PIN variant; the passkey is its digits.
            if (variant == BluetoothDevice.PAIRING_VARIANT_PIN || variant == PAIRING_VARIANT_PASSKEY) {
              if (device.setPin(passkey.toByteArray(Charsets.US_ASCII))) abortBroadcast()
            }
          }
          BluetoothDevice.ACTION_BOND_STATE_CHANGED -> {
            val state = intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.ERROR)
            if (state == BluetoothDevice.BOND_BONDED || state == BluetoothDevice.BOND_NONE) finish()
          }
        }
      }
    }
    val filter = IntentFilter().apply {
      addAction(BluetoothDevice.ACTION_PAIRING_REQUEST)
      addAction(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
      // Ahead of the system's own dialog, so it can be answered silently.
      priority = IntentFilter.SYSTEM_HIGH_PRIORITY - 1
    }
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
      context.registerReceiver(receiver, filter, Context.RECEIVER_EXPORTED)
    } else {
      context.registerReceiver(receiver, filter)
    }
    main.postAtTime({ finish() }, receiver, android.os.SystemClock.uptimeMillis() + timeoutMs)
    return true
  }

  /** Starts pairing at the system's level. */
  @SuppressLint("MissingPermission")
  fun create(id: String): Boolean = device(id)?.createBond() ?: false

  private fun Intent.device(): BluetoothDevice? =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
      getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
    } else {
      @Suppress("DEPRECATION") getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
    }

  private fun name(state: Int) = when (state) {
    BluetoothDevice.BOND_BONDED -> "bonded"
    BluetoothDevice.BOND_BONDING -> "bonding"
    else -> "none"
  }

  private companion object {
    /** `BluetoothDevice.PAIRING_VARIANT_PASSKEY`, hidden from the SDK. */
    const val PAIRING_VARIANT_PASSKEY = 1
  }
}
