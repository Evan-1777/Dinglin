package dev.dinglin.client

import android.app.NotificationManager
import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.pm.ServiceInfo
import android.media.AudioAttributes
import android.media.AudioFocusRequest
import android.media.AudioManager
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.media.ToneGenerator
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.PowerManager
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import androidx.core.app.NotificationCompat
import androidx.core.app.ServiceCompat
import androidx.core.content.ContextCompat
import org.json.JSONObject
import kotlin.concurrent.thread

/**
 * Dedicated continuous alarm ringing foreground service.
 * Strictly scoped to kind == "alarm" schedules (critical notifications use CHANNEL_CRITICAL).
 */
class AlarmRingService : Service() {
    companion object {
        const val ACTION_STOP = "dev.dinglin.ACTION_STOP_RING"
        const val ACTION_SNOOZE = "dev.dinglin.ACTION_SNOOZE_RING"
        const val ACTION_RING_STATE_CHANGED = "dev.dinglin.ACTION_RING_STATE_CHANGED"
        const val EXTRA_RINGING = "ringing"
        const val EXTRA_SCHEDULE_ID = "schedule_id"
        const val NOTIF_ID = 9001
        private const val DEFAULT_MAX_RING_SEC = 600

        @Volatile
        var isRinging: Boolean = false
            private set

        @Volatile
        var currentScheduleId: String? = null
            private set

        fun startSafely(
            context: Context,
            scheduleId: String,
            title: String,
            body: String,
            snoozeMinutes: Int = 10,
            vibrate: Boolean = true,
            maxRingSec: Int = DEFAULT_MAX_RING_SEC,
        ) {
            val svc = Intent(context, AlarmRingService::class.java).apply {
                putExtra("schedule_id", scheduleId)
                putExtra("title", title)
                putExtra("body", body)
                putExtra("snooze_minutes", snoozeMinutes)
                putExtra("vibrate", vibrate)
                putExtra("max_ring_sec", maxRingSec)
            }
            try {
                ContextCompat.startForegroundService(context, svc)
            } catch (_: Throwable) {
                isRinging = true
                currentScheduleId = scheduleId
                NotificationChannels.showAlarmFallbackNotification(
                    context,
                    scheduleId,
                    title,
                    body,
                    snoozeMinutes,
                    vibrate
                )
                NativeBridgePlugin.emitEvent(
                    mapOf("type" to "alarm_ringing", "schedule_id" to scheduleId)
                )
            }
        }

        /**
         * Stops ringing only when scheduleId is null/empty or matches the active ringing alarm.
         */
        fun stopIfMatching(context: Context, scheduleId: String?) {
            val active = currentScheduleId
            if (!scheduleId.isNullOrEmpty() && !active.isNullOrEmpty() && active != scheduleId) {
                return
            }
            val wasRinging = isRinging
            isRinging = false
            currentScheduleId = null
            try {
                context.stopService(Intent(context, AlarmRingService::class.java))
            } catch (_: Throwable) {
            }
            cancelAlarmNotification(context)
            if (wasRinging || !scheduleId.isNullOrEmpty()) {
                broadcastRingState(context, false, scheduleId ?: active ?: "")
                NativeBridgePlugin.emitEvent(
                    mapOf(
                        "type" to "alarm_ringing_stopped",
                        "schedule_id" to (scheduleId ?: active ?: ""),
                    )
                )
            }
        }

        /**
         * Unified alarm dismiss/snooze handler shared by notification actions, full-screen UI,
         * and safety auto-snooze timeout. Never requires cold-starting a background service.
         */
        fun performAction(
            context: Context,
            action: String,
            scheduleId: String,
            title: String,
            body: String,
            snoozeMinutes: Int,
            vibrate: Boolean,
        ) {
            val mins = snoozeMinutes.coerceAtLeast(1)
            if (action == ACTION_SNOOZE && scheduleId.isNotEmpty()) {
                ExactAlarmScheduler.scheduleSnooze(context, scheduleId, title, body, mins, vibrate)
            }
            isRinging = false
            currentScheduleId = null
            try {
                context.stopService(Intent(context, AlarmRingService::class.java))
            } catch (_: Throwable) {
            }
            cancelAlarmNotification(context)
            broadcastRingState(context, false, scheduleId)
            NativeBridgePlugin.emitEvent(
                mapOf(
                    "type" to "alarm_ringing_stopped",
                    "schedule_id" to scheduleId,
                    "action" to action,
                )
            )
            if (scheduleId.isNotEmpty()) {
                val baseUrl = ScheduleStore.serverUrl(context)
                val token = ScheduleStore.authToken(context)
                if (baseUrl.isNotEmpty() && token.isNotEmpty()) {
                    thread(name = "dinglin-alarm-action") {
                        if (action == ACTION_SNOOZE) {
                            AlarmTriggerReceiver.postJson(
                                "$baseUrl/api/v1/schedules/$scheduleId/snooze",
                                token,
                                JSONObject().put("minutes", mins).toString()
                            )
                        } else {
                            AlarmTriggerReceiver.postJson(
                                "$baseUrl/api/v1/schedules/$scheduleId/dismiss",
                                token,
                                "{}"
                            )
                        }
                    }
                }
            }
        }

        fun buildActionBroadcastPendingIntent(
            context: Context,
            requestCode: Int,
            action: String,
            scheduleId: String,
            title: String,
            body: String,
            snoozeMinutes: Int,
            vibrate: Boolean,
        ): PendingIntent {
            val intent = Intent(context, AlarmTriggerReceiver::class.java).apply {
                this.action = action
                putExtra("schedule_id", scheduleId)
                putExtra("title", title)
                putExtra("body", body)
                putExtra("snooze_minutes", snoozeMinutes)
                putExtra("vibrate", vibrate)
            }
            return PendingIntent.getBroadcast(
                context,
                requestCode,
                intent,
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
        }

        private fun cancelAlarmNotification(context: Context) {
            try {
                val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
                nm.cancel(NOTIF_ID)
            } catch (_: Throwable) {
            }
        }

        private fun broadcastRingState(context: Context, ringing: Boolean, scheduleId: String) {
            val intent = Intent(ACTION_RING_STATE_CHANGED).apply {
                setPackage(context.packageName)
                putExtra(EXTRA_RINGING, ringing)
                putExtra(EXTRA_SCHEDULE_ID, scheduleId)
            }
            context.sendBroadcast(intent)
        }
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var player: MediaPlayer? = null
    private var toneGenerator: ToneGenerator? = null
    private var toneRunnable: Runnable? = null
    private var timeoutRunnable: Runnable? = null
    private var vibrator: Vibrator? = null
    private var wakeLock: PowerManager.WakeLock? = null
    private var audioFocusRequest: AudioFocusRequest? = null

    private var activeScheduleId: String = ""
    private var activeTitle: String = "Dinglin 闹钟"
    private var activeBody: String = ""
    private var activeSnoozeMins: Int = 10
    private var activeVibrate: Boolean = true

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        val scheduleId = intent?.getStringExtra("schedule_id") ?: ""
        val snoozeMins = (intent?.getIntExtra("snooze_minutes", 10) ?: 10).coerceAtLeast(1)
        val title = intent?.getStringExtra("title") ?: activeTitle
        val body = intent?.getStringExtra("body") ?: activeBody
        val vibrate = intent?.getBooleanExtra("vibrate", activeVibrate) ?: activeVibrate

        if (action == ACTION_STOP || action == ACTION_SNOOZE) {
            if (scheduleId.isNotEmpty() && activeScheduleId.isNotEmpty() && scheduleId != activeScheduleId) {
                return START_NOT_STICKY
            }
            performAction(
                applicationContext,
                action,
                scheduleId.ifEmpty { activeScheduleId },
                title,
                body,
                snoozeMins,
                vibrate
            )
            ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }

        activeScheduleId = scheduleId
        activeTitle = title.ifEmpty { "Dinglin 闹钟" }
        activeBody = body
        activeSnoozeMins = snoozeMins
        activeVibrate = vibrate
        val maxRingSec = (intent?.getIntExtra("max_ring_sec", DEFAULT_MAX_RING_SEC) ?: DEFAULT_MAX_RING_SEC)
            .coerceIn(30, 1800)

        isRinging = true
        currentScheduleId = activeScheduleId

        NotificationChannels.ensureCreated(this)

        val fullScreenIntent = Intent(this, AlarmFullScreenActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            putExtra("schedule_id", activeScheduleId)
            putExtra("title", activeTitle)
            putExtra("body", activeBody)
            putExtra("snooze_minutes", activeSnoozeMins)
            putExtra("vibrate", activeVibrate)
        }
        val fullScreenPi = PendingIntent.getActivity(
            this,
            100,
            fullScreenIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val snoozePi = buildActionBroadcastPendingIntent(
            this,
            101,
            ACTION_SNOOZE,
            activeScheduleId,
            activeTitle,
            activeBody,
            activeSnoozeMins,
            activeVibrate
        )

        val dismissPi = buildActionBroadcastPendingIntent(
            this,
            102,
            ACTION_STOP,
            activeScheduleId,
            activeTitle,
            activeBody,
            activeSnoozeMins,
            activeVibrate
        )

        val notification = NotificationCompat.Builder(this, NotificationChannels.CHANNEL_ALARM_RINGING)
            .setSmallIcon(R.drawable.ic_stat_dinglin)
            .setContentTitle(activeTitle)
            .setContentText(activeBody.ifEmpty { "闹钟响铃中" })
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setContentIntent(fullScreenPi)
            .setFullScreenIntent(fullScreenPi, true)
            .addAction(0, "贪睡", snoozePi)
            .addAction(0, "关闭", dismissPi)
            .build()

        val fgsType = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            ServiceInfo.FOREGROUND_SERVICE_TYPE_MEDIA_PLAYBACK
        } else {
            0
        }
        ServiceCompat.startForeground(this, NOTIF_ID, notification, fgsType)

        acquireWakeLock(maxRingSec * 1000L + 15_000L)
        startAudioAndVibration(activeVibrate)
        scheduleSafetyTimeout(maxRingSec)

        broadcastRingState(this, true, activeScheduleId)
        NativeBridgePlugin.emitEvent(
            mapOf("type" to "alarm_ringing", "schedule_id" to activeScheduleId)
        )
        return START_NOT_STICKY
    }

    private fun acquireWakeLock(timeoutMs: Long) {
        releaseWakeLock()
        try {
            val pm = getSystemService(Context.POWER_SERVICE) as PowerManager
            wakeLock = pm.newWakeLock(PowerManager.PARTIAL_WAKE_LOCK, "dinglin:alarm-ring").apply {
                setReferenceCounted(false)
                acquire(timeoutMs)
            }
        } catch (_: Throwable) {
        }
    }

    private fun releaseWakeLock() {
        try {
            if (wakeLock?.isHeld == true) {
                wakeLock?.release()
            }
        } catch (_: Throwable) {
        }
        wakeLock = null
    }

    private fun requestAlarmAudioFocus() {
        try {
            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                val attrs = AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
                val req = AudioFocusRequest.Builder(AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE)
                    .setAudioAttributes(attrs)
                    .setWillPauseWhenDucked(false)
                    .build()
                audioFocusRequest = req
                am.requestAudioFocus(req)
            } else {
                @Suppress("DEPRECATION")
                am.requestAudioFocus(
                    null,
                    AudioManager.STREAM_ALARM,
                    AudioManager.AUDIOFOCUS_GAIN_TRANSIENT_EXCLUSIVE
                )
            }
        } catch (_: Throwable) {
        }
    }

