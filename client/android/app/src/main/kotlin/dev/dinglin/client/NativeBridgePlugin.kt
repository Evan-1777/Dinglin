package dev.dinglin.client

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.os.Handler
import android.os.Looper
import androidx.core.app.ActivityCompat
import com.google.firebase.FirebaseApp
import com.google.firebase.messaging.FirebaseMessaging
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.lang.ref.WeakReference
import java.util.TimeZone

object NativeBridgePlugin : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private const val METHOD_CHANNEL = "dev.dinglin/native"
    private const val EVENT_CHANNEL = "dev.dinglin/events"

    private val mainHandler = Handler(Looper.getMainLooper())
    private var appContext: Context? = null
    private var activityRef: WeakReference<Activity>? = null
    private var eventSink: EventChannel.EventSink? = null
    private var pendingPermResult: MethodChannel.Result? = null

    fun attach(activity: Activity, messenger: BinaryMessenger) {
        appContext = activity.applicationContext
        activityRef = WeakReference(activity)
        MethodChannel(messenger, METHOD_CHANNEL).setMethodCallHandler(this)
        EventChannel(messenger, EVENT_CHANNEL).setStreamHandler(this)
    }

    fun detachActivity(activity: Activity) {
        if (activityRef?.get() === activity) {
            activityRef = null
        }
    }

    fun onRequestPermissionsResult(requestCode: Int, grantResults: IntArray) {
        if (requestCode != PermissionHelper.REQ_POST_NOTIFICATIONS) return
        val pending = pendingPermResult
        pendingPermResult = null
        val granted = grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED
        if (!granted) {
            val act = activityRef?.get()
            if (act != null && !ActivityCompat.shouldShowRequestPermissionRationale(act, Manifest.permission.POST_NOTIFICATIONS)) {
                PermissionHelper.openNotificationSettings(act)
            }
        }
        pending?.success(granted)
    }

    fun emitEvent(event: Map<String, Any?>) {
        if (Looper.myLooper() == Looper.getMainLooper()) {
            eventSink?.success(event)
        } else {
            mainHandler.post { eventSink?.success(event) }
        }
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
            "startAlarmRinging" -> {
                val id = call.argument<String>("id") ?: ""
                val title = call.argument<String>("title") ?: "Dinglin 闹钟"
                val body = call.argument<String>("body") ?: ""
                val snoozeMins = (call.argument<Number>("snooze_minutes"))?.toInt() ?: 10
                val vibrate = call.argument<Boolean>("vibrate") ?: true
                AlarmRingService.startSafely(
                    ctx,
                    scheduleId = id,
                    title = title,
                    body = body,
                    snoozeMinutes = snoozeMins,
                    vibrate = vibrate,
                )
                result.success(null)
            }
            "stopRinging" -> {
                val scheduleId = call.argument<String>("schedule_id")
                AlarmRingService.stopIfMatching(ctx, scheduleId)
                result.success(null)
            }
            "setAppForeground" -> {
                val foreground = call.argument<Boolean>("foreground") ?: true
                KeepAliveManager.setAppForeground(ctx, foreground)
                result.success(null)
            }
            "supportsAutoStartSettings" -> {
                result.success(PermissionHelper.hasAutoStartIntent(ctx))
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
            "configureKeepAlive" -> {
                val mode = call.argument<String>("mode") ?: "auto"
                val intervalMin = (call.argument<Number>("interval_min"))?.toInt() ?: 5
                ScheduleStore.saveKeepAlive(ctx, mode, intervalMin)
                KeepAliveManager.apply(ctx)
                result.success(null)
            }
            "getPermissionStatus" -> {
                result.success(PermissionHelper.getStatus(ctx))
            }
            "requestPermission" -> {
                val permission = call.argument<String>("permission") ?: ""
                pendingPermResult?.success(false)
                pendingPermResult = result
                val completedSync = PermissionHelper.requestPermission(activityRef?.get(), ctx, permission) { granted ->
                    if (pendingPermResult === result) {
                        pendingPermResult = null
                        result.success(granted)
                    }
                }
                if (completedSync && pendingPermResult === result) {
                    pendingPermResult = null
                }
            }
            "updateSyncCursor" -> {
                val lastSeq = (call.argument<Number>("last_seq"))?.toLong() ?: 0L
                val reset = call.argument<Boolean>("reset") ?: false
                if (reset) {
                    ScheduleStore.resetLastSeq(ctx)
                } else {
                    ScheduleStore.saveLastSeq(ctx, lastSeq)
                }
                result.success(null)
            }
            "getSyncCursor" -> {
                result.success(ScheduleStore.lastSeq(ctx))
            }
            "getLocalTimezone" -> {
                result.success(TimeZone.getDefault().id)
            }
            "updateDndPolicy" -> {
                val enabled = call.argument<Boolean>("enabled") ?: false
                val start = call.argument<String>("start") ?: "23:00"
                val end = call.argument<String>("end") ?: "07:00"
                ScheduleStore.saveDndPolicy(ctx, enabled, start, end)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }
}
