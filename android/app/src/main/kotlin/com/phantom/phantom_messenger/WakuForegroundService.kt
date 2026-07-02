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
 * Keeps the go-waku node alive as a lightweight foreground service.
 *
 * Unlike IPFS (which runs in its own process and holds a heavy WakeLock),
 * Waku is designed for mobile and uses far less CPU/memory. It still runs
 * as a foreground service so Android doesn't kill it during Doze, but
 * the battery impact is minimal compared to maintaining a full IPFS swarm.
 *
 * The go-waku .aar exposes Java bindings via gomobile. This service:
 *   1. Loads the gowaku library
 *   2. Starts a Waku node with relay + store protocols
 *   3. Exposes a REST API on a random localhost port
 *   4. Writes the port to SharedPreferences so the Dart side can find it
 *
 * Survival: same layered strategy as IpfsForegroundService —
 * START_STICKY + onTaskRemoved re-assert + AlarmManager safety net.
 */
class WakuForegroundService : Service() {

    private var wakuProcess: Process? = null
    private var wakeLock: PowerManager.WakeLock? = null

    companion object {
        const val TAG          = "WakuForegroundService"
        const val CHANNEL_ID   = "phantom_waku_node"
        const val NOTIF_ID     = 45
        const val ACTION_START = "phantom.waku.START"
        const val ACTION_STOP  = "phantom.waku.STOP"
        const val EXTRA_BINARY = "binaryPath"
        const val EXTRA_DATA   = "dataDir"
        const val PREFS_NAME   = "phantom_waku_prefs"
        const val KEY_BINARY   = "waku_binary_path"
        const val KEY_DATA     = "waku_data_dir"
        const val KEY_API_PORT = "waku_api_port"

        fun startIntent(ctx: Context, binaryPath: String, dataDir: String): Intent =
            Intent(ctx, WakuForegroundService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_BINARY, binaryPath)
                putExtra(EXTRA_DATA, dataDir)
            }

