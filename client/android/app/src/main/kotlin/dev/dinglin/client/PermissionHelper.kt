package dev.dinglin.client

import android.Manifest
import android.app.Activity
import android.app.AlarmManager
import android.app.NotificationManager
import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.PowerManager
import android.provider.Settings
import androidx.core.app.ActivityCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat

object PermissionHelper {
    const val REQ_POST_NOTIFICATIONS = 0x4449

    // Curated 4 stable OEM auto-start entry points; every package is declared in AndroidManifest <queries>.
    private val autoStartComponents = listOf(
        ComponentName("com.miui.securitycenter", "com.miui.permcenter.autostart.AutoStartManagementActivity"),
        ComponentName("com.huawei.systemmanager", "com.huawei.systemmanager.startupmgr.ui.StartupNormalAppListActivity"),
        ComponentName("com.coloros.safecenter", "com.coloros.safecenter.permission.startup.StartupAppListActivity"),
        ComponentName("com.iqoo.secure", "com.iqoo.secure.ui.phoneoptimize.AddWhiteListActivity"),
    )

    fun hasAutoStartIntent(context: Context): Boolean {
        return resolveAutoStartIntent(context) != null
    }

    private fun resolveAutoStartIntent(context: Context): Intent? {
        val pm = context.packageManager
        for (component in autoStartComponents) {
            val intent = Intent().setComponent(component)
            val resolved = try {
                pm.resolveActivity(intent, PackageManager.MATCH_DEFAULT_ONLY)
            } catch (_: Throwable) {
                null
            }
            if (resolved != null) return intent
        }
        return null
    }

    fun getStatus(context: Context): Map<String, Boolean> {
        val notifications = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            ContextCompat.checkSelfPermission(context, Manifest.permission.POST_NOTIFICATIONS) ==
                PackageManager.PERMISSION_GRANTED &&
                NotificationManagerCompat.from(context).areNotificationsEnabled()
        } else {
            NotificationManagerCompat.from(context).areNotificationsEnabled()
        }

        val batteryOptimization = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
            val pm = context.getSystemService(Context.POWER_SERVICE) as PowerManager
            pm.isIgnoringBatteryOptimizations(context.packageName)
        } else {
            true
        }

        val exactAlarm = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            val am = context.getSystemService(Context.ALARM_SERVICE) as AlarmManager
            am.canScheduleExactAlarms()
        } else {
            true
        }

        val fullScreenIntent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val nm = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            nm.canUseFullScreenIntent()
        } else {
            true
        }

        return mapOf(
            "notifications" to notifications,
            "battery_optimization" to batteryOptimization,
            "exact_alarm" to exactAlarm,
            "full_screen_intent" to fullScreenIntent,
        )
    }

    fun requestPermission(
        activity: Activity?,
        context: Context,
        permission: String,
        onAsyncResult: (Boolean) -> Unit,
    ): Boolean {
        val status = getStatus(context)
        if (permission != "auto_start" && status[permission] == true) {
            onAsyncResult(true)
            return true
        }

        return when (permission) {
            "notifications" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU && activity != null) {
                    ActivityCompat.requestPermissions(
                        activity,
                        arrayOf(Manifest.permission.POST_NOTIFICATIONS),
                        REQ_POST_NOTIFICATIONS
                    )
                    false // Result delivered via onRequestPermissionsResult.
                } else {
                    openNotificationSettings(context)
                    onAsyncResult(getStatus(context)["notifications"] == true)
                    true
                }
            }
            "battery_optimization" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.M) {
                    launchPackageIntent(
                        context,
                        Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
                        Settings.ACTION_IGNORE_BATTERY_OPTIMIZATION_SETTINGS
                    )
                }
                onAsyncResult(getStatus(context)["battery_optimization"] == true)
                true
            }
            "exact_alarm" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                    launchPackageIntent(
                        context,
                        Settings.ACTION_REQUEST_SCHEDULE_EXACT_ALARM,
                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS
                    )
                }
                onAsyncResult(getStatus(context)["exact_alarm"] == true)
                true
            }
            "full_screen_intent" -> {
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
                    launchPackageIntent(
                        context,
                        Settings.ACTION_MANAGE_APP_USE_FULL_SCREEN_INTENT,
                        Settings.ACTION_APPLICATION_DETAILS_SETTINGS
                    )
                }
                onAsyncResult(getStatus(context)["full_screen_intent"] == true)
                true
            }
            "auto_start" -> {
                val target = resolveAutoStartIntent(context)
                val opened = (target != null && startSafely(context, target)) ||
                    startSafely(
                        context,
                        Intent(
                            Settings.ACTION_APPLICATION_DETAILS_SETTINGS,
                            Uri.parse("package:${context.packageName}")
                        )
                    )
                onAsyncResult(opened)
                true
            }
            else -> {
                onAsyncResult(false)
                true
            }
        }
    }

    fun openNotificationSettings(context: Context) {
        val intent = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Intent(Settings.ACTION_APP_NOTIFICATION_SETTINGS).apply {
                putExtra(Settings.EXTRA_APP_PACKAGE, context.packageName)
            }
        } else {
            Intent(Settings.ACTION_APPLICATION_DETAILS_SETTINGS, Uri.parse("package:${context.packageName}"))
        }
        startSafely(context, intent)
    }

    private fun launchPackageIntent(context: Context, action: String, fallbackAction: String) {
        val pkgUri = Uri.parse("package:${context.packageName}")
        if (!startSafely(context, Intent(action, pkgUri))) {
            val fallback = if (fallbackAction == Settings.ACTION_APPLICATION_DETAILS_SETTINGS) {
                Intent(fallbackAction, pkgUri)
            } else {
                Intent(fallbackAction)
            }
            startSafely(context, fallback)
        }
    }

    private fun startSafely(context: Context, intent: Intent): Boolean {
        return try {
            intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
            context.startActivity(intent)
            true
        } catch (_: Throwable) {
            false
        }
    }
}
