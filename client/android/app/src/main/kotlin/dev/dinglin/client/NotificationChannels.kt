package dev.dinglin.client

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.media.AudioAttributes
import android.media.RingtoneManager
import android.os.Build
import androidx.core.app.NotificationCompat

object NotificationChannels {
    const val CHANNEL_SILENT = "dinglin_silent"
    const val CHANNEL_NORMAL = "dinglin_normal"
    const val CHANNEL_CRITICAL = "dinglin_critical"

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
            "强提醒与闹钟",
            NotificationManager.IMPORTANCE_HIGH
        ).apply {
            setBypassDnd(true)
            enableVibration(true)
            setSound(
                alarmUri,
                AudioAttributes.Builder()
                    .setUsage(AudioAttributes.USAGE_ALARM)
                    .setContentType(AudioAttributes.CONTENT_TYPE_SONIFICATION)
                    .build()
            )
        }

        nm.createNotificationChannel(silent)
        nm.createNotificationChannel(normal)
        nm.createNotificationChannel(critical)
    }

    fun channelForPriority(priority: String): String = when (priority) {
        "silent" -> CHANNEL_SILENT
        "critical" -> CHANNEL_CRITICAL
        else -> CHANNEL_NORMAL
    }

    fun showNotification(context: Context, id: String, title: String, body: String, priority: String) {
        ensureCreated(context)
        val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
        val channelId = channelForPriority(priority)
        val notif = NotificationCompat.Builder(context, channelId)
            .setSmallIcon(android.R.drawable.ic_lock_idle_alarm)
            .setContentTitle(title)
            .setContentText(body)
            .setAutoCancel(true)
            .setPriority(
                when (priority) {
                    "critical" -> NotificationCompat.PRIORITY_MAX
                    "silent" -> NotificationCompat.PRIORITY_LOW
                    else -> NotificationCompat.PRIORITY_DEFAULT
                }
            )
            .build()
        nm.notify(id.hashCode(), notif)
    }
}
