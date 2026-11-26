package dev.dinglin.client

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import kotlin.concurrent.thread

class KeepAliveSyncReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val pending = goAsync()
        thread(name = "dinglin-keepalive-poll") {
            try {
                KeepAliveManager.syncOnceBackground(context)
                if (ScheduleStore.keepAliveMode(context) == "polling") {
                    KeepAliveManager.scheduleNextPoll(context, ScheduleStore.keepAliveIntervalMin(context))
                }
            } finally {
                pending.finish()
            }
        }
    }
}
