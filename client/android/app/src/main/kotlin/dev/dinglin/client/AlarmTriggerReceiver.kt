package dev.dinglin.client

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.os.PowerManager
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import kotlin.concurrent.thread

class AlarmTriggerReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.action
        if (action == AlarmRingService.ACTION_STOP || action == AlarmRingService.ACTION_SNOOZE) {
            val scheduleId = intent.getStringExtra("schedule_id") ?: ""
            val title = intent.getStringExtra("title") ?: "Dinglin 闹钟"
            val body = intent.getStringExtra("body") ?: ""
            val snoozeMins = intent.getIntExtra("snooze_minutes", 10)
            val vibrate = intent.getBooleanExtra("vibrate", true)
            AlarmRingService.performAction(
                context.applicationContext,
                action,
                scheduleId,
                title,
                body,
                snoozeMins,
                vibrate
            )
            return
        }

        val scheduleId = intent.getStringExtra("schedule_id") ?: return
        val kind = intent.getStringExtra("kind") ?: "scheduled_notification"
        val title = intent.getStringExtra("title") ?: "Dinglin 提醒"
        val body = intent.getStringExtra("body") ?: ""
        val priority = intent.getStringExtra("priority") ?: "normal"
        val fireTs = intent.getLongExtra("fire_ts", System.currentTimeMillis() / 1000L)
        val snoozeMinutes = intent.getIntExtra("snooze_minutes", 10)
        val vibrate = intent.getBooleanExtra("vibrate", true)

        val occKey = "sched:$scheduleId:$fireTs"
        reportTriggeredAsync(context.applicationContext, scheduleId, occKey)

        // Strictly separate alarms from notifications: only kind == "alarm" starts AlarmRingService.
        if (kind == "alarm") {
            val handoffLock = acquireHandoffWakeLock(context)
            try {
                AlarmRingService.startSafely(
                    context.applicationContext,
                    scheduleId = scheduleId,
                    title = title,
                    body = body,
                    snoozeMinutes = snoozeMinutes,
                    vibrate = vibrate,
                )
            } finally {
                try {
                    if (handoffLock?.isHeld == true) handoffLock.release()
                } catch (_: Throwable) {
                }
            }
        } else {
            NotificationChannels.showNotification(context.applicationContext, scheduleId, title, body, priority)
        }

        NativeBridgePlugin.emitEvent(
            mapOf(
                "type" to "schedule_fired",
                "schedule_id" to scheduleId,
                "kind" to kind,
                "occurrence_key" to occKey,
            )
        )
    }

    private fun acquireHandoffWakeLock(context: Context): PowerManager.WakeLock? {
        return try {
            val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "dinglin:alarm-handoff").apply {
                setReferenceCounted(false)
                acquire(15_000L)
            }
        } catch (_: Throwable) {
            null
        }
    }

    companion object {
        fun reportTriggeredAsync(context: Context, scheduleId: String, occKey: String) {
            val baseUrl = ScheduleStore.serverUrl(context)
            val token = ScheduleStore.authToken(context)
            if (baseUrl.isEmpty() || token.isEmpty()) return
            thread(name = "dinglin-trigger-report") {
                postJson(
                    "$baseUrl/api/v1/schedules/$scheduleId/triggered",
                    token,
                    JSONObject().put("occurrence_key", occKey).toString()
                )
            }
        }

        fun postJson(urlStr: String, token: String, jsonBody: String): Int {
            return try {
                val conn = (URL(urlStr).openConnection() as HttpURLConnection).apply {
                    requestMethod = "POST"
                    connectTimeout = 8000
                    readTimeout = 8000
                    doOutput = true
                    setRequestProperty("Content-Type", "application/json")
                    setRequestProperty("Authorization", "Bearer $token")
                }
                conn.outputStream.use { it.write(jsonBody.toByteArray(Charsets.UTF_8)) }
                val code = conn.responseCode
                conn.disconnect()
                code
            } catch (_: Exception) {
                -1
            }
        }
    }
}
