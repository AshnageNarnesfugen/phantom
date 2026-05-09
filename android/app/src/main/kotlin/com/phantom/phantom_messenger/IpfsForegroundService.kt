package com.phantom.phantom_messenger

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
 * Key design decisions:
 *   - Uses START_STICKY so Android restarts the service after OOM kills.
 *   - Persists binaryPath/repoPath in SharedPreferences so the daemon can
 *     be re-spawned on sticky restart (where the Intent extras are null).
 *   - Holds a partial WakeLock to prevent the CPU from sleeping and killing
 *     the daemon's network connections.
 *   - onTaskRemoved() does NOT stop the service — Kubo survives app swipe.
 *   - The service only stops when explicitly told via ACTION_STOP.
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
        ensureNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                Log.i(TAG, "Received STOP — shutting down daemon")
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
                // Persist paths so START_STICKY re-delivery can restart the daemon
                prefs().edit()
                    .putString(KEY_BINARY, binary)
                    .putString(KEY_REPO, repo)
                    .apply()

                startForeground(NOTIF_ID, buildNotification("Connecting to decentralized network…"))
                acquireWakeLock()
                if (daemonProcess == null) spawnDaemon(binary, repo)
            }
            else -> {
                // START_STICKY re-delivery: intent is null or has no action.
                // Recover saved paths and restart the daemon.
                val p = prefs()
                val binary = p.getString(KEY_BINARY, null)
                val repo   = p.getString(KEY_REPO, null)
                if (binary != null && repo != null) {
                    Log.i(TAG, "Sticky restart — re-spawning daemon")
                    startForeground(NOTIF_ID, buildNotification("Reconnecting to decentralized network…"))
                    acquireWakeLock()
                    if (daemonProcess == null) spawnDaemon(binary, repo)
                } else {
                    Log.w(TAG, "Sticky restart but no saved paths — stopping")
                    stopSelf()
                    return START_NOT_STICKY
                }
            }
        }
        return START_STICKY
    }

    /**
     * Called when the user swipes the app away from Recents.
     * We do NOT stop the service here — the IPFS daemon must survive app closure
     * so the GossipSub mesh stays connected and messages arrive instantly on
     * next app open.
     */
    override fun onTaskRemoved(rootIntent: Intent?) {
        Log.i(TAG, "App removed from recents — daemon stays alive")
        // Do NOT call stopSelf() or super.onTaskRemoved() with stopWithTask=true
    }

    override fun onDestroy() {
        Log.i(TAG, "Service destroyed — killing daemon process")
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
            acquire() // held indefinitely until service stops
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

                // Update notification once the API is reachable
                Thread {
                    try {
                        Thread.sleep(3000) // give daemon time to start
                        updateNotification("Decentralized node active")
                    } catch (_: Exception) {}
                }.start()

                // Drain output so the pipe buffer never blocks the daemon.
                proc.inputStream.bufferedReader().forEachLine { /* discard */ }
                val exitCode = proc.waitFor()
                Log.w(TAG, "Daemon exited with code $exitCode")
            } catch (e: Exception) {
                Log.e(TAG, "Daemon spawn failed", e)
            } finally {
                daemonProcess = null
                // If the daemon dies unexpectedly, try to restart it
                val p = prefs()
                val savedBinary = p.getString(KEY_BINARY, null)
                val savedRepo   = p.getString(KEY_REPO, null)
                if (savedBinary != null && savedRepo != null && daemonProcess == null) {
                    Log.i(TAG, "Daemon died — restarting in 5s")
                    try { Thread.sleep(5000) } catch (_: Exception) {}
                    spawnDaemon(savedBinary, savedRepo)
                }
            }
        }.also { it.isDaemon = true }.start()
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
        val nm = getSystemService(NotificationManager::class.java) ?: return
        nm.notify(NOTIF_ID, buildNotification(text))
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
