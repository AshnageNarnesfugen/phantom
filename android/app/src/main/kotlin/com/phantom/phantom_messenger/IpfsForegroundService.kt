package com.phantom.phantom_messenger

import android.app.AlarmManager
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.SharedPreferences
import android.os.Build
import android.os.IBinder
import android.os.PowerManager
import android.util.Log

/**
 * Keeps the bundled Kubo IPFS daemon alive as a persistent foreground service.
 *
 * Survival strategy (multiple layers):
 *   1. Runs in a separate process (:ipfs) — app swipe only kills main process
 *   2. stopWithTask="false" — Android doesn't stop service on task removal
 *   3. onTaskRemoved() re-asserts foreground + schedules restart via AlarmManager
 *   4. START_STICKY — Android auto-restarts after OOM kill
 *   5. SharedPreferences persist binary/repo paths for sticky restart
 *   6. Partial WakeLock keeps CPU alive for network connections
 *   7. Auto-respawn daemon if it crashes
 */
class IpfsForegroundService : Service() {

    private var daemonProcess: Process? = null
    private var wakeLock: PowerManager.WakeLock? = null

    companion object {
        const val TAG          = "IpfsForegroundService"
        const val CHANNEL_ID   = "phantom_ipfs_node"
        const val NOTIF_ID     = 42
        const val ACTION_START = "phantom.ipfs.START"
        const val ACTION_STOP  = "phantom.ipfs.STOP"
        const val EXTRA_BINARY = "binaryPath"
        const val EXTRA_REPO   = "repoPath"
        const val PREFS_NAME   = "phantom_ipfs_prefs"
        const val KEY_BINARY   = "ipfs_binary_path"
        const val KEY_REPO     = "ipfs_repo_path"

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

    private fun prefs(): SharedPreferences =
        getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    override fun onCreate() {
        super.onCreate()
        Log.i(TAG, "onCreate — PID=${android.os.Process.myPid()}")
        ensureNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        Log.i(TAG, "onStartCommand action=${intent?.action} flags=$flags")

        when (intent?.action) {
            ACTION_STOP -> {
                Log.i(TAG, "Received STOP — shutting down daemon")
                // Clear saved paths so START_STICKY doesn't resurrect us
                prefs().edit().clear().apply()
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
                // Persist paths for START_STICKY re-delivery and onTaskRemoved restart
                prefs().edit()
                    .putString(KEY_BINARY, binary)
                    .putString(KEY_REPO, repo)
                    .apply()

                startForeground(NOTIF_ID, buildNotification("Connecting to decentralized network…"))
                acquireWakeLock()
                if (daemonProcess == null) spawnDaemon(binary, repo)
            }
            else -> {
                // START_STICKY re-delivery or onTaskRemoved restart: intent may be null
                // or have no action. Recover paths from SharedPreferences.
                val p = prefs()
                val binary = p.getString(KEY_BINARY, null)
                val repo   = p.getString(KEY_REPO, null)
                if (binary != null && repo != null) {
                    Log.i(TAG, "Sticky/alarm restart — re-spawning daemon")
                    startForeground(NOTIF_ID, buildNotification("Reconnecting to decentralized network…"))
                    acquireWakeLock()
                    if (daemonProcess == null) spawnDaemon(binary, repo)
                } else {
                    Log.w(TAG, "Restart but no saved paths — stopping")
                    stopSelf()
                    return START_NOT_STICKY
                }
            }
        }
        return START_STICKY
    }

    /**
     * Called when the user swipes the app away from Recents.
     *
     * Layer 1: Re-assert foreground notification (some ROMs drop it)
     * Layer 2: Schedule an AlarmManager restart in 1 second as a safety net
     *          in case the OS kills this process anyway.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        Log.i(TAG, "onTaskRemoved — re-asserting foreground + scheduling restart")

        // Re-assert ourselves as foreground so Android doesn't de-prioritize us
        try {
            startForeground(NOTIF_ID, buildNotification("Decentralized node active"))
        } catch (e: Exception) {
            Log.w(TAG, "startForeground in onTaskRemoved failed: $e")
        }

        // Schedule a restart via AlarmManager as a safety net
        try {
            val restartIntent = Intent(applicationContext, IpfsForegroundService::class.java)
            // No action → will hit the "else" branch in onStartCommand and use saved prefs
            val pi = PendingIntent.getService(
                this, 1, restartIntent,
                PendingIntent.FLAG_ONE_SHOT or PendingIntent.FLAG_IMMUTABLE
            )
            val am = getSystemService(Context.ALARM_SERVICE) as AlarmManager
            am.set(AlarmManager.RTC_WAKEUP, System.currentTimeMillis() + 1000, pi)
            Log.i(TAG, "Restart alarm scheduled for +1s")
        } catch (e: Exception) {
            Log.w(TAG, "AlarmManager restart failed: $e")
        }
    }

    override fun onDestroy() {
        Log.i(TAG, "onDestroy — killing daemon process")
        releaseWakeLock()
        daemonProcess?.destroyForcibly()
        daemonProcess = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // ── WakeLock ──────────────────────────────────────────────────────────────

    private fun acquireWakeLock() {
        if (wakeLock != null) return
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "phantom:ipfs_daemon"
        ).apply {
            setReferenceCounted(false)
            acquire()
        }
        Log.i(TAG, "WakeLock acquired")
    }

    private fun releaseWakeLock() {
        wakeLock?.let {
            if (it.isHeld) it.release()
            Log.i(TAG, "WakeLock released")
        }
        wakeLock = null
    }

    // ── Daemon process ────────────────────────────────────────────────────────

    private fun spawnDaemon(binary: String, repo: String) {
        // Use a non-daemon thread so the JVM doesn't consider exiting
        Thread {
            try {
                Log.i(TAG, "Spawning daemon: $binary (repo: $repo)")
                val pb = ProcessBuilder(
                    binary, "daemon",
                    "--routing=dhtclient",
                    "--migrate=true",
                )
                pb.environment()["IPFS_PATH"] = repo
                pb.redirectErrorStream(true)
                val proc = pb.start()
                daemonProcess = proc

                // Update notification once daemon has had time to start
                Thread {
                    try {
                        Thread.sleep(3000)
                        updateNotification("Decentralized node active")
                    } catch (_: Exception) {}
                }.start()

                // Drain output so pipe buffer never blocks
                proc.inputStream.bufferedReader().forEachLine { line ->
                    Log.d(TAG, line)
                }
                val exitCode = proc.waitFor()
                Log.w(TAG, "Daemon exited with code $exitCode")
            } catch (e: Exception) {
                Log.e(TAG, "Daemon spawn failed", e)
            } finally {
                daemonProcess = null
                // Auto-restart if the daemon died but we weren't explicitly stopped
                val p = prefs()
                val savedBinary = p.getString(KEY_BINARY, null)
                val savedRepo   = p.getString(KEY_REPO, null)
                if (savedBinary != null && savedRepo != null) {
                    Log.i(TAG, "Daemon died unexpectedly — restarting in 3s")
                    try { Thread.sleep(3000) } catch (_: Exception) {}
                    spawnDaemon(savedBinary, savedRepo)
                }
            }
        }.start() // NOT isDaemon=true — keep the process alive
    }

    // ── Notification ──────────────────────────────────────────────────────────

    private fun buildNotification(text: String): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pi = PendingIntent.getActivity(
            this, 0, launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_menu_share)
                .setContentTitle("Phantom")
                .setContentText(text)
                .setContentIntent(pi)
                .setOngoing(true)
                .build()
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setSmallIcon(android.R.drawable.ic_menu_share)
                .setContentTitle("Phantom")
                .setContentText(text)
                .setContentIntent(pi)
                .setOngoing(true)
                .build()
        }
    }

    private fun updateNotification(text: String) {
        try {
            val nm = getSystemService(NotificationManager::class.java) ?: return
            nm.notify(NOTIF_ID, buildNotification(text))
        } catch (_: Exception) {}
    }

    private fun ensureNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val nm = getSystemService(NotificationManager::class.java)!!
            if (nm.getNotificationChannel(CHANNEL_ID) != null) return
            val ch = NotificationChannel(
                CHANNEL_ID,
                "Decentralized Node",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                setShowBadge(false)
                description = "Keeps your Phantom node connected to the decentralized network"
            }
            nm.createNotificationChannel(ch)
        }
    }
}
