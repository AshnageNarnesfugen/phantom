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

    private fun start(configJson: String, ourAddress: String): Boolean {
        try {
            // 1. Build TUN
            val builder = Builder()
                .setSession("Phantom Yggdrasil")
                .setMtu(1280)
                .addAddress(ourAddress, 7)
                .addRoute("0200::", 7)
            // Allow our app to bypass the VPN so internal IPFS / TCP keeps working
            builder.addDisallowedApplication(packageName)
            val pfd = builder.establish() ?: run {
                Log.e(TAG, "VpnService.establish() returned null — VPN permission?")
                return false
            }
            tunFd = pfd

            // 2. Load mobile.Yggdrasil via reflection so the app links even
            //    when the .aar is absent.
            val yggCls = try {
                Class.forName("mobile.Yggdrasil")
            } catch (e: ClassNotFoundException) {
                Log.e(TAG, "mobile.Yggdrasil missing — yggdrasil-mobile.aar not built into this APK")
                pfd.close(); tunFd = null
                return false
            }

            val ygg = yggCls.getDeclaredConstructor().newInstance()
            yggInstance = ygg

            // 3. Start the router. The contrib/mobile package exposes
            //    `startJSON([]byte) error` which boots Yggdrasil with the
            //    given config and a no-op TUN; we feed packets ourselves.
            yggCls.getMethod("startJSON", ByteArray::class.java)
                .invoke(ygg, configJson.toByteArray(Charsets.UTF_8))

            // 4. Pump packets
            startPumps(ygg, pfd)
            Log.i(TAG, "Yggdrasil started; TUN address=$ourAddress")
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
