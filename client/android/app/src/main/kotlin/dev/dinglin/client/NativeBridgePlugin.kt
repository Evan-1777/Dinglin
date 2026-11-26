package dev.dinglin.client

import android.content.Context
import android.content.Intent
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

object NativeBridgePlugin : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private const val METHOD_CHANNEL = "dev.dinglin/native"
    private const val EVENT_CHANNEL = "dev.dinglin/events"

    private var appContext: Context? = null
    private var eventSink: EventChannel.EventSink? = null

    fun attach(context: Context, messenger: BinaryMessenger) {
        appContext = context.applicationContext
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler(this)
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(this)
    }

    fun emitEvent(event: Map<String, Any?>) {
        eventSink?.success(event)
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        eventSink = events
    }

    override fun onCancel(arguments: Any?) {
        eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val ctx = appContext ?: run {
            result.error("NO_CONTEXT", "Android context unavailable", null)
            return
        }

        when (call.method) {
            "configure" -> {
                val url = call.argument<String>("server_url") ?: ""
                val token = call.argument<String>("auth_token") ?: ""
                val devId = call.argument<String>("device_id") ?: ""
                ScheduleStore.saveConfig(ctx, url, token, devId)
                result.success(null)
            }
            "syncSchedules" -> {
                val rawList = call.argument<List<Map<String, Any?>>>("schedules") ?: emptyList()
                val parsed = rawList.mapNotNull { m ->
                    val id = m["id"]?.toString() ?: return@mapNotNull null
                    LocalSchedule(
                        id = id,
                        kind = m["kind"]?.toString() ?: "scheduled_notification",
                        title = m["title"]?.toString() ?: "",
                        body = m["body"]?.toString() ?: "",
                        priority = m["priority"]?.toString() ?: "normal",
                        nextFireAtMs = (m["next_fire_at_ms"] as? Number)?.toLong() ?: 0L,
                        snoozeMinutes = (m["snooze_minutes"] as? Number)?.toInt() ?: 10,
                        vibrate = (m["vibrate"] as? Boolean) ?: true,
                        enabled = (m["enabled"] as? Boolean) ?: true,
                        state = m["state"]?.toString() ?: "active",
                    )
                }
                ExactAlarmScheduler.syncAll(ctx, parsed)
                result.success(null)
            }
            "showNotification" -> {
                val id = call.argument<String>("id") ?: "notif"
                val title = call.argument<String>("title") ?: "Dinglin"
                val body = call.argument<String>("body") ?: ""
                val priority = call.argument<String>("priority") ?: "normal"
                NotificationChannels.showNotification(ctx, id, title, body, priority)
                result.success(null)
            }
            "stopRinging" -> {
                ctx.stopService(Intent(ctx, AlarmRingService::class.java))
                result.success(null)
            }
            "hasGms" -> {
                val available = try {
                    FirebaseApp.getApps(ctx).isNotEmpty()
                } catch (_: Throwable) {
                    false
                }
                result.success(available)
            }
            "getFcmToken" -> {
                if (FirebaseApp.getApps(ctx).isEmpty()) {
                    result.success(null)
                    return
                }
                try {
                    FirebaseMessaging.getInstance().token
                        .addOnSuccessListener { tok -> result.success(tok) }
                        .addOnFailureListener { result.success(null) }
                } catch (_: Throwable) {
                    result.success(null)
                }
            }
            else -> result.notImplemented()
        }
    }
}
