package dev.dinglin.client

import android.app.Activity
import android.content.Intent
import android.graphics.Color
import android.os.Build
import android.os.Bundle
import android.view.Gravity
import android.view.WindowManager
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import org.json.JSONObject
import kotlin.concurrent.thread

/**
 * Lock-screen full-screen alarm UI.
 * Reports snooze/dismiss directly to the Dinglin server via HTTP without requiring FlutterEngine.
 */
class AlarmFullScreenActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON or
                    WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON
            )
        }

        val scheduleId = intent.getStringExtra("schedule_id") ?: ""
        val title = intent.getStringExtra("title") ?: "Dinglin 闹钟"
        val body = intent.getStringExtra("body") ?: ""
        val snoozeMins = intent.getIntExtra("snooze_minutes", 10)

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER
            setBackgroundColor(Color.parseColor("#000000"))
            setPadding(64, 96, 64, 96)
        }

        val titleView = TextView(this).apply {
            text = title
            textSize = 28f
            setTextColor(Color.WHITE)
            gravity = Gravity.CENTER
        }
        val bodyView = TextView(this).apply {
            text = body
            textSize = 16f
            setTextColor(Color.parseColor("#98989D"))
            gravity = Gravity.CENTER
            setPadding(0, 16, 0, 64)
        }

        val snoozeBtn = Button(this).apply {
            text = "贪睡 $snoozeMins 分钟"
            setOnClickListener {
                stopService(Intent(this@AlarmFullScreenActivity, AlarmRingService::class.java))
                reportActionAsync(scheduleId, "snooze", snoozeMins)
                finish()
            }
        }

        val dismissBtn = Button(this).apply {
            text = "关闭"
            setOnClickListener {
                stopService(Intent(this@AlarmFullScreenActivity, AlarmRingService::class.java))
                reportActionAsync(scheduleId, "dismiss", 0)
                finish()
            }
        }

        root.addView(titleView)
        if (body.isNotEmpty()) root.addView(bodyView)
        root.addView(snoozeBtn)
        root.addView(dismissBtn)
        setContentView(root)
    }

    private fun reportActionAsync(scheduleId: String, action: String, snoozeMinutes: Int) {
        if (scheduleId.isEmpty()) return
        val baseUrl = ScheduleStore.serverUrl(this)
        val token = ScheduleStore.authToken(this)
        if (baseUrl.isEmpty() || token.isEmpty()) return
        thread(name = "dinglin-lockscreen-report") {
            val payload = if (action == "snooze") {
                JSONObject().put("minutes", snoozeMinutes).toString()
            } else {
                "{}"
            }
            AlarmTriggerReceiver.postJson(
                "$baseUrl/api/v1/schedules/$scheduleId/$action",
                token,
                payload
            )
        }
    }
}