        fun stopIntent(ctx: Context): Intent =
            Intent(ctx, WakuForegroundService::class.java).apply {
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
                Log.i(TAG, "Received STOP — shutting down Waku")
                prefs().edit().clear().apply()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_START -> {
                val binary = intent.getStringExtra(EXTRA_BINARY) ?: run {
                    stopSelf(); return START_NOT_STICKY
                }
                val dataDir = intent.getStringExtra(EXTRA_DATA) ?: run {
                    stopSelf(); return START_NOT_STICKY
                }
                prefs().edit()
                    .putString(KEY_BINARY, binary)
                    .putString(KEY_DATA, dataDir)
                    .apply()

                startForeground(NOTIF_ID, buildNotification("Connecting to Waku network…"))
                acquireWakeLock()
                if (wakuProcess == null) spawnWaku(binary, dataDir)
            }
            else -> {
                // START_STICKY re-delivery
                val p = prefs()
                val binary  = p.getString(KEY_BINARY, null)
                val dataDir = p.getString(KEY_DATA, null)
                if (binary != null && dataDir != null) {
                    Log.i(TAG, "Sticky restart — re-spawning Waku")
                    startForeground(NOTIF_ID, buildNotification("Reconnecting to Waku network…"))
                    acquireWakeLock()
                    if (wakuProcess == null) spawnWaku(binary, dataDir)
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
        Log.i(TAG, "onTaskRemoved — re-asserting foreground")
        try {
            startForeground(NOTIF_ID, buildNotification("Waku relay active"))
        } catch (e: Exception) {
            Log.w(TAG, "startForeground in onTaskRemoved failed: $e")
        }
    }

    override fun onDestroy() {
        Log.i(TAG, "onDestroy — killing Waku process")
        releaseWakeLock()
        wakuProcess?.destroyForcibly()
        wakuProcess = null
        super.onDestroy()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // ── WakeLock ──────────────────────────────────────────────────────────────

    private fun acquireWakeLock() {
        if (wakeLock != null) return
        val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
        wakeLock = pm.newWakeLock(
            PowerManager.PARTIAL_WAKE_LOCK,
            "phantom:waku_node"
        ).apply {
            setReferenceCounted(false)
            // Waku is lightweight — 30 min timeout instead of indefinite
            acquire(30 * 60 * 1000L)
        }
        Log.i(TAG, "WakeLock acquired (30 min timeout)")
    }

    private fun releaseWakeLock() {
        wakeLock?.let {
            if (it.isHeld) it.release()
            Log.i(TAG, "WakeLock released")
        }
        wakeLock = null
    }

    // ── Waku process ──────────────────────────────────────────────────────────

    private fun spawnWaku(binary: String, dataDir: String) {
        Thread {
            try {
                Log.i(TAG, "Spawning Waku: $binary (data: $dataDir)")

                // go-waku CLI: start with relay + store + REST API on random port.
                // Flag names verified from the daemon's own --help output —
                // earlier `--nodekey-file` / `--db-path` were guesses that
                // panicked the process with "flag provided but not defined".
                val pb = ProcessBuilder(
                    binary,
                    "--relay=true",
                    "--store=true",
                    "--rest=true",
                    "--rest-address=127.0.0.1",
                    "--rest-port=8645",         // pin so Dart can reach it
                    "--key-file=$dataDir/nodekey",
                    "--store-message-db-url=sqlite3://$dataDir/store.db",
                    // status.prod fleet: cluster 16, shard 32 (status-go's
                    // 1:1 shard). The old wakuv2.prod fleet (cluster 0,
                    // /waku/2/default-waku/proto) was retired — its nodes
                    // sit in permanent dial backoff, so store queries
                    // failed with "no suitable peers found" forever.
                    // Must match WakuDaemon.defaultPubsubTopic.
                    "--cluster-id=16",
                    "--pubsub-topic=/waku/2/rs/16/32",
                    "--store=true",
                    "--store-message-retention-time=72h",
                    "--dns-discovery=true",
                    "--dns-discovery-url=enrtree://AMOJVZX4V6EXP7NTJPMAYJYST2QP6AJXYW76IU6VGJS7UVSNDYZG4@boot.prod.status.nodes.status.im",
                    "--dns-discovery-name-server=1.1.1.1",
                    // Pinned status.prod store nodes (one per region, from
                    // fleets.status.im) — guarantees store/lightpush-capable
                    // peers even when DNS discovery is slow.
                    "--staticnode=/dns4/store-01.do-ams3.status.prod.status.im/tcp/30303/p2p/16Uiu2HAmAUdrQ3uwzuE4Gy4D56hX6uLKEeerJAnhKEHZ3DxF1EfT",
                    "--staticnode=/dns4/store-01.gc-us-central1-a.status.prod.status.im/tcp/30303/p2p/16Uiu2HAmMELCo218hncCtTvC2Dwbej3rbyHQcR8erXNnKGei7WPZ",
                    "--staticnode=/dns4/store-01.ac-cn-hongkong-c.status.prod.status.im/tcp/30303/p2p/16Uiu2HAm2M7xs7cLPc3jamawkEqbr7cUJX11uvY7LxQ6WFUdUKUT",
                    "--storenode=/dns4/store-01.do-ams3.status.prod.status.im/tcp/30303/p2p/16Uiu2HAmAUdrQ3uwzuE4Gy4D56hX6uLKEeerJAnhKEHZ3DxF1EfT",
                    "--rest-admin=true",
                    "--min-relay-peers-to-publish=0",
                    // Default 5m keep-alive lets mobile NAT mappings die and
                    // takes the store/lightpush connections with them; the
                    // Dart side also re-dials via /admin/v1/peers on failure.
                    "--keep-alive=30s",
                )
                pb.environment()["HOME"] = dataDir
                pb.redirectErrorStream(true)
                val proc = pb.start()
                wakuProcess = proc

                Thread {
                    try {
                        Thread.sleep(3000)
                        updateNotification("Waku relay active")
                    } catch (_: Exception) {}
                }.start()

                // Drain output and watch for the REST API port announcement
                proc.inputStream.bufferedReader().forEachLine { line ->
                    Log.d(TAG, line)
                    // go-waku logs the REST port like: "rest server listening on 127.0.0.1:XXXXX"
                    if (line.contains("rest") && line.contains("listening")) {
                        val port = Regex(":(\\d+)").find(line)?.groupValues?.get(1)
                        if (port != null) {
                            prefs().edit().putString(KEY_API_PORT, port).apply()
                            Log.i(TAG, "Waku REST API on port $port")
                        }
                    }
                }
                val exitCode = proc.waitFor()
                Log.w(TAG, "Waku exited with code $exitCode")
            } catch (e: Exception) {
                Log.e(TAG, "Waku spawn failed", e)
            } finally {
                wakuProcess = null
                val p = prefs()
                val savedBinary = p.getString(KEY_BINARY, null)
                val savedData   = p.getString(KEY_DATA, null)
                if (savedBinary != null && savedData != null) {
                    Log.i(TAG, "Waku died unexpectedly — restarting in 5s")
                    try { Thread.sleep(5000) } catch (_: Exception) {}
                    spawnWaku(savedBinary, savedData)
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
                "Waku Relay Node",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                setShowBadge(false)
                description = "Keeps Phantom connected to the Waku messaging relay"
            }
            nm.createNotificationChannel(ch)
        }
    }
}
