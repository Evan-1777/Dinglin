package dev.dinglin.client

import androidx.core.content.ContextCompat
import android.content.Intent
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessagingService
import com.google.firebase.messaging.RemoteMessage
import org.json.JSONObject
import kotlin.concurrent.thread

/**
 * Compile-safe optional FCM receiver.
 * Every Firebase runtime access is guarded by FirebaseApp.getApps(context).isNotEmpty().
 */
class DinglinMessagingService : FirebaseMessagingService() {
    override fun onMessageReceived(message: RemoteMessage) {
        if (FirebaseApp.getApps(applicationContext).isEmpty()) return
        val data = message.data
        val title = data["title"] ?: message.notification?.title ?: "Dinglin 提醒"
        val body = data["body"] ?: message.notification?.body ?: ""
        val priority = data["priority"] ?: "normal"
        val entityId = data["entity_id"] ?: System.currentTimeMillis().toString()
        val eventType = data["event_type"] ?: "notification.created"

        if (priority == "critical" && eventType == "notification.created") {
            val svc = Intent(applicationContext, AlarmRingService::class.java).apply {
                putExtra("schedule_id", entityId)
                putExtra("title", title)
                putExtra("body", body)
                putExtra("vibrate", true)
            }
            ContextCompat.startForegroundService(applicationContext, svc)
        } else {
            NotificationChannels.showNotification(applicationContext, entityId, title, body, priority)
        }

        NativeBridgePlugin.emitEvent(
            mapOf(
                "type" to "fcm_wakeup",
                "event_type" to eventType,
                "entity_id" to entityId,
            )
        )
    }

    override fun onNewToken(token: String) {
        if (FirebaseApp.getApps(applicationContext).isEmpty()) return
        val baseUrl = ScheduleStore.serverUrl(applicationContext)
        val authToken = ScheduleStore.authToken(applicationContext)
        val deviceId = ScheduleStore.deviceId(applicationContext)
        if (baseUrl.isNotEmpty() && authToken.isNotEmpty() && deviceId.isNotEmpty()) {
            thread(name = "dinglin-fcm-token-sync") {
                AlarmTriggerReceiver.postJson(
                    "$baseUrl/api/v1/devices/$deviceId/fcm-token",
                    authToken,
                    JSONObject()
                        .put("fcm_token", token)
                        .put("has_gms", true)
                        .toString()
                )
            }
        }
        NativeBridgePlugin.emitEvent(mapOf("type" to "fcm_token", "token" to token))
    }
}
