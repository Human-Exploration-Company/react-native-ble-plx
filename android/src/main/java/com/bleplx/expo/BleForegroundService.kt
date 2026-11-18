package com.bleplx.expo

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.os.Build
import android.os.IBinder

/**
 * A foreground service of type `connectedDevice`, so the process keeps its
 * links while the app is in the background. It does nothing itself: the
 * session's links live in the module; this only keeps the process alive.
 */
class BleForegroundService : Service() {
  override fun onBind(intent: Intent?): IBinder? = null

  override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
    val title = intent?.getStringExtra(EXTRA_TITLE) ?: "Bluetooth"
    val text = intent?.getStringExtra(EXTRA_TEXT) ?: ""
    val notification = notification(this, title, text)
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
      startForeground(ID, notification, ServiceInfo.FOREGROUND_SERVICE_TYPE_CONNECTED_DEVICE)
    } else {
      startForeground(ID, notification)
    }
    return START_NOT_STICKY
  }

  companion object {
    private const val ID = 0x426c65
    private const val CHANNEL = "com.bleplx.connections"
    private const val EXTRA_TITLE = "title"
    private const val EXTRA_TEXT = "text"

    fun start(context: Context, title: String, text: String) {
      val intent = Intent(context, BleForegroundService::class.java)
        .putExtra(EXTRA_TITLE, title).putExtra(EXTRA_TEXT, text)
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) context.startForegroundService(intent) else context.startService(intent)
    }

    fun stop(context: Context) {
      context.stopService(Intent(context, BleForegroundService::class.java))
    }

    private fun notification(context: Context, title: String, text: String): Notification {
      val launch = context.packageManager.getLaunchIntentForPackage(context.packageName)
      val open = launch?.let { PendingIntent.getActivity(context, 0, it, PendingIntent.FLAG_IMMUTABLE) }
      val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
        val manager = context.getSystemService(NotificationManager::class.java)
        manager.createNotificationChannel(NotificationChannel(CHANNEL, "Bluetooth connections", NotificationManager.IMPORTANCE_LOW))
        Notification.Builder(context, CHANNEL)
      } else {
        @Suppress("DEPRECATION") Notification.Builder(context)
      }
      return builder
        .setContentTitle(title)
        .setContentText(text)
        .setSmallIcon(context.applicationInfo.icon)
        .setOngoing(true)
        .apply { if (open != null) setContentIntent(open) }
        .build()
    }
  }
}
