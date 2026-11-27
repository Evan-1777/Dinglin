package dev.dinglin.client

import android.app.AlarmManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.os.Build

object ExactAlarmScheduler {
    fun syncAll(context: Context, schedules: List<LocalSchedule>) {
        val previous = ScheduleStore.loadSchedules(context)
        val nextIds = schedules.map { it.id }.toSet()
        for (old in previous) {
            if (old.id !in nextIds) {
                cancel(context, old.id)
            }
        }
        ScheduleStore.saveSchedules(context, schedules)
        val now = System.currentTimeMillis()
        for (s in schedules) {
            if (!s.enabled || s.state != "active" || s.nextFireAtMs <= now) {
                cancel(context, s.id)
            } else {
                scheduleOne(context, s)
            }
        }
    }

    fun restoreAll(context: Context) {
        val now = System.currentTimeMillis()
        for (s in ScheduleStore.loadSchedules(context)) {
            if (s.enabled && s.state == "active" && s.nextFireAtMs > now) {
                scheduleOne(context, s)
            }
        }
    }

    /**
     * Schedules an immediate local snooze alarm and persists the updated active nextFireAtMs
     * into ScheduleStore so offline reboots or syncAll calls do not cancel the snooze.
     */
    fun scheduleSnooze(
        context: Context,
        scheduleId: String,
        title: String,
        body: String,
        snoozeMinutes: Int,
        vibrate: Boolean,
    ) {
        val mins = snoozeMinutes.coerceAtLeast(1)
        val triggerAtMs = System.currentTimeMillis() + mins * 60_000L
        val existingList = ScheduleStore.loadSchedules(context).toMutableList()
        val idx = existingList.indexOfFirst { it.id == scheduleId }
        val snoozed = if (idx >= 0) {
            val prev = existingList[idx]
            prev.copy(
                kind = "alarm",
                title = title.ifEmpty { prev.title },
                body = body,
                priority = "critical",
                nextFireAtMs = triggerAtMs,
                snoozeMinutes = mins,
                vibrate = vibrate,
                enabled = true,
                state = "active",
            ).also { existingList[idx] = it }
        } else {
            LocalSchedule(
                id = scheduleId,
                kind = "alarm",
                title = title.ifEmpty { "Dinglin 闹钟" },
                body = body,
                priority = "critical",
                nextFireAtMs = triggerAtMs,
                snoozeMinutes = mins,
                vibrate = vibrate,
                enabled = true,
                state = "active",
            ).also { existingList.add(it) }
        }
        ScheduleStore.saveSchedules(context, existingList)
        scheduleOne(context, snoozed)
    }

    fun scheduleOne(context: Context, s: LocalSchedule) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val pi = buildPendingIntent(context, s)
        val canExact = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            am.canScheduleExactAlarms()
        } else {
            true
        }

        if (s.kind == "alarm") {
            val showIntent = PendingIntent.getActivity(
                context,
                s.id.hashCode(),
                Intent(context, MainActivity::class.java),
                PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
            )
            try {
                am.setAlarmClock(AlarmManager.AlarmClockInfo(s.nextFireAtMs, showIntent), pi)
                return
            } catch (_: SecurityException) {
                // Fall through to inexact wakeup if alarm permission was revoked.
            }
        }

        try {
            if (canExact) {
                am.setExactAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, s.nextFireAtMs, pi)
            } else {
                am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, s.nextFireAtMs, pi)
            }
        } catch (_: SecurityException) {
            am.setAndAllowWhileIdle(AlarmManager.RTC_WAKEUP, s.nextFireAtMs, pi)
        }
    }

    fun cancel(context: Context, scheduleId: String) {
        val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
        val intent = Intent(context, AlarmTriggerReceiver::class.java).apply {
            action = "dev.dinglin.ALARM_TRIGGER"
            putExtra("schedule_id", scheduleId)
        }
        val pi = PendingIntent.getBroadcast(
            context,
            scheduleId.hashCode(),
            intent,
            PendingIntent.FLAG_NO_CREATE or PendingIntent.FLAG_IMMUTABLE
        )
        if (pi != null) {
            am.cancel(pi)
            pi.cancel()
        }
    }

    private fun buildPendingIntent(context: Context, s: LocalSchedule): PendingIntent {
        val intent = Intent(context, AlarmTriggerReceiver::class.java).apply {
            action = "dev.dinglin.ALARM_TRIGGER"
            putExtra("schedule_id", s.id)
            putExtra("kind", s.kind)
            putExtra("title", s.title)
            putExtra("body", s.body)
            putExtra("priority", s.priority)
            putExtra("fire_ts", s.nextFireAtMs / 1000L)
            putExtra("snooze_minutes", s.snoozeMinutes)
            putExtra("vibrate", s.vibrate)
        }
        return PendingIntent.getBroadcast(
            context,
            s.id.hashCode(),
            intent,
            PendingIntent.FLAG_UPDATE_CURRENT or PendingIntent.FLAG_IMMUTABLE
        )
    }
}
