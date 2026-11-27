package dev.dinglin.client

import android.animation.AnimatorSet
import android.animation.ObjectAnimator
import android.animation.ValueAnimator
import android.app.Activity
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.graphics.Color
import android.graphics.Typeface
import android.graphics.drawable.GradientDrawable
import android.os.Build
import android.os.Bundle
import android.util.TypedValue
import android.view.Gravity
import android.view.KeyEvent
import android.view.View
import android.view.WindowManager
import android.view.animation.AccelerateDecelerateInterpolator
import android.widget.FrameLayout
import android.widget.LinearLayout
import android.widget.TextClock
import android.widget.TextView
import androidx.core.content.ContextCompat

/**
 * Apple Clock-inspired dark lock-screen full-screen alarm UI.
 * Delegates all snooze/dismiss actions to AlarmRingService.performAction().
 */
class AlarmFullScreenActivity : Activity() {
    private var scheduleId: String = ""
    private var alarmTitle: String = "Dinglin 闹钟"
    private var alarmBody: String = ""
    private var snoozeMins: Int = 10
    private var alarmVibrate: Boolean = true
    private var pulseAnimator: AnimatorSet? = null

    private val ringStateReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context, intent: Intent) {
            val ringing = intent.getBooleanExtra(AlarmRingService.EXTRA_RINGING, true)
            val targetId = intent.getStringExtra(AlarmRingService.EXTRA_SCHEDULE_ID) ?: ""
            if (!ringing && (targetId.isEmpty() || targetId == scheduleId)) {
                finish()
            }
        }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O_MR1) {
            setShowWhenLocked(true)
            setTurnScreenOn(true)
        } else {
            @Suppress("DEPRECATION")
            window.addFlags(
                WindowManager.LayoutParams.FLAG_SHOW_WHEN_LOCKED or
                    WindowManager.LayoutParams.FLAG_TURN_SCREEN_ON
            )
        }
        window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
        window.statusBarColor = Color.TRANSPARENT
        window.navigationBarColor = Color.BLACK

        scheduleId = intent.getStringExtra("schedule_id") ?: ""
        alarmTitle = intent.getStringExtra("title") ?: "Dinglin 闹钟"
        alarmBody = intent.getStringExtra("body") ?: ""
        snoozeMins = intent.getIntExtra("snooze_minutes", 10).coerceAtLeast(1)
        alarmVibrate = intent.getBooleanExtra("vibrate", true)

        val density = resources.displayMetrics.density
        fun dp(v: Int): Int = (v * density).toInt()

        val root = LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            gravity = Gravity.CENTER_HORIZONTAL
            background = GradientDrawable(
                GradientDrawable.Orientation.TOP_BOTTOM,
                intArrayOf(Color.parseColor("#0B0D12"), Color.parseColor("#000000"))
            )
            setPadding(dp(28), dp(72), dp(28), dp(52))
        }

        // Top subtle cobalt pulse indicator + label
        val pulseBox = FrameLayout(this).apply {
            layoutParams = LinearLayout.LayoutParams(dp(52), dp(52)).apply {
                bottomMargin = dp(14)
            }
        }
        val haloView = View(this).apply {
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.parseColor("#330A66FF"))
            }
            layoutParams = FrameLayout.LayoutParams(dp(52), dp(52), Gravity.CENTER)
        }
        val coreDot = View(this).apply {
            background = GradientDrawable().apply {
                shape = GradientDrawable.OVAL
                setColor(Color.parseColor("#0A66FF"))
            }
            layoutParams = FrameLayout.LayoutParams(dp(18), dp(18), Gravity.CENTER)
        }
        pulseBox.addView(haloView)
        pulseBox.addView(coreDot)
        startPulseAnimation(haloView)

        val badgeLabel = TextView(this).apply {
            text = "闹钟"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 13f)
            setTextColor(Color.parseColor("#8E95A6"))
            letterSpacing = 0.12f
            gravity = Gravity.CENTER
        }

        val topSpacer = View(this).apply {
            layoutParams = LinearLayout.LayoutParams(0, 0, 1f)
        }

        // Large tabular live clock
        val clockView = TextClock(this).apply {
            format24Hour = "HH:mm"
            format12Hour = "HH:mm"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 74f)
            setTextColor(Color.WHITE)
            typeface = Typeface.create("sans-serif-thin", Typeface.NORMAL)
            fontFeatureSettings = "tnum"
            gravity = Gravity.CENTER
        }

        val titleView = TextView(this).apply {
            text = alarmTitle
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 24f)
            setTextColor(Color.WHITE)
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            gravity = Gravity.CENTER
            setPadding(0, dp(16), 0, 0)
        }

        val bodyView = TextView(this).apply {
            text = alarmBody
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 15f)
            setTextColor(Color.parseColor("#98989D"))
            gravity = Gravity.CENTER
            setPadding(0, dp(10), 0, 0)
        }

        val bottomSpacer = View(this).apply {
            layoutParams = LinearLayout.LayoutParams(0, 0, 1.3f)
        }

        // Secondary frosted dark-gray capsule: Snooze
        val snoozeBtn = TextView(this).apply {
            text = "贪睡 $snoozeMins 分钟"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 16f)
            setTextColor(Color.parseColor("#E5E7EB"))
            typeface = Typeface.create("sans-serif-medium", Typeface.NORMAL)
            gravity = Gravity.CENTER
            isClickable = true
            isFocusable = true
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dp(28).toFloat()
                setColor(Color.parseColor("#24262E"))
                setStroke(dp(1), Color.parseColor("#3A3D4A"))
            }
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                dp(52)
            ).apply {
                bottomMargin = dp(14)
            }
            setOnClickListener { triggerSnooze() }
        }

        // Primary high-contrast cobalt capsule: Dismiss
        val dismissBtn = TextView(this).apply {
            text = "关闭"
            setTextSize(TypedValue.COMPLEX_UNIT_SP, 17f)
            setTextColor(Color.WHITE)
            typeface = Typeface.create("sans-serif-medium", Typeface.BOLD)
            gravity = Gravity.CENTER
            isClickable = true
            isFocusable = true
            background = GradientDrawable().apply {
                shape = GradientDrawable.RECTANGLE
                cornerRadius = dp(28).toFloat()
                setColor(Color.parseColor("#0A66FF"))
            }
            layoutParams = LinearLayout.LayoutParams(
                LinearLayout.LayoutParams.MATCH_PARENT,
                dp(56)
            )
            setOnClickListener { triggerDismiss() }
        }

        root.addView(pulseBox)
        root.addView(badgeLabel)
        root.addView(topSpacer)
        root.addView(clockView)
        root.addView(titleView)
        if (alarmBody.isNotEmpty()) root.addView(bodyView)
        root.addView(bottomSpacer)
        root.addView(snoozeBtn)
        root.addView(dismissBtn)
        setContentView(root)

        ContextCompat.registerReceiver(
            this,
            ringStateReceiver,
            IntentFilter(AlarmRingService.ACTION_RING_STATE_CHANGED),
            ContextCompat.RECEIVER_NOT_EXPORTED
        )
    }

    private fun startPulseAnimation(target: View) {
        val sx = ObjectAnimator.ofFloat(target, View.SCALE_X, 0.72f, 1.32f).apply {
            repeatCount = ValueAnimator.INFINITE
            repeatMode = ValueAnimator.REVERSE
        }
        val sy = ObjectAnimator.ofFloat(target, View.SCALE_Y, 0.72f, 1.32f).apply {
            repeatCount = ValueAnimator.INFINITE
            repeatMode = ValueAnimator.REVERSE
        }
        val alpha = ObjectAnimator.ofFloat(target, View.ALPHA, 0.85f, 0.2f).apply {
            repeatCount = ValueAnimator.INFINITE
            repeatMode = ValueAnimator.REVERSE
        }
        pulseAnimator = AnimatorSet().apply {
            duration = 1350L
            interpolator = AccelerateDecelerateInterpolator()
            playTogether(sx, sy, alpha)
            start()
        }
    }

    private fun triggerSnooze() {
        AlarmRingService.performAction(
            applicationContext,
            AlarmRingService.ACTION_SNOOZE,
            scheduleId,
            alarmTitle,
            alarmBody,
            snoozeMins,
            alarmVibrate
        )
        finish()
    }

    private fun triggerDismiss() {
        AlarmRingService.performAction(
            applicationContext,
            AlarmRingService.ACTION_STOP,
            scheduleId,
            alarmTitle,
            alarmBody,
            snoozeMins,
            alarmVibrate
        )
        finish()
    }

    override fun onKeyDown(keyCode: Int, event: KeyEvent?): Boolean {
        if (keyCode == KeyEvent.KEYCODE_VOLUME_UP || keyCode == KeyEvent.KEYCODE_VOLUME_DOWN) {
            triggerSnooze()
            return true
        }
        if (keyCode == KeyEvent.KEYCODE_BACK) {
            // Prevent accidental back press from dismissing an active alarm.
            return true
        }
        return super.onKeyDown(keyCode, event)
    }

    @Deprecated("Deprecated in Java")
    override fun onBackPressed() {
        // Intentionally ignored so back gesture cannot silence an active alarm.
    }

    override fun onDestroy() {
        pulseAnimator?.cancel()
        pulseAnimator = null
        try {
            unregisterReceiver(ringStateReceiver)
        } catch (_: Throwable) {
        }
        super.onDestroy()
    }
}
