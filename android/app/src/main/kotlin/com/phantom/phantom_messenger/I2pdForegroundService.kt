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
 * Keeps the bundled i2pd (PurpleI2P) daemon alive as a persistent foreground
 * service. This is the mirror of [IpfsForegroundService] for the I2P transport
 * — we need a working SAM bridge before any control-plane frame (X3DH INIT,
 * handshakeAck, preKeyShare, connectivityInfo) can flow, so the daemon's
 * survival is treated with the same care as the Kubo daemon.
 *
 * Survival strategy (multiple layers, identical to IPFS):
 *   1. Runs in a separate process (:i2pd) — app swipe only kills main process
 *   2. stopWithTask="false" — Android doesn't stop service on task removal
 *   3. onTaskRemoved() re-asserts foreground + schedules AlarmManager restart
 *   4. START_STICKY — Android auto-restarts after OOM kill
 *   5. SharedPreferences persist binary/datadir paths for sticky restart
 *   6. Partial WakeLock keeps CPU alive for network connections
 *   7. Auto-respawn daemon if it crashes
 */
class I2pdForegroundService : Service() {

    private var daemonProcess: Process? = null
    private var wakeLock: PowerManager.WakeLock? = null

    companion object {
        const val TAG          = "I2pdForegroundService"
        const val CHANNEL_ID   = "phantom_i2pd_node"
        const val NOTIF_ID     = 44
        const val ACTION_START = "phantom.i2pd.START"
        const val ACTION_STOP  = "phantom.i2pd.STOP"
        const val EXTRA_BINARY = "binaryPath"
        const val EXTRA_DATA   = "dataDir"
        const val PREFS_NAME   = "phantom_i2pd_prefs"
        const val KEY_BINARY   = "i2pd_binary_path"
        const val KEY_DATA     = "i2pd_data_dir"

        fun startIntent(ctx: Context, binaryPath: String, dataDir: String): Intent =
            Intent(ctx, I2pdForegroundService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_BINARY, binaryPath)
                putExtra(EXTRA_DATA, dataDir)
            }

        fun stopIntent(ctx: Context): Intent =
            Intent(ctx, I2pdForegroundService::class.java).apply {
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
                Log.i(TAG, "Received STOP — shutting down i2pd")
                prefs().edit().clear().apply()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_START -> {
                val binary = intent.getStringExtra(EXTRA_BINARY) ?: run {
                    stopSelf(); return START_NOT_STICKY
                }
                val data = intent.getStringExtra(EXTRA_DATA) ?: run {
                    stopSelf(); return START_NOT_STICKY
                }
                prefs().edit()
                    .putString(KEY_BINARY, binary)
                    .putString(KEY_DATA, data)
                    .apply()

                startForeground(NOTIF_ID, buildNotification("Bringing up anonymous network…"))
                acquireWakeLock()
                if (daemonProcess == null) spawnDaemon(binary, data)
            }
            else -> {
                // START_STICKY re-delivery or onTaskRemoved restart.
                val p = prefs()
                val binary = p.getString(KEY_BINARY, null)
                val data   = p.getString(KEY_DATA, null)
                if (binary != null && data != null) {
                    Log.i(TAG, "Sticky/alarm restart — re-spawning i2pd")
                    startForeground(NOTIF_ID, buildNotification("Reconnecting to anonymous network…"))
                    acquireWakeLock()
                    if (daemonProcess == null) spawnDaemon(binary, data)
                } else {
                    Log.w(TAG, "Restart but no saved paths — stopping")
                    stopSelf()
                    return START_NOT_STICKY
                }
            }
        }
        return START_STICKY
    }

    override fun onTaskRemoved(rootIntent: Intent?) {
        Log.i(TAG, "onTaskRemoved — re-asserting foreground + scheduling restart")
        try {
            startForeground(NOTIF_ID, buildNotification("Anonymous network active"))
        } catch (e: Exception) {
            Log.w(TAG, "startForeground in onTaskRemoved failed: $e")
        }
        try {
            val restartIntent = Intent(applicationContext, I2pdForegroundService::class.java)
            val pi = PendingIntent.getService(
                this, 2, restartIntent,
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
        Log.i(TAG, "onDestroy — killing i2pd process")
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
            "phantom:i2pd_daemon"
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

    private fun spawnDaemon(binary: String, dataDir: String) {
        Thread {
            try {
                Log.i(TAG, "Spawning i2pd: $binary (data: $dataDir)")
                val pb = ProcessBuilder(
                    binary,
                    "--conf=$dataDir/i2pd.conf",
                    "--datadir=$dataDir",
                    "--tunconf=$dataDir/tunnels.conf",
                )
                pb.redirectErrorStream(true)
                val proc = pb.start()
                daemonProcess = proc

                Thread {
                    try {
                        Thread.sleep(5000)
                        updateNotification("Anonymous network active")
                    } catch (_: Exception) {}
                }.start()

                proc.inputStream.bufferedReader().forEachLine { line ->
                    Log.d(TAG, line)
                }
                val exitCode = proc.waitFor()
                Log.w(TAG, "i2pd exited with code $exitCode")
            } catch (e: Exception) {
                Log.e(TAG, "i2pd spawn failed", e)
            } finally {
                daemonProcess = null
                val p = prefs()
                val savedBinary = p.getString(KEY_BINARY, null)
                val savedData   = p.getString(KEY_DATA, null)
                if (savedBinary != null && savedData != null) {
                    Log.i(TAG, "i2pd died unexpectedly — restarting in 5s")
                    try { Thread.sleep(5000) } catch (_: Exception) {}
                    spawnDaemon(savedBinary, savedData)
                }
            }
        }.start()
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
                .setContentTitle("Phantom · I2P")
                .setContentText(text)
                .setContentIntent(pi)
                .setOngoing(true)
                .build()
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setSmallIcon(android.R.drawable.ic_menu_share)
                .setContentTitle("Phantom · I2P")
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
                "Anonymous Network",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                setShowBadge(false)
                description = "Keeps the I2P SAM bridge alive for Phantom handshakes"
            }
            nm.createNotificationChannel(ch)
        }
    }
}
