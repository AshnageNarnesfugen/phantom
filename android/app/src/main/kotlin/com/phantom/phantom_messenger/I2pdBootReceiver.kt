package com.phantom.phantom_messenger

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/**
 * Restarts the i2pd foreground service when the device boots.
 * Mirror of [IpfsBootReceiver] for the I2P transport.
 */
class I2pdBootReceiver : BroadcastReceiver() {

    companion object {
        const val TAG = "I2pdBootReceiver"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return

        Log.i(TAG, "Boot completed — checking if i2pd service should restart")

        val prefs = context.getSharedPreferences(
            I2pdForegroundService.PREFS_NAME,
            Context.MODE_PRIVATE
        )
        val binary = prefs.getString(I2pdForegroundService.KEY_BINARY, null)
        val data   = prefs.getString(I2pdForegroundService.KEY_DATA, null)

        if (binary != null && data != null) {
            Log.i(TAG, "Saved paths found — restarting i2pd foreground service")
            val serviceIntent = I2pdForegroundService.startIntent(context, binary, data)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(serviceIntent)
            } else {
                context.startService(serviceIntent)
            }
        } else {
            Log.i(TAG, "No saved paths — i2pd service was never started, skipping")
        }
    }
}
