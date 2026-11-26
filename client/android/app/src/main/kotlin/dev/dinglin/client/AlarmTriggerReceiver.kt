package dev.dinglin.client

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import kotlin.concurrent.thread

class AlarmTriggerReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val scheduleId = intent.getStringExtra("schedule_id") ?: return
        val kind = intent.getStringExtra("kind") ?: "scheduled_notification"
        val title = intent.getStringExtra("title") ?: "Dinglin 提醒"
        val body = intent.getStringExtra("body") ?: ""
        val priority = intent.getStringExtra("priority") ?: "normal"
        val fireTs = intent.getLongExtra("fire_ts", System.currentTimeMillis() / 1000L)
        val snoozeMinutes = intent.getIntExtra("snooze_minutes", 10)
        val vibrate = intent.getBooleanExtra("vibrate", true)

        val occKey = "sched:$scheduleId:$fireTs"
        reportTriggeredAsync(context, scheduleId, occKey)

        if (kind == "alarm" || priority == "critical") {
            val svcIntent = Intent(context, AlarmRingService::class.java).apply {
                putExtra("schedule_id", scheduleId)
                putExtra("title", title)
                putExtra("body", body)
                putExtra("snooze_minutes", snoozeMinutes)
                putExtra("vibrate", vibrate)
            }
            ContextCompat.startForegroundService(context, svcIntent)
        } else {
            NotificationChannels.showNotification(context, scheduleId, title, body, priority)
        }

        NativeBridgePlugin.emitEvent(
            mapOf(
                "type" to "schedule_fired",
                "schedule_id" to scheduleId,
                "occurrence_key" to occKey,
            )
        )
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
