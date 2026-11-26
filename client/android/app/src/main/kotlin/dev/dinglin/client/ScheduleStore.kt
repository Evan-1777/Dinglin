package dev.dinglin.client

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject
import java.util.Calendar

data class LocalSchedule(
    val id: String,
    val kind: String,
    val title: String,
    val body: String,
    val priority: String,
    val nextFireAtMs: Long,
    val snoozeMinutes: Int,
    val vibrate: Boolean,
    val enabled: Boolean,
    val state: String,
)

object ScheduleStore {
    private const val PREFS = "dinglin_native_store"
    private const val KEY_SERVER_URL = "server_url"
    private const val KEY_AUTH_TOKEN = "auth_token"
    private const val KEY_DEVICE_ID = "device_id"
    private const val KEY_SCHEDULES = "schedules_json"
    private const val KEY_KEEPALIVE_MODE = "keepalive_mode"
    private const val KEY_KEEPALIVE_INTERVAL = "keepalive_interval_min"
    private const val KEY_LAST_SEQ = "last_seq"
    private const val KEY_DND_ENABLED = "dnd_enabled"
    private const val KEY_DND_START = "dnd_start"
    private const val KEY_DND_END = "dnd_end"

    fun saveConfig(context: Context, serverUrl: String, authToken: String, deviceId: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(KEY_SERVER_URL, serverUrl.trimEnd('/'))
            .putString(KEY_AUTH_TOKEN, authToken)
            .putString(KEY_DEVICE_ID, deviceId)
            .apply()
    }

    fun serverUrl(context: Context): String =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_SERVER_URL, "") ?: ""

    fun authToken(context: Context): String =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_AUTH_TOKEN, "") ?: ""

    fun deviceId(context: Context): String =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).getString(KEY_DEVICE_ID, "") ?: ""

    fun saveSchedules(context: Context, list: List<LocalSchedule>) {
        val arr = JSONArray()
        for (s in list) {
            arr.put(
                JSONObject()
                    .put("id", s.id)
                    .put("kind", s.kind)
                    .put("title", s.title)
                    .put("body", s.body)
                    .put("priority", s.priority)
                    .put("next_fire_at_ms", s.nextFireAtMs)
                    .put("snooze_minutes", s.snoozeMinutes)
                    .put("vibrate", s.vibrate)
                    .put("enabled", s.enabled)
                    .put("state", s.state)
            )
        }
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(KEY_SCHEDULES, arr.toString())
            .apply()
    }

    fun loadSchedules(context: Context): List<LocalSchedule> {
        val raw = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_SCHEDULES, "[]") ?: "[]"
        val out = mutableListOf<LocalSchedule>()
        try {
            val arr = JSONArray(raw)
            for (i in 0 until arr.length()) {
                val o = arr.getJSONObject(i)
                out.add(
                    LocalSchedule(
                        id = o.optString("id"),
                        kind = o.optString("kind", "scheduled_notification"),
                        title = o.optString("title"),
                        body = o.optString("body"),
                        priority = o.optString("priority", "normal"),
                        nextFireAtMs = o.optLong("next_fire_at_ms", 0L),
                        snoozeMinutes = o.optInt("snooze_minutes", 10),
                        vibrate = o.optBoolean("vibrate", true),
                        enabled = o.optBoolean("enabled", true),
                        state = o.optString("state", "active"),
                    )
                )
            }
        } catch (_: Exception) {
        }
        return out
    }

    fun saveKeepAlive(context: Context, mode: String, intervalMin: Int) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putString(KEY_KEEPALIVE_MODE, mode)
            .putInt(KEY_KEEPALIVE_INTERVAL, intervalMin.coerceAtLeast(5))
            .apply()
    }

    fun keepAliveMode(context: Context): String =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getString(KEY_KEEPALIVE_MODE, "auto") ?: "auto"

    fun keepAliveIntervalMin(context: Context): Int =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getInt(KEY_KEEPALIVE_INTERVAL, 5).coerceAtLeast(5)

    fun lastSeq(context: Context): Long =
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .getLong(KEY_LAST_SEQ, 0L)

    fun saveLastSeq(context: Context, seq: Long) {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (seq > prefs.getLong(KEY_LAST_SEQ, 0L)) {
            prefs.edit().putLong(KEY_LAST_SEQ, seq).apply()
        }
    }

    fun resetLastSeq(context: Context) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putLong(KEY_LAST_SEQ, 0L)
            .apply()
    }

    fun saveDndPolicy(context: Context, enabled: Boolean, start: String, end: String) {
        context.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putBoolean(KEY_DND_ENABLED, enabled)
            .putString(KEY_DND_START, start)
            .putString(KEY_DND_END, end)
            .apply()
    }

    fun isWithinDnd(context: Context, now: Calendar = Calendar.getInstance()): Boolean {
        val prefs = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        if (!prefs.getBoolean(KEY_DND_ENABLED, false)) return false
        val startMin = parseHhMm(prefs.getString(KEY_DND_START, "23:00")) ?: return false
        val endMin = parseHhMm(prefs.getString(KEY_DND_END, "07:00")) ?: return false
        if (startMin == endMin) return false
        val curMin = now.get(Calendar.HOUR_OF_DAY) * 60 + now.get(Calendar.MINUTE)
        return if (startMin < endMin) {
            curMin in startMin until endMin
        } else {
            curMin >= startMin || curMin < endMin
        }
    }

    private fun parseHhMm(raw: String?): Int? {
        if (raw == null) return null
        val parts = raw.trim().split(':')
        if (parts.size != 2) return null
        val h = parts[0].toIntOrNull() ?: return null
        val m = parts[1].toIntOrNull() ?: return null
        if (h !in 0..23 || m !in 0..59) return null
        return h * 60 + m
    }
}
