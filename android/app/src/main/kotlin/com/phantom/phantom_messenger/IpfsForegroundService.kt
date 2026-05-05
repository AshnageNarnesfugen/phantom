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
 * Keeps the bundled Kubo IPFS daemon alive while the app is in the background.
 *
 * Started/stopped via the `phantom/ipfs_daemon` Flutter method channel.
 * The binary at [EXTRA_BINARY] is the libkubo.so extracted by Android from
 * jniLibs — already on-disk and executable, no extraction needed.
 */
class IpfsForegroundService : Service() {

    private var daemonProcess: Process? = null

    companion object {
        const val CHANNEL_ID   = "phantom_ipfs_node"
        const val NOTIF_ID     = 42
        const val ACTION_START = "phantom.ipfs.START"
        const val ACTION_STOP  = "phantom.ipfs.STOP"
        const val EXTRA_BINARY = "binaryPath"
        const val EXTRA_REPO   = "repoPath"

        fun startIntent(ctx: Context, binaryPath: String, repoPath: String): Intent =
            Intent(ctx, IpfsForegroundService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_BINARY, binaryPath)
                putExtra(EXTRA_REPO, repoPath)
            }

        fun stopIntent(ctx: Context): Intent =
            Intent(ctx, IpfsForegroundService::class.java).apply {
                action = ACTION_STOP
            }
    }

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    override fun onCreate() {
        super.onCreate()
        ensureNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_START -> {
                val binary = intent.getStringExtra(EXTRA_BINARY) ?: run {
                    stopSelf(); return START_NOT_STICKY
                }
                val repo = intent.getStringExtra(EXTRA_REPO) ?: run {
                    stopSelf(); return START_NOT_STICKY
                }
                startForeground(NOTIF_ID, buildNotification())
                // Guard against double-start (e.g. START_STICKY re-delivery)
                if (daemonProcess == null) spawnDaemon(binary, repo)
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        daemonProcess?.destroyForcibly()
        daemonProcess = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // ── Daemon process ────────────────────────────────────────────────────────

    private fun spawnDaemon(binary: String, repo: String) {
        Thread {
            try {
                // --enable-pubsub-experiment was removed in Kubo >= 0.11;
                // pubsub is now enabled via config (Pubsub.Enabled=true).
                val pb = ProcessBuilder(
                    binary, "daemon",
                    "--routing=dhtclient",
                    "--migrate=true",
                )
                pb.environment()["IPFS_PATH"] = repo
                pb.redirectErrorStream(true)
                val proc = pb.start()
                daemonProcess = proc
                // Drain output so the pipe buffer never blocks the daemon.
                proc.inputStream.bufferedReader().forEachLine { /* discard */ }
                proc.waitFor()
            } catch (_: Exception) {
            } finally {
                daemonProcess = null
            }
        }.also { it.isDaemon = true }.start()
    }

    // ── Notification ──────────────────────────────────────────────────────────

    private fun buildNotification(): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pi = PendingIntent.getActivity(
            this, 0, launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_menu_share)
                .setContentTitle("Phantom")
                .setContentText("Decentralized node active")
                .setContentIntent(pi)
                .setOngoing(true)
                .build()
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setSmallIcon(android.R.drawable.ic_menu_share)
                .setContentTitle("Phantom")
                .setContentText("Decentralized node active")
                .setContentIntent(pi)
                .setOngoing(true)
                .build()
        }
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)!!
            if (nm.getNotificationChannel(CHANNEL_ID) != null) return
            val ch = NotificationChannel(
                CHANNEL_ID,
                "Decentralized Node",
                NotificationManager.IMPORTANCE_LOW,
            )
            ch.setShowBadge(false)
            nm.createNotificationChannel(ch)
        }
    }
}
