package com.phantom.phantom_messenger

import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.plugin.common.MethodChannel

class MainActivity : FlutterActivity() {
    private var gattServer: PhantomGattServer? = null

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // Block screenshots and Recents thumbnail for privacy.
        window.setFlags(
            WindowManager.LayoutParams.FLAG_SECURE,
            WindowManager.LayoutParams.FLAG_SECURE,
        )

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
