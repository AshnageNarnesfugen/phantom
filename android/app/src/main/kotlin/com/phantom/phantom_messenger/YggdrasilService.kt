package com.phantom.phantom_messenger

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.util.Log
import io.flutter.plugin.common.EventChannel
import java.lang.reflect.Method

/**
 * Plain foreground Service that hosts an in-process yggdrasil-go router
 * WITHOUT a TUN / VpnService.
 *
 * Why no VpnService: a VpnService is a system-wide (or at best per-app) tunnel.
 * With a TUN, our own in-package daemons (go-waku, kubo, i2pd — same UID) get
 * their internet traffic routed into the tunnel and black-holed, and other apps
 * lose connectivity too. We don't actually need the OS to see an ygg interface —
 * we only need to move a handful of message frames between two ygg addresses.
 *
 * The gomobile `mobile.Yggdrasil` binding runs the router headless (it dials its
 * `tls://` peers over normal internet sockets — no TUN required) and exposes
 * `Send([]byte)` / `Recv() []byte` that move fully-formed IPv6 packets in and
 * out of the mesh. The Dart side ([YggIp6]) crafts/parses those packets, so:
 *   - Dart → send:  MethodChannel `phantom/yggdrasil_io` → [send] → router.Send
 *   - router.Recv → EventChannel `phantom/yggdrasil_io/incoming` → Dart
 *
 * The router instance + its send method + the event sink live in the companion
 * so the channel handlers (wired in MainActivity on the Flutter engine) can
 * reach the router this service owns.
 */
class YggdrasilService : Service() {

    companion object {
        const val TAG          = "YggdrasilService"
        const val CHANNEL_ID   = "phantom_yggdrasil"
        const val NOTIF_ID     = 43
        const val ACTION_START = "phantom.yggdrasil.START"
        const val ACTION_STOP  = "phantom.yggdrasil.STOP"
        const val EXTRA_CONFIG = "configJson"
        const val EXTRA_ADDR   = "address"

        const val PREFS_NAME  = "phantom_ygg_prefs"
        const val KEY_ADDRESS = "ygg_address"
        const val KEY_CONFIG  = "ygg_config"

        // The running router, shared so the `send` MethodChannel and the
        // incoming EventChannel (both live in MainActivity) can reach it.
        @Volatile private var ygg: Any? = null
        @Volatile private var sendMethod: Method? = null
        @Volatile private var sink: EventChannel.EventSink? = null
        private val mainHandler = Handler(Looper.getMainLooper())

        /**
         * gomobile with `-javapkg=mobile` double-prefixes, so the bound class is
         * `mobile.mobile.Yggdrasil`; older layouts used one segment — try both.
         */
        fun resolveRouterClass(): Class<*>? {
            for (name in arrayOf("mobile.mobile.Yggdrasil", "mobile.Yggdrasil")) {
                try { return Class.forName(name) } catch (_: Throwable) {}
            }
            return null
        }

        fun resolveMobileClass(): Class<*>? {
            for (name in arrayOf("mobile.mobile.Mobile", "mobile.Mobile")) {
                try { return Class.forName(name) } catch (_: Throwable) {}
            }
            return null
        }

        /** True when the gomobile router class is inside this APK. */
        fun routerBundled(): Boolean = resolveRouterClass() != null

        /** Feed one fully-formed IPv6 packet to the router (called from Dart). */
        fun send(packet: ByteArray): Boolean {
            val y = ygg ?: return false
            val m = sendMethod ?: return false
            return try {
                m.invoke(y, packet); true
            } catch (e: Throwable) {
                Log.w(TAG, "send failed: $e"); false
            }
        }

        /** Register/clear the sink the Recv pump forwards inbound packets to. */
        fun setSink(s: EventChannel.EventSink?) { sink = s }

        fun startIntent(ctx: Context, configJson: String, address: String): Intent =
            Intent(ctx, YggdrasilService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_CONFIG, configJson)
                putExtra(EXTRA_ADDR, address)
            }

