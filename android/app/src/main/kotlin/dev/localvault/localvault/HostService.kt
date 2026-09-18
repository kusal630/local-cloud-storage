package dev.localvault.localvault

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.IBinder
import android.os.PowerManager

/// Keeps the LocalVault host server alive while the app is in the background.
///
/// The Dart shelf server runs on the Flutter engine's isolate; without a
/// foreground service Android may kill the process minutes after the user
/// leaves the app. This service holds a partial wake lock and shows an
/// ongoing notification so the personal cloud stays reachable.
class HostService : Service() {

    companion object {
        const val CHANNEL_ID = "localvault_host"
        const val NOTIFICATION_ID = 8484
        const val ACTION_START = "dev.localvault.localvault.host.START"
        const val ACTION_STOP = "dev.localvault.localvault.host.STOP"
        const val EXTRA_LABEL = "label"
        const val EXTRA_PORT = "port"

        fun start(context: Context, label: String, port: Int) {
            val intent = Intent(context, HostService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_LABEL, label)
                putExtra(EXTRA_PORT, port)
            }
            context.startForegroundService(intent)
        }

        fun stop(context: Context) {
            val intent = Intent(context, HostService::class.java).apply {
                action = ACTION_STOP
            }
            context.startService(intent)
        }
    }

    private var wakeLock: PowerManager.WakeLock? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopSelf()
                return START_NOT_STICKY
            }
            else -> {
                val label = intent?.getStringExtra(EXTRA_LABEL) ?: "LocalVault"
                val port = intent?.getIntExtra(EXTRA_PORT, 8484) ?: 8484
                ensureChannel()
                startForeground(NOTIFICATION_ID, buildNotification(label, port))
                acquireLock()
                return START_STICKY
            }
        }
    }

    private fun ensureChannel() {
        val manager = getSystemService(NotificationManager::class.java) ?: return
        if (manager.getNotificationChannel(CHANNEL_ID) != null) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "LocalVault host",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Keeps your personal cloud reachable"
        }
        manager.createNotificationChannel(channel)
    }

    private fun buildNotification(label: String, port: Int): Notification {
        return Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("$label is running")
            .setContentText("Personal cloud active on port $port")
            .setSmallIcon(getNotificationIcon())
            .setOngoing(true)
            .build()
    }

    private fun getNotificationIcon(): Int {
        val id = resources.getIdentifier(
            "ic_launcher", "mipmap", packageName,
        )
        return if (id != 0) id else android.R.drawable.stat_sys_data_bluetooth
    }

    private fun acquireLock() {
        if (wakeLock?.isHeld == true) return
        val pm = getSystemService(POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "LocalVault:HostLock",
        ).apply {
            acquire(12 * 60 * 60 * 1000L)
        }
    }

    override fun onDestroy() {
        try {
            wakeLock?.release()
        } catch (_: Exception) {
        }
        wakeLock = null
        super.onDestroy()
    }
}
