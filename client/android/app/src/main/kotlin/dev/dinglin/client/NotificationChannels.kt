package dev.dinglin.client

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import androidx.core.app.NotificationCompat

object NotificationChannels {
    const val CHANNEL_SILENT = "dinglin_silent"
    const val CHANNEL_NORMAL = "dinglin_normal"
    const val CHANNEL_CRITICAL = "dinglin_critical"
    const val CHANNEL_ALARM_RINGING = "dinglin_alarm_ringing"
    const val CHANNEL_KEEPALIVE = "dinglin_keepalive"

    fun ensureCreated(context: Context) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

        val silent = NotificationChannel(
            CHANNEL_SILENT,
            "静默通知",
            NotificationManager.IMPORTANCE_LOW
        ).apply {
            setSound(null, null)
            enableVibration(false)
        }

        val normal = NotificationChannel(
            CHANNEL_NORMAL,
            "普通通知",
            NotificationManager.IMPORTANCE_DEFAULT
        )

        val alarmUri = RingtoneManager.getDefaultUri(RingtoneManager.TYPE_ALARM)
            ?: RingtoneManager.getDefaultUri(RingtoneManager.TYPE_NOTIFICATION)
        val critical = NotificationChannel(
            CHANNEL_CRITICAL,
            "强提醒通知",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            setBypassDnd(true)
            enableVibration(true)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
            setSound(
                alarmUri,
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            )
        }

        // Dedicated silent high-importance channel for AlarmRingService so system notification
        // sound never collides with MediaPlayer looping alarm playback.
        val alarmRinging = NotificationChannel(
            CHANNEL_ALARM_RINGING,
            "闹钟响铃",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            setSound(null, null)
            enableVibration(false)
            setBypassDnd(true)
            lockscreenVisibility = Notification.VISIBILITY_PUBLIC
        }

        val keepalive = NotificationChannel(
            CHANNEL_KEEPALIVE,
            "后台保活",
            NotificationManager.IMPORTANCE_MIN
        ).apply {
            setShowBadge(false)
            setSound(null, null)
            enableVibration(false)
        }

        nm.createNotificationChannel(silent)
        nm.createNotificationChannel(normal)
        nm.createNotificationChannel(critical)
        nm.createNotificationChannel(alarmRinging)
        nm.createNotificationChannel(keepalive)
    }

    fun channelForPriority(priority: String): String = when (priority) {
        "silent" -> CHANNEL_SILENT
        "critical" -> CHANNEL_CRITICAL
        else -> CHANNEL_NORMAL
    }

    fun showNotification(context: Context, id: String, title: String, body: String, priority: String) {
        ensureCreated(context)
        val effectivePriority = if (priority == "normal" && ScheduleStore.isWithinDnd(context)) {
            "silent"
        } else {
            priority
        }
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channelId = channelForPriority(effectivePriority)
        val launchIntent = Intent(context, MainActivity::class.java).apply {
            flags = Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP
        }
        val contentIntent = PendingIntent.getActivity(
            context,
            id.hashCode(),
            launchIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val notif = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(R.drawable.ic_stat_dinglin)
            .setContentTitle(title)
            .setContentText(body)
            .setContentIntent(contentIntent)
            .setAutoCancel(true)
            .setPriority(
                when (effectivePriority) {
                    "critical" -> NotificationCompat.PRIORITY_MAX
                    "silent" -> NotificationCompat.PRIORITY_LOW
                    else -> NotificationCompat.PRIORITY_DEFAULT
                }
            )
            .build()
        nm.notify(id.hashCode(), notif)
    }

    /**
     * Fallback high-priority full-screen alarm notification used when Android 12+ blocks
     * background foreground-service start (e.g. battery optimization not yet exempted).
     */
    fun showAlarmFallbackNotification(
        context: Context,
        scheduleId: String,
        title: String,
        body: String,
        snoozeMinutes: Int,
        vibrate: Boolean,
    ) {
        ensureCreated(context)
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val fullScreenIntent = Intent(context, AlarmFullScreenActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            putExtra("schedule_id", scheduleId)
            putExtra("title", title)
            putExtra("body", body)
            putExtra("snooze_minutes", snoozeMinutes)
            putExtra("vibrate", vibrate)
        }
        val fullScreenPi = PendingIntent.getActivity(
            context,
            200,
            fullScreenIntent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
        val snoozePi = AlarmRingService.buildActionBroadcastPendingIntent(
            context,
            201,
            AlarmRingService.ACTION_SNOOZE,
            scheduleId,
            title,
            body,
            snoozeMinutes,
            vibrate
        )
        val dismissPi = AlarmRingService.buildActionBroadcastPendingIntent(
            context,
            202,
            AlarmRingService.ACTION_STOP,
            scheduleId,
            title,
            body,
            snoozeMinutes,
            vibrate
        )
        val notif = NotificationCompat.Builder(context, CHANNEL_CRITICAL)
            .setSmallIcon(R.drawable.ic_stat_dinglin)
            .setContentTitle(title.ifEmpty { "Dinglin 闹钟" })
            .setContentText(body.ifEmpty { "闹钟响铃中" })
            .setCategory(NotificationCompat.CATEGORY_ALARM)
            .setPriority(NotificationCompat.PRIORITY_MAX)
            .setVisibility(NotificationCompat.VISIBILITY_PUBLIC)
            .setOngoing(true)
            .setContentIntent(fullScreenPi)
            .setFullScreenIntent(fullScreenPi, true)
            .addAction(0, "贪睡", snoozePi)
            .addAction(0, "关闭", dismissPi)
            .build()
        nm.notify(AlarmRingService.NOTIF_ID, notif)
    }
}
