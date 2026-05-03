package com.phantom.phantom_messenger

import android.app.WallpaperManager
import android.graphics.Bitmap
import android.graphics.Canvas
import android.graphics.drawable.BitmapDrawable
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel
import java.io.ByteArrayOutputStream

class MainActivity : FlutterActivity() {
    private var gattServer: PhantomGattServer? = null

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

    override fun onDestroy() {
        gattServer?.stop()
        super.onDestroy()
    }
}
