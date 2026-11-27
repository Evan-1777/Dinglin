package dev.dinglin.client

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import com.google.firebase.FirebaseApp
import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.atomic.AtomicBoolean

object KeepAliveManager {
    private const val POLL_REQUEST_CODE = 0x44494E47
    private const val POLL_ACTION = "dev.dinglin.KEEPALIVE_POLL"
    private const val AUTO_FALLBACK_INTERVAL_MIN = 15

    // Strictly in-memory foreground flag so process kill never leaves background sync stuck off.
    @Volatile
    var isAppForeground: Boolean = false
        private set

    private val syncing = AtomicBoolean(false)

    private val isoUtcFormat = object : ThreadLocal<SimpleDateFormat>() {
        override fun initialValue(): SimpleDateFormat {
            return SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss", Locale.US).apply {
                timeZone = TimeZone.getTimeZone("UTC")
            }
        }
    }

    fun setAppForeground(context: Context, foreground: Boolean) {
        isAppForeground = foreground
        if (foreground) {
            cancelPolling(context)
        } else {
            apply(context)
        }
    }

    fun shouldRunBackgroundPoll(context: Context): Boolean {
        if (isAppForeground) return false
        val mode = ScheduleStore.keepAliveMode(context)
        if (mode == "polling") return true
        if (mode == "auto" && !hasFirebaseApp(context)) return true
        return false
    }

    fun apply(context: Context) {
        if (!shouldRunBackgroundPoll(context)) {
            cancelPolling(context)
            return
        }
        val mode = ScheduleStore.keepAliveMode(context)
        val intervalMin = if (mode == "auto") {
            AUTO_FALLBACK_INTERVAL_MIN
        } else {
            ScheduleStore.keepAliveIntervalMin(context)
        }
        scheduleNextPoll(context, intervalMin)
    }

    fun scheduleNextPoll(context: Context, intervalMin: Int) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pi = buildPollPendingIntent(context)
        val triggerAt = System.currentTimeMillis() + intervalMin.coerceAtLeast(5) * 60_000L
        // Use power-friendly inexact alarm for routine background sync so Android can batch Doze wakeups.
        am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, triggerAt, pi)
    }

    fun cancelPolling(context: Context) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val intent = Intent(context, KeepAliveSyncReceiver::class.java).apply {
            action = POLL_ACTION
        }
        val pi = PendingIntent.getBroadcast(
            context,
            POLL_REQUEST_CODE,
            intent,
            PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE
        )
        if (pi != null) {
            am.cancel(pi)
            pi.cancel()
        }
    }

    fun isNetworkAvailable(context: Context): Boolean {
        return try {
            val cm = context.getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                val net = cm.activeNetwork ?: return false
                val caps = cm.getNetworkCapabilities(net) ?: return false
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            } else {
                @Suppress("DEPRECATION")
                cm.activeNetworkInfo?.isConnected == true
            }
        } catch (_: Throwable) {
            true
        }
    }

    fun syncOnceBackground(context: Context) {
        if (!syncing.compareAndSet(false, true)) return
        try {
            val baseUrl = ScheduleStore.serverUrl(context)
            val token = ScheduleStore.authToken(context)
            if (baseUrl.isEmpty() || token.isEmpty()) return

            if (!isNetworkAvailable(context)) {
                SyncJobService.scheduleImmediateOnNetwork(context)
                return
            }

            var curSeq = ScheduleStore.lastSeq(context)
            val isBootstrap = curSeq == 0L
            var hasMore = true
            var guard = 0
            var schedulesDirty = false
            val localSchedules = ScheduleStore.loadSchedules(context).toMutableList()

            while (hasMore && guard < 20) {
                guard++
                var conn: HttpURLConnection? = null
                try {
                    conn = (URL("$baseUrl/api/v1/sync?since_seq=$curSeq&limit=100").openConnection() as HttpURLConnection).apply {
                        requestMethod = "GET"
                        connectTimeout = 8000
                        readTimeout = 8000
                        setRequestProperty("Authorization", "Bearer $token")
                    }
                    if (conn.responseCode != 200) break
                    val body = conn.inputStream.bufferedReader(Charsets.UTF_8).use { it.readText() }
                    val root = JSONObject(body)
                    val events = root.optJSONArray("events")
                    val latestSeq = root.optLong("latest_seq", curSeq)
                    hasMore = root.optBoolean("has_more", false)

                    if (events != null) {
                        for (i in 0 until events.length()) {
                            val ev = events.optJSONObject(i) ?: continue
                            val eventType = ev.optString("event_type")
                            val entityId = ev.optString("entity_id")
                            val payload = ev.optJSONObject("payload")

                            if (eventType == "schedule.upsert" && payload != null) {
                                val parsed = parseSchedule(payload)
                                if (parsed != null) {
                                    val idx = localSchedules.indexOfFirst { it.id == parsed.id }
                                    if (idx >= 0) localSchedules[idx] = parsed else localSchedules.add(parsed)
                                    schedulesDirty = true
                                    if (!isBootstrap) {
                                        if (parsed.kind == "alarm" && parsed.state == "ringing") {
                                            AlarmRingService.startSafely(
                                                context,
                                                scheduleId = parsed.id,
                                                title = parsed.title,
                                                body = parsed.body,
                                                snoozeMinutes = parsed.snoozeMinutes,
                                                vibrate = parsed.vibrate,
                                            )
                                        } else {
                                            AlarmRingService.stopIfMatching(context, parsed.id)
                                        }
                                    }
                                }
                                if (!isBootstrap) {
                                    NativeBridgePlugin.emitEvent(
                                        mapOf(
                                            "type" to "background_schedule_changed",
                                            "event_type" to eventType,
                                            "entity_id" to entityId,
                                        )
                                    )
                                }
                            } else if (eventType == "schedule.delete") {
                                if (localSchedules.removeAll { it.id == entityId }) {
                                    schedulesDirty = true
                                }
                                if (!isBootstrap) {
                                    AlarmRingService.stopIfMatching(context, entityId)
                                    NativeBridgePlugin.emitEvent(
                                        mapOf(
                                            "type" to "background_schedule_changed",
                                            "event_type" to eventType,
                                            "entity_id" to entityId,
                                        )
                                    )
                                }
                            } else if (!isBootstrap && eventType == "notification.created" && payload != null) {
                                val status = payload.optString("status", "unread")
                                if (status != "unread") continue
                                val priority = payload.optString("priority", "normal")
                                val title = payload.optString("title", "Dinglin 提醒")
                                val msgBody = payload.optString("body", "")
                                NotificationChannels.showNotification(context, entityId, title, msgBody, priority)
                            }
                        }
                    }

                    if (latestSeq > curSeq) {
                        curSeq = latestSeq
                        ScheduleStore.saveLastSeq(context, latestSeq)
                    } else {
                        break
                    }
                } catch (_: Exception) {
                    break
                } finally {
                    conn?.disconnect()
                }
            }

            if (schedulesDirty) {
                ExactAlarmScheduler.syncAll(context, localSchedules)
            }
            if (!isBootstrap && curSeq > 0L) {
                NativeBridgePlugin.emitEvent(
                    mapOf(
                        "type" to "background_synced",
                        "latest_seq" to curSeq,
                    )
                )
            }
        } finally {
            syncing.set(false)
        }
    }

    private fun hasFirebaseApp(context: Context): Boolean {
        return try {
            FirebaseApp.getApps(context).isNotEmpty()
        } catch (_: Throwable) {
            false
        }
    }

    private fun parseSchedule(o: JSONObject): LocalSchedule? {
        val id = o.optString("id")
        if (id.isEmpty()) return null
        return LocalSchedule(
            id = id,
            kind = o.optString("kind", "scheduled_notification"),
            title = o.optString("title"),
            body = o.optString("body"),
            priority = o.optString("priority", "normal"),
            nextFireAtMs = parseIsoUtcMillis(o.optString("next_fire_at")),
            snoozeMinutes = o.optInt("snooze_minutes", 10),
            vibrate = o.optBoolean("vibrate", true),
            enabled = o.optBoolean("enabled", true),
            state = o.optString("state", "active"),
        )
    }

    private fun parseIsoUtcMillis(raw: String): Long {
        if (raw.isBlank()) return 0L
        return try {
            val cleaned = raw.trim()
                .replace(Regex("\\.\\d+"), "")
                .removeSuffix("Z")
            isoUtcFormat.get()?.parse(cleaned)?.time ?: 0L
        } catch (_: Exception) {
            0L
        }
    }

    private fun buildPollPendingIntent(context: Context): PendingIntent {
        val intent = Intent(context, KeepAliveSyncReceiver::class.java).apply {
            action = POLL_ACTION
        }
        return PendingIntent.getBroadcast(
            context,
            POLL_REQUEST_CODE,
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }
}
