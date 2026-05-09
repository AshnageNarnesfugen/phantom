package com.phantom.phantom_messenger

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.Build
import android.util.Log

/**
 * Restarts the IPFS foreground service when the device boots.
 * Also handles the AlarmManager restart triggered from onTaskRemoved().
 *
 * This ensures Kubo stays alive across device reboots and aggressive
 * OEM task killers.
 */
class IpfsBootReceiver : BroadcastReceiver() {

    companion object {
        const val TAG = "IpfsBootReceiver"
    }

    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return

        Log.i(TAG, "Boot completed — checking if IPFS service should restart")

        val prefs = context.getSharedPreferences(
            IpfsForegroundService.PREFS_NAME,
            Context.MODE_PRIVATE
        )
        val binary = prefs.getString(IpfsForegroundService.KEY_BINARY, null)
        val repo   = prefs.getString(IpfsForegroundService.KEY_REPO, null)

        if (binary != null && repo != null) {
            Log.i(TAG, "Saved paths found — restarting IPFS foreground service")
            val serviceIntent = IpfsForegroundService.startIntent(context, binary, repo)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                context.startForegroundService(serviceIntent)
            } else {
                context.startService(serviceIntent)
            }
        } else {
            Log.i(TAG, "No saved paths — IPFS service was never started, skipping")
        }
    }
}
