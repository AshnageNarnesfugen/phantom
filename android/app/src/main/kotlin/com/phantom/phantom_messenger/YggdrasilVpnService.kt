package com.phantom.phantom_messenger

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import java.io.FileInputStream
import java.io.FileOutputStream

/**
 * VpnService that hosts an in-process yggdrasil-go router.
 *
 * Flow:
 *   1. VpnService.Builder.establish() returns a TUN [ParcelFileDescriptor]
 *   2. We hand the file descriptor to the gomobile-bound Yggdrasil instance
 *   3. Two pump threads bridge:
 *        TUN -> Yggdrasil.send  (outbound packets to the Ygg mesh)
 *        Yggdrasil.recv -> TUN  (inbound packets to userspace)
 *
 * Uses reflection to load mobile.Yggdrasil so the app still builds when
 * libs/yggdrasil-mobile.aar is missing (e.g. local dev without a CI build).
 */
class YggdrasilVpnService : VpnService() {

    companion object {
        const val TAG          = "YggdrasilVpnService"
        const val CHANNEL_ID   = "phantom_yggdrasil"
        const val NOTIF_ID     = 43
        const val ACTION_START = "phantom.yggdrasil.START"
        const val ACTION_STOP  = "phantom.yggdrasil.STOP"
        const val EXTRA_CONFIG = "configJson"
        const val EXTRA_ADDR   = "address"

        // Bootstrap results (final config incl. generated PrivateKey + the
        // router's real 0200::/7 address) are persisted here so the Dart side
        // can read them back after the first start and keep the identity
        // stable across runs. Same pattern as WakuForegroundService's port.
        const val PREFS_NAME  = "phantom_ygg_prefs"
        const val KEY_ADDRESS = "ygg_address"
        const val KEY_CONFIG  = "ygg_config"

        /**
         * gomobile with `-javapkg=mobile` prefixes the GO package name too, so
         * the bound class is `mobile.mobile.Yggdrasil` (verified via javap on
         * the .aar). Older gomobile layouts used a single segment — try both.
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

        fun startIntent(ctx: Context, configJson: String, address: String): Intent =
            Intent(ctx, YggdrasilVpnService::class.java).apply {
                action = ACTION_START
                putExtra(EXTRA_CONFIG, configJson)
                putExtra(EXTRA_ADDR, address)
            }

        fun stopIntent(ctx: Context): Intent =
            Intent(ctx, YggdrasilVpnService::class.java).apply {
                action = ACTION_STOP
            }
    }

    private var tunFd: ParcelFileDescriptor? = null
    /** mobile.Yggdrasil instance, held as Any so the app links without the .aar. */
    private var yggInstance: Any? = null
    @Volatile private var pumpsRunning = false

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

    /// Router-FIRST start. The old order (TUN → router) could never bootstrap:
    /// on a fresh install Dart has no 0200::/7 address to give the TUN, and
    /// the only thing that can produce one is the router itself. So:
    ///   1. ensure the config has a PrivateKey (generateConfigJSON when not)
    ///   2. startJSON the router (works without a TUN — we pump manually)
    ///   3. ask it for its real address (getAddressString)
    ///   4. establish the TUN with THAT address
    ///   5. persist address+config to SharedPreferences so the Dart side can
    ///      read them back and keep the identity stable across runs
    private fun start(configJson: String, ourAddress: String): Boolean {
        try {
            // 1. Load the router class via reflection so the app links even
            //    when the .aar is absent.
            val yggCls = resolveRouterClass() ?: run {
                Log.e(TAG, "mobile.mobile.Yggdrasil missing — yggdrasil-mobile.aar not built into this APK")
                return false
            }

            // 2. A config without a PrivateKey would make startJSON mint a new
            //    ephemeral key (= new address) on EVERY run. Generate a full
            //    config once and merge our fields (Peers etc.) into it.
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

            val ygg = yggCls.getDeclaredConstructor().newInstance()
            yggInstance = ygg

            // 3. Start the router. contrib/mobile's startJSON boots Yggdrasil
            //    with a no-op TUN; we feed packets ourselves.
            yggCls.getMethod("startJSON", ByteArray::class.java)
                .invoke(ygg, effectiveConfig.toByteArray(Charsets.UTF_8))

            // 4. The router knows its real 0200::/7 address; prefer it over
            //    whatever Dart passed (empty on first run).
            val realAddress = try {
                (yggCls.getMethod("getAddressString").invoke(ygg) as? String)
                    ?.takeIf { it.isNotEmpty() } ?: ourAddress
            } catch (_: Throwable) { ourAddress }
            if (realAddress.isEmpty()) {
                Log.e(TAG, "router produced no address — aborting")
                shutdown(); return false
            }

            // 5. Build the TUN with the authoritative address.
            val builder = Builder()
                .setSession("Phantom Yggdrasil")
                .setMtu(1280)
                .addAddress(realAddress, 7)
                .addRoute("0200::", 7)
            // Allow our app to bypass the VPN so internal IPFS / TCP keeps working
            builder.addDisallowedApplication(packageName)
            val pfd = builder.establish() ?: run {
                Log.e(TAG, "VpnService.establish() returned null — VPN permission?")
                shutdown(); return false
            }
            tunFd = pfd

            // 6. Persist the provisioned identity for the Dart side.
            getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE).edit()
                .putString(KEY_ADDRESS, realAddress)
                .putString(KEY_CONFIG, effectiveConfig)
                .apply()

            // 7. Pump packets
            startPumps(ygg, pfd)
            Log.i(TAG, "Yggdrasil started; TUN address=$realAddress")
            return true
        } catch (e: Throwable) {
            Log.e(TAG, "start failed", e)
            shutdown()
            return false
        }
    }

    private fun startPumps(ygg: Any, pfd: ParcelFileDescriptor) {
        pumpsRunning = true
        val cls = ygg.javaClass

        val sendMethod = cls.getMethod("send", ByteArray::class.java)
        val recvMethod = cls.getMethod("recv")

        // TUN -> Yggdrasil
        Thread({
            try {
                val input = FileInputStream(pfd.fileDescriptor)
                val buf = ByteArray(2048)
                while (pumpsRunning) {
                    val n = input.read(buf)
                    if (n <= 0) break
                    val pkt = buf.copyOfRange(0, n)
                    sendMethod.invoke(ygg, pkt)
                }
            } catch (e: Throwable) {
                if (pumpsRunning) Log.w(TAG, "TUN->Ygg pump dead: $e")
            }
        }, "ygg-tx").start()

        // Yggdrasil -> TUN
        Thread({
            try {
                val output = FileOutputStream(pfd.fileDescriptor)
                while (pumpsRunning) {
                    val pkt = recvMethod.invoke(ygg) as? ByteArray ?: continue
                    if (pkt.isEmpty()) continue
                    output.write(pkt)
                }
            } catch (e: Throwable) {
                if (pumpsRunning) Log.w(TAG, "Ygg->TUN pump dead: $e")
            }
        }, "ygg-rx").start()
    }

    private fun shutdown() {
        pumpsRunning = false
        try {
            yggInstance?.let { y ->
                try { y.javaClass.getMethod("stop").invoke(y) } catch (_: Throwable) {}
            }
        } finally {
            yggInstance = null
        }
        try { tunFd?.close() } catch (_: Throwable) {}
        tunFd = null
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
