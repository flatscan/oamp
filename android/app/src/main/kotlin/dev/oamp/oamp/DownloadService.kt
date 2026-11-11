package dev.oamp.oamp

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
 * Keeps OAmp running, with a "Downloading N of M" notification, while music
 * downloads for offline use. The downloading itself happens in Dart; this
 * only holds the process in the foreground so Android doesn't stop it when
 * the screen goes off.
 */
class DownloadService : Service() {
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }
        val done = intent?.getIntExtra(EXTRA_DONE, 0) ?: 0
        val total = intent?.getIntExtra(EXTRA_TOTAL, 0) ?: 0
        val notification = build(done, total)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
        return START_NOT_STICKY
    }

    /** Android 15 caps a data sync service at a few hours; Dart starts it again if work remains. */
    override fun onTimeout(startId: Int, fgsType: Int) {
        stopForeground(STOP_FOREGROUND_REMOVE)
        stopSelf()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun build(done: Int, total: Int): Notification {
        val manager = getSystemService(NOTIFICATION_SERVICE) as NotificationManager
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            // Normal importance without sound or vibration: a low importance
            // channel is treated as silent, which many phones hide from the
            // lock screen, and a download that carries on with the screen off
            // is exactly when it should be visible.
            manager.createNotificationChannel(
                NotificationChannel(
                    CHANNEL_ID,
                    "Downloads",
                    NotificationManager.IMPORTANCE_DEFAULT,
                ).apply {
                    setSound(null, null)
                    enableVibration(false)
                    setShowBadge(false)
                    lockscreenVisibility = Notification.VISIBILITY_PUBLIC
                },
            )
        }
        val open = PendingIntent.getActivity(
            this,
            0,
            packageManager.getLaunchIntentForPackage(packageName),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val builder = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
        }
        return builder
            .setSmallIcon(R.drawable.ic_stat_oamp)
            .setContentTitle("Downloading music")
            .setContentText(if (total > 0) "$done of $total tracks" else "Getting ready")
            .setProgress(total, done.coerceAtMost(total), total == 0)
            .setOngoing(true)
            .setVisibility(Notification.VISIBILITY_PUBLIC)
            .setOnlyAlertOnce(true)
            .setContentIntent(open)
            .build()
    }

    companion object {
        private const val CHANNEL_ID = "oamp_downloads_v2"
        private const val NOTIFICATION_ID = 4202
        private const val EXTRA_DONE = "done"
        private const val EXTRA_TOTAL = "total"
        private const val ACTION_STOP = "dev.oamp.oamp.STOP_DOWNLOADS"

        fun show(context: Context, done: Int, total: Int) {
            val intent = Intent(context, DownloadService::class.java)
                .putExtra(EXTRA_DONE, done)
                .putExtra(EXTRA_TOTAL, total)
            context.startForegroundService(intent)
        }

        fun hide(context: Context) {
            // Starting a service only to stop it can itself be refused from the
            // background, so stop it directly.
            context.stopService(Intent(context, DownloadService::class.java))
        }
    }
}