        fun stopIntent(ctx: Context): Intent =
            Intent(ctx, YggdrasilService::class.java).apply { action = ACTION_STOP }
    }

    @Volatile private var pumpRunning = false

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onCreate() {
        super.onCreate()
        ensureNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_STOP -> {
                shutdown()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_START -> {
                val cfg  = intent.getStringExtra(EXTRA_CONFIG)
                val addr = intent.getStringExtra(EXTRA_ADDR)
                if (cfg == null || addr == null) {
                    Log.w(TAG, "missing config/addr — aborting")
                    stopSelf(); return START_NOT_STICKY
                }
                startForeground(NOTIF_ID, buildNotification("Yggdrasil active"))
                return if (start(cfg, addr)) START_STICKY else START_NOT_STICKY
            }
        }
        return START_NOT_STICKY
    }

    override fun onDestroy() {
        shutdown()
        super.onDestroy()
    }

    // ── Lifecycle ────────────────────────────────────────────────────────────

    /**
     * Start the router headless. Same identity handling as before (generate a
     * persistent key once, reuse it across runs), but NO TUN: we start the Recv
     * pump and expose Send instead of establishing a VpnService.
     */
    private fun start(configJson: String, ourAddress: String): Boolean {
        try {
            val yggCls = resolveRouterClass() ?: run {
                Log.e(TAG, "mobile.mobile.Yggdrasil missing — yggdrasil-mobile.aar not built into this APK")
                return false
            }

            // A config without a PrivateKey makes startJSON mint a new key (=
            // new address) every run. Generate a full config once and merge our
            // fields (Peers etc.) into it.
            var effectiveConfig = configJson
            if (!org.json.JSONObject(configJson).has("PrivateKey")) {
                try {
                    val gen = resolveMobileClass()!!
                        .getMethod("generateConfigJSON")
                        .invoke(null) as ByteArray
                    val full = org.json.JSONObject(String(gen, Charsets.UTF_8))
                    val ours = org.json.JSONObject(configJson)
                    for (key in ours.keys()) full.put(key, ours.get(key))
                    effectiveConfig = full.toString()
                    Log.i(TAG, "generated persistent Yggdrasil identity")
                } catch (e: Throwable) {
                    Log.w(TAG, "generateConfigJSON unavailable — router will use an ephemeral key: $e")
                }
            }

            val instance = yggCls.getDeclaredConstructor().newInstance()

            // startJSON boots the core + a headless (no-TUN) ipv6rwc; the router
            // dials its tls:// peers over normal internet sockets.
            yggCls.getMethod("startJSON", ByteArray::class.java)
                .invoke(instance, effectiveConfig.toByteArray(Charsets.UTF_8))

            val realAddress = try {
                (yggCls.getMethod("getAddressString").invoke(instance) as? String)
                    ?.takeIf { it.isNotEmpty() } ?: ourAddress
            } catch (_: Throwable) { ourAddress }
            if (realAddress.isEmpty()) {
                Log.e(TAG, "router produced no address — aborting")
                shutdown(); return false
            }

            // Persist the provisioned identity for the Dart side.
            getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit()
                .putString(KEY_ADDRESS, realAddress)
                .putString(KEY_CONFIG, effectiveConfig)
                .apply()

            // Publish for the send path + start pumping inbound packets.
            sendMethod = yggCls.getMethod("send", ByteArray::class.java)
            ygg = instance
            startRecvPump(instance, yggCls)

            Log.i(TAG, "Yggdrasil started (headless, no TUN); address=$realAddress")
            return true
        } catch (e: Throwable) {
            Log.e(TAG, "start failed", e)
            shutdown()
            return false
        }
    }

    private fun startRecvPump(instance: Any, cls: Class<*>) {
        val recvMethod = cls.getMethod("recv")
        pumpRunning = true
        Thread({
            try {
                while (pumpRunning) {
                    val pkt = recvMethod.invoke(instance) as? ByteArray ?: continue
                    if (pkt.isEmpty()) continue
                    val s = sink ?: continue
                    val copy = pkt.copyOf()
                    mainHandler.post {
                        try { s.success(copy) } catch (_: Throwable) {}
                    }
                }
            } catch (e: Throwable) {
                if (pumpRunning) Log.w(TAG, "recv pump dead: $e")
            }
        }, "ygg-recv").start()
    }

    private fun shutdown() {
        pumpRunning = false
        val y = ygg
        ygg = null
        sendMethod = null
        try {
            y?.let { it.javaClass.getMethod("stop").invoke(it) }
        } catch (_: Throwable) {}
    }

    // ── Notification (foreground service requirement) ───────────────────────

    private fun buildNotification(text: String): Notification {
        val launchIntent = packageManager.getLaunchIntentForPackage(packageName)
        val pi = PendingIntent.getActivity(
            this, 0, launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE,
        )
        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(this, CHANNEL_ID)
                .setSmallIcon(android.R.drawable.ic_menu_share)
                .setContentTitle("Phantom Yggdrasil")
                .setContentText(text)
                .setContentIntent(pi)
                .setOngoing(true)
                .build()
        } else {
            @Suppress("DEPRECATION")
            Notification.Builder(this)
                .setSmallIcon(android.R.drawable.ic_menu_share)
                .setContentTitle("Phantom Yggdrasil")
                .setContentText(text)
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
                CHANNEL_ID, "Yggdrasil Mesh",
                NotificationManager.IMPORTANCE_LOW,
            ).apply {
                setShowBadge(false)
                description = "Hosts the Yggdrasil router for Phantom"
            }
            nm.createNotificationChannel(ch)
        }
    }
}
