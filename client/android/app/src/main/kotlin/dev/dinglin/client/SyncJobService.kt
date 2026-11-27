package dev.dinglin.client

import android.app.job.JobInfo
import android.app.job.JobParameters
import android.app.job.JobScheduler
import android.app.job.JobService
import android.content.ComponentName
import android.content.Context
import kotlin.concurrent.thread

/**
 * Low-power network-aware catch-up JobService.
 * Runs a single incremental sync as soon as network connectivity becomes available
 * after boot, app update, or an offline poll attempt.
 */
class SyncJobService : JobService() {
    @Volatile
    private var cancelled = false

    override fun onStartJob(params: JobParameters?): Boolean {
        cancelled = false
        thread(name = "dinglin-sync-job") {
            try {
                if (!cancelled) {
                    KeepAliveManager.syncOnceBackground(applicationContext)
                    KeepAliveManager.apply(applicationContext)
                }
            } finally {
                jobFinished(params, false)
            }
        }
        return true
    }

    override fun onStopJob(params: JobParameters?): Boolean {
        cancelled = true
        return true
    }

    companion object {
        private const val JOB_ID = 0x44494E01

        fun scheduleImmediateOnNetwork(context: Context) {
            try {
                val scheduler = context.getSystemService(Context.JOB_SCHEDULER_SERVICE) as JobScheduler
                val component = ComponentName(context, SyncJobService::class.java)
                val info = JobInfo.Builder(JOB_ID, component)
                    .setRequiredNetworkType(JobInfo.NETWORK_TYPE_ANY)
                    .setMinimumLatency(0L)
                    .setOverrideDeadline(6L * 60L * 60L * 1000L)
                    .build()
                scheduler.schedule(info)
            } catch (_: Throwable) {
            }
        }
    }
}
