package dev.dinglin.client

import android.app.AlarmManager
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent

class BootRestoreReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action ?: return
        val shouldRestore = action == Intent.ACTION_BOOT_COMPLETED ||
            action == Intent.ACTION_TIME_CHANGED ||
            action == Intent.ACTION_TIMEZONE_CHANGED ||
            action == Intent.ACTION_MY_PACKAGE_REPLACED ||
            action == AlarmManager.ACTION_SCHEDULE_EXACT_ALARM_PERMISSION_STATE_CHANGED

        if (shouldRestore) {
            val appCtx = context.applicationContext
            NotificationChannels.ensureCreated(appCtx)
            ExactAlarmScheduler.restoreAll(appCtx)
            SyncJobService.scheduleImmediateOnNetwork(appCtx)
            KeepAliveManager.apply(appCtx)
        }
    }
}
