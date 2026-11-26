package dev.dinglin.client

import android.content.Context
import org.json.JSONArray
import org.json.JSONObject

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
}
