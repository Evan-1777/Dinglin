package dev.dinglin.client

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class BootRestoreReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        when (intent.action) {
            Intent.ACTION_BOOT_COMPLETED,
            Intent.ACTION_TIMEZONE_CHANGED,
            Intent.ACTION_MY_PACKAGE_REPLACED -> {
                NotificationChannels.ensureCreated(context)
                ExactAlarmScheduler.restoreAll(context)
            }
        }
    }
}
