package com.phantom.phantom_messenger

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.IBinder

/**
 * Lightweight foreground service that keeps the Flutter process alive while the
 * app is in the background.
 *
 * The Dart isolate — including the ntfy.sh SSE subscription — keeps running as
 * long as this service is active. Incoming messages are therefore received and
 * can trigger local notifications even when Phantom is not the focused app.
 *
 * The service is started on AppLifecycleState.paused and stopped on .resumed
 * via the `phantom/messaging` Flutter method channel.
 */
class PhantomMessagingService : Service() {

    companion object {
        const val CHANNEL_ID   = "phantom_background"
        const val NOTIF_ID     = 44
        const val ACTION_START = "phantom.messaging.START"
        const val ACTION_STOP  = "phantom.messaging.STOP"

        fun startIntent(ctx: Context): Intent =
            Intent(ctx, PhantomMessagingService::class.java).apply {
                action = ACTION_START
            }

        fun stopIntent(ctx: Context): Intent =
            Intent(ctx, PhantomMessagingService::class.java).apply {
                action = ACTION_STOP
            }
    }

    override fun onCreate() {
        super.onCreate()
        ensureNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        if (intent?.action == ACTION_STOP) {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
                stopForeground(STOP_FOREGROUND_REMOVE)
            } else {
                @Suppress("DEPRECATION")
                stopForeground(true)
            }
            stopSelf()
            return START_NOT_STICKY
        }
        startForeground(NOTIF_ID, buildNotification())
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null

    private fun buildNotification(): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pi = PendingIntent.getActivity(
            this, 0, launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle("Phantom")
                .setContentText("Ready to receive messages")
                .setContentIntent(pi)
                .setOngoing(true)
                .setShowWhen(false)
                .build()
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setSmallIcon(R.drawable.ic_notification)
                .setContentTitle("Phantom")
                .setContentText("Ready to receive messages")
                .setContentIntent(pi)
                .setOngoing(true)
                .setShowWhen(false)
                .build()
        }
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java) ?: return
            if (nm.getNotificationChannel(CHANNEL_ID) != null) return
            val ch = NotificationChannel(
                CHANNEL_ID,
                "Background",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                setShowBadge(false)
                setSound(null, null)
            }
            nm.createNotificationChannel(ch)
        }
    }
}
