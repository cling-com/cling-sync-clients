package com.clingsync.android

import android.Manifest
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.core.app.NotificationManagerCompat
import androidx.core.content.ContextCompat
import androidx.work.CoroutineWorker
import androidx.work.WorkerParameters
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.util.concurrent.TimeUnit

// Daily-at-18:00 reminder that there are files to back up. Most days it checks
// cached hashes against the repository's persisted hash index; once a week it also
// hashes changed files. It never opens the repository, so it needs no passphrase.
class MergeReminderWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {
    override suspend fun doWork(): Result {
        // A forced run is a one-off manual test; it must not re-arm or otherwise
        // disturb the real daily schedule.
        val forcedMode = inputData.getString(KEY_FORCE_MODE)
        try {
            runCheck(forcedMode)
        } catch (e: Exception) {
            Log.e("MergeReminder", "Reminder check failed", e)
        } finally {
            if (forcedMode == null) {
                MergeReminderScheduler.scheduleNext(applicationContext)
            }
        }
        return Result.success()
    }

    private suspend fun runCheck(forcedMode: String?) =
        withContext(Dispatchers.IO) {
            val settings = SettingsManager(applicationContext).getSettings()
            if (!settings.isValid()) return@withContext

            val files = getSourceFiles(getSourceDirectory(settings), settings.mediaOnly)
            if (files.isEmpty()) return@withContext

            GoBridgeProvider.initialize(applicationContext)
            val scan = MergeReminderScan(SHA256Cache.getInstance(applicationContext), GoBridgeProvider.getInstance())
            val state = MergeReminderState(applicationContext)
            val now = System.currentTimeMillis()
            val auto = forcedMode == null
            val weekly =
                when (forcedMode) {
                    MODE_WEEKLY -> true
                    MODE_DAILY -> false
                    else -> now - state.lastWeeklyScan() >= WEEKLY_INTERVAL_MS
                }

            val count =
                if (weekly) {
                    scan.countUnsyncedOrChanged(files).also { if (auto) state.setLastWeeklyScan(now) }
                } else {
                    scan.countUnsynced(files)
                }

            if (count > 0) {
                notifyBackupDue(count, weekly)
            }
        }

    private fun notifyBackupDue(
        count: Int,
        weekly: Boolean,
    ) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(applicationContext, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            return
        }
        createChannel()
        val noun = if (count == 1) "item" else "items"
        val kind = if (weekly) "new or changed" else "new"
        val notification =
            NotificationCompat.Builder(applicationContext, CHANNEL_ID)
                .setContentTitle("Back up your files")
                .setContentText("$count $kind $noun ready to back up.")
                .setSmallIcon(R.drawable.ic_notification)
                .setAutoCancel(true)
                .setContentIntent(openAppIntent())
                .setPriority(NotificationCompat.PRIORITY_DEFAULT)
                .build()
        NotificationManagerCompat.from(applicationContext).notify(NOTIFICATION_ID, notification)
    }

    private fun openAppIntent(): PendingIntent {
        val intent =
            Intent(applicationContext, MainActivity::class.java).apply {
                flags = Intent.FLAG_ACTIVITY_SINGLE_TOP or Intent.FLAG_ACTIVITY_CLEAR_TOP
            }
        return PendingIntent.getActivity(
            applicationContext,
            0,
            intent,
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
    }

    private fun createChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel =
                NotificationChannel(
                    CHANNEL_ID,
                    "Backup reminders",
                    NotificationManager.IMPORTANCE_DEFAULT,
                ).apply {
                    description = "Reminds you to back up new photos and videos"
                }
            val manager = applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            manager.createNotificationChannel(channel)
        }
    }

    companion object {
        // Input key forcing the daily or weekly path, set only by the manual test
        // controls. Absent for the real scheduled run, which auto-decides by cadence.
        const val KEY_FORCE_MODE = "force_mode"
        const val MODE_DAILY = "daily"
        const val MODE_WEEKLY = "weekly"

        private const val CHANNEL_ID = "merge_reminder_channel"
        private const val NOTIFICATION_ID = 2
        private val WEEKLY_INTERVAL_MS = TimeUnit.DAYS.toMillis(7)
    }
}