    private fun abandonAlarmAudioFocus() {
        try {
            val am = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                audioFocusRequest?.let { am.abandonAudioFocusRequest(it) }
            } else {
                @Suppress("DEPRECATION")
                am.abandonAudioFocus(null)
            }
        } catch (_: Throwable) {
        }
        audioFocusRequest = null
    }

    private fun startAudioAndVibration(vibrate: Boolean) {
        stopAudioAndVibration()
        requestAlarmAudioFocus()

        val candidates = listOfNotNull(
            RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM),
            RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE),
            RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION),
        ).distinct()

        var started = false
        for (uri in candidates) {
            try {
                val mp = MediaPlayer().apply {
                    setAudioAttributes(
                        AudioAttributes.Builder()
                            .setUsage(AudioAttributes.USAGE_ALARM)
                            .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                            .build()
                    )
                    setDataSource(applicationContext, uri)
                    isLooping = true
                    setOnErrorListener { _, _, _ ->
                        startToneFallback()
                        true
                    }
                    prepare()
                    start()
                }
                player = mp
                started = true
                break
            } catch (_: Throwable) {
            }
        }

        if (!started) {
            startToneFallback()
        }

        if (vibrate) {
            try {
                vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    val vm = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager
                    vm.defaultVibrator
                } else {
                    @Suppress("DEPRECATION")
                    getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
                }
                val pattern = longArrayOf(0, 650, 450)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                    vibrator?.vibrate(VibrationEffect.createWaveform(pattern, 0))
                } else {
                    @Suppress("DEPRECATION")
                    vibrator?.vibrate(pattern, 0)
                }
            } catch (_: Throwable) {
            }
        }
    }

    private fun startToneFallback() {
        stopToneFallback()
        try {
            val tg = ToneGenerator(AudioManager.STREAM_ALARM, 90)
            toneGenerator = tg
            val r = object : Runnable {
                override fun run() {
                    if (!isRinging) return
                    try {
                        tg.startTone(ToneGenerator.TONE_CDMA_ALERT_CALL_GUARD, 600)
                    } catch (_: Throwable) {
                    }
                    mainHandler.postDelayed(this, 1400L)
                }
            }
            toneRunnable = r
            mainHandler.post(r)
        } catch (_: Throwable) {
        }
    }

    private fun stopToneFallback() {
        toneRunnable?.let { mainHandler.removeCallbacks(it) }
        toneRunnable = null
        try {
            toneGenerator?.stopTone()
            toneGenerator?.release()
        } catch (_: Throwable) {
        }
        toneGenerator = null
    }

    private fun scheduleSafetyTimeout(maxRingSec: Int) {
        timeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        val r = Runnable {
            performAction(
                applicationContext,
                ACTION_SNOOZE,
                activeScheduleId,
                activeTitle,
                activeBody,
                activeSnoozeMins,
                activeVibrate
            )
            ServiceCompat.stopForeground(this, ServiceCompat.STOP_FOREGROUND_REMOVE)
            stopSelf()
        }
        timeoutRunnable = r
        mainHandler.postDelayed(r, maxRingSec * 1000L)
    }

    private fun stopAudioAndVibration() {
        stopToneFallback()
        try {
            player?.stop()
            player?.release()
        } catch (_: Throwable) {
        }
        player = null
        try {
            vibrator?.cancel()
        } catch (_: Throwable) {
        }
        vibrator = null
        abandonAlarmAudioFocus()
    }

    override fun onDestroy() {
        timeoutRunnable?.let { mainHandler.removeCallbacks(it) }
        timeoutRunnable = null
        stopAudioAndVibration()
        releaseWakeLock()
        if (currentScheduleId == activeScheduleId) {
            isRinging = false
            currentScheduleId = null
            broadcastRingState(this, false, activeScheduleId)
        }
        super.onDestroy()
    }
}
