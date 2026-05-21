package com.phantom.phantom_messenger

import android.app.WallpaperManager
import android.content.Context
import android.content.Intent
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.net.VpnService
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class MainActivity : FlutterActivity() {
    private var gattServer: PhantomGattServer? = null
    private var pendingVpnPermissionResult: MethodChannel.Result? = null
    private val VPN_PERMISSION_REQ = 0xFEED

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Block screenshots and Recents thumbnail for privacy.
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE,
        )

        // ── System utilities channel ──────────────────────────────────────────
        MethodChannel(
            flutterEngine!!.dartExecutor.binaryMessenger,
            "phantom/system",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getDeviceWallpaper" -> {
                    try {
                        val wm  = WallpaperManager.getInstance(applicationContext)
                        val drw = wm.drawable
                        if (drw == null) { result.success(null); return@setMethodCallHandler }
                        val bmp = if (drw is BitmapDrawable) {
                            drw.bitmap
                        } else {
                            val w = drw.intrinsicWidth.coerceAtLeast(1)
                            val h = drw.intrinsicHeight.coerceAtLeast(1)
                            val b = Bitmap.createBitmap(w, h, Bitmap.Config.ARGB_8888)
                            val c = Canvas(b)
                            drw.setBounds(0, 0, w, h)
                            drw.draw(c)
                            b
                        }
                        val out = ByteArrayOutputStream()
                        bmp.compress(Bitmap.CompressFormat.JPEG, 85, out)
                        result.success(out.toByteArray())
                    } catch (_: Exception) {
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // ── IPFS daemon channel ───────────────────────────────────────────────
        MethodChannel(
            flutterEngine!!.dartExecutor.binaryMessenger,
            "phantom/ipfs_daemon",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getNativeLibDir" -> {
                    result.success(applicationContext.applicationInfo.nativeLibraryDir)
                }
                "startService" -> {
                    try {
                        val args       = call.arguments as Map<*, *>
                        val binaryPath = args["binaryPath"] as String
                        val repoPath   = args["repoPath"]   as String
                        val intent     = IpfsForegroundService.startIntent(
                            applicationContext, binaryPath, repoPath,
                        )
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("IPFS_START_FAILED", e.message, null)
                    }
                }
                "stopService" -> {
                    startService(IpfsForegroundService.stopIntent(applicationContext))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // ── i2pd daemon channel ───────────────────────────────────────────────
        MethodChannel(
            flutterEngine!!.dartExecutor.binaryMessenger,
            "phantom/i2pd_daemon",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getNativeLibDir" -> {
                    result.success(applicationContext.applicationInfo.nativeLibraryDir)
                }
                "startService" -> {
                    try {
                        val args       = call.arguments as Map<*, *>
                        val binaryPath = args["binaryPath"] as String
                        val dataDir    = args["dataDir"]   as String
                        val intent     = I2pdForegroundService.startIntent(
                            applicationContext, binaryPath, dataDir,
                        )
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("I2PD_START_FAILED", e.message, null)
                    }
                }
                "stopService" -> {
                    startService(I2pdForegroundService.stopIntent(applicationContext))
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }

        // ── Yggdrasil VPN daemon channel ──────────────────────────────────────
        MethodChannel(
            flutterEngine!!.dartExecutor.binaryMessenger,
            "phantom/yggdrasil_daemon",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                // Returns true when the user has already granted VPN permission.
                // When false, the caller should next invoke "requestPermission".
                "isPrepared" -> {
                    result.success(VpnService.prepare(applicationContext) == null)
                }
                "requestPermission" -> {
                    val intent = VpnService.prepare(applicationContext)
                    if (intent == null) {
                        result.success(true)
                    } else {
                        pendingVpnPermissionResult = result
                        startActivityForResult(intent, VPN_PERMISSION_REQ)
                    }
                }
                "startService" -> {
                    try {
                        val args = call.arguments as Map<*, *>
                        val cfg  = args["configJson"] as String
                        val addr = args["address"] as String
                        val intent = YggdrasilVpnService.startIntent(applicationContext, cfg, addr)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("YGG_START_FAILED", e.message, null)
                    }
                }
                "stopService" -> {
                    try {
                        startService(YggdrasilVpnService.stopIntent(applicationContext))
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("YGG_STOP_FAILED", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // ── Messaging service channel ─────────────────────────────────────────
        MethodChannel(
            flutterEngine!!.dartExecutor.binaryMessenger,
            "phantom/messaging",
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "startService" -> {
                    try {
                        val intent = PhantomMessagingService.startIntent(applicationContext)
                        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                            startForegroundService(intent)
                        } else {
                            startService(intent)
                        }
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("START_FAILED", e.message, null)
                    }
                }
                "stopService" -> {
                    try {
                        startService(PhantomMessagingService.stopIntent(applicationContext))
                        result.success(null)
                    } catch (e: Exception) {
                        result.error("STOP_FAILED", e.message, null)
                    }
                }
                else -> result.notImplemented()
            }
        }

        // ── GATT server channel ───────────────────────────────────────────────
        val channel = MethodChannel(
            flutterEngine!!.dartExecutor.binaryMessenger,
            "phantom/gatt_server",
        )
        val server = PhantomGattServer(this, channel)
        gattServer = server

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    // Dart sends Uint8List → arrives as ByteArray via StandardMethodCodec
                    try {
                        server.start(call.arguments as ByteArray)
                        result.success(null)
                    } catch (e: GattStartException) {
                        result.error(e.code, e.message, null)
                    }
                }
                "stop" -> {
                    server.stop()
                    result.success(null)
                }
                "notifyAll" -> {
                    val delivered = server.notifyAll(call.arguments as ByteArray)
                    result.success(delivered)
                }
                else -> result.notImplemented()
            }
        }
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (requestCode == VPN_PERMISSION_REQ) {
            pendingVpnPermissionResult?.success(resultCode == RESULT_OK)
            pendingVpnPermissionResult = null
            return
        }
        super.onActivityResult(requestCode, resultCode, data)
    }

    override fun onDestroy() {
        gattServer?.stop()
        super.onDestroy()
    }
}
