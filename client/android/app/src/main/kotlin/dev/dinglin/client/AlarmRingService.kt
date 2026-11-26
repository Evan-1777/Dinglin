package dev.dinglin.client

import android.app.PendingIntent
import android.app.Service
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.MediaPlayer
import android.media.RingtoneManager
import android.os.Build
import android.os.IBinder
import android.os.VibrationEffect
import android.os.Vibrator
import android.os.VibratorManager
import androidx.core.app.NotificationCompat
import org.json.JSONObject
import kotlin.concurrent.thread

class AlarmRingService : Service() {
    companion object {
        const val ACTION_STOP = "dev.dinglin.ACTION_STOP_RING"
        const val ACTION_SNOOZE = "dev.dinglin.ACTION_SNOOZE_RING"
        private const val NOTIF_ID = 9001
    }

    private var player: MediaPlayer? = null
    private var vibrator: Vibrator? = null

    override fun onBind(intent: Intent?): IBinder? = null

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val action = intent?.action
        val scheduleId = intent?.getStringExtra("schedule_id") ?: ""
        val snoozeMins = intent?.getIntExtra("snooze_minutes", 10) ?: 10

        if (action == ACTION_STOP || action == ACTION_SNOOZE) {
            stopAudioAndVibration()
            if (scheduleId.isNotEmpty()) {
                val baseUrl = ScheduleStore.serverUrl(this)
                val token = ScheduleStore.authToken(this)
                if (baseUrl.isNotEmpty() && token.isNotEmpty()) {
                    thread(name = "dinglin-alarm-action") {
                        if (action == ACTION_SNOOZE) {
                            AlarmTriggerReceiver.postJson(
                                "$baseUrl/api/v1/schedules/$scheduleId/snooze",
                                token,
                                JSONObject().put("minutes", snoozeMins).toString()
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
            stopForeground(STOP_FOREGROUND_REMOVE)
            stopSelf()
            return START_NOT_STICKY
        }

        val title = intent?.getStringExtra("title") ?: "Dinglin 闹钟"
        val body = intent?.getStringExtra("body") ?: ""
        val vibrate = intent?.getBooleanExtra("vibrate", true) ?: true

        NotificationChannels.ensureCreated(this)

        val fullScreenIntent = Intent(this, AlarmFullScreenActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            putExtra("schedule_id", scheduleId)
            putExtra("title", title)
            putExtra("body", body)
            putExtra("snooze_minutes", snoozeMins)
        }
        val fullScreenPi = PendingIntent.getActivity(
            this,
            100,
            fullScreenIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val snoozePi = PendingIntent.getService(
            this,
            101,
            Intent(this, AlarmRingService::class.java).apply {
                this.action = ACTION_SNOOZE
                putExtra("schedule_id", scheduleId)
                putExtra("snooze_minutes", snoozeMins)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val dismissPi = PendingIntent.getService(
            this,
            102,
            Intent(this, AlarmRingService::class.java).apply {
                this.action = ACTION_STOP
                putExtra("schedule_id", scheduleId)
            },
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )

        val notification = NotificationCompat.Builder(this, NotificationChannels.CHANNEL_CRITICAL)
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle(title)
            .setContentText(body.ifEmpty { "强提醒响铃中" })
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setOngoing(true)
            .setFullScreenIntent(fullScreenPi, true)
            .addAction(0, "贪睡", snoozePi)
            .addAction(0, "关闭", dismissPi)
            .build()

        startForeground(NOTIF_ID, notification)
        startAudioAndVibration(vibrate)
        return START_NOT_STICKY
    }

    private fun startAudioAndVibration(vibrate: Boolean) {
        stopAudioAndVibration()
        try {
            val uri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
                ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_RINGTONE)
            player = MediaPlayer().apply {
                setAudioAttributes(
                    AudioAttributes.Builder()
                        .setUsage(AudioAttributes.USAGE_ALARM)
                        .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                        .build()
                )
                setDataSource(applicationContext, uri)
                isLooping = true
                prepare()
                start()
            }
        } catch (_: Exception) {
        }

        if (vibrate) {
            vibrator = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                val vm = getSystemService(Context.VIBRATOR_MANAGER_SERVICE) as VibratorManager
                vm.defaultVibrator
            } else {
                @Suppress("DEPRECATION")
                getSystemService(Context.VIBRATOR_SERVICE) as Vibrator
            }
            val pattern = longArrayOf(0, 600, 400)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
                vibrator?.vibrate(VibrationEffect.createWaveform(pattern, 0))
            } else {
                @Suppress("DEPRECATION")
                vibrator?.vibrate(pattern, 0)
            }
        }
    }

    private fun stopAudioAndVibration() {
        try {
            player?.stop()
            player?.release()
        } catch (_: Exception) {
        }
        player = null
        try {
            vibrator?.cancel()
        } catch (_: Exception) {
        }
    }

    override fun onDestroy() {
        stopAudioAndVibration()
        super.onDestroy()
    }
}
