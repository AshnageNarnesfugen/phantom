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
                    val bytes = (call.arguments as List<*>)
                        .map { (it as Int).toByte() }
                        .toByteArray()
                    server.start(bytes)
                    result.success(null)
                }
                "stop" -> {
                    server.stop()
                    result.success(null)
                }
                "notifyAll" -> {
                    val bytes = (call.arguments as List<*>)
                        .map { (it as Int).toByte() }
                        .toByteArray()
                    server.notifyAll(bytes)
                    result.success(null)
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
