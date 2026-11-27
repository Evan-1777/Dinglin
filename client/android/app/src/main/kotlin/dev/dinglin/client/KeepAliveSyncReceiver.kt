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
                KeepAliveManager.syncOnceBackground(context.applicationContext)
                KeepAliveManager.apply(context.applicationContext)
            } finally {
                pending.finish()
            }
        }
    }
}
