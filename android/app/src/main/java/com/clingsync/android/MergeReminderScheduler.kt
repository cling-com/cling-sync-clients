package com.clingsync.android

import android.content.Context
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.workDataOf
import java.util.Calendar
import java.util.concurrent.TimeUnit

// Runs MergeReminderWorker daily at REMINDER_HOUR local time. A one-time request
// the worker re-arms each day (rather than a periodic one) keeps the trigger
// anchored to the wall-clock hour and re-derived for the current time zone every
// run instead of drifting.
object MergeReminderScheduler {
    const val WORK_NAME = "merge_reminder"
    const val TEST_WORK_NAME = "merge_reminder_test"
    const val REMINDER_HOUR = 18
    const val TEST_DELAY_SECONDS = 8L

    // Arms the reminder only if none is pending. Safe to call on every app start.
    fun ensureScheduled(context: Context) = enqueue(context, ExistingWorkPolicy.KEEP)

    // Re-arms tomorrow's reminder, replacing the run that just finished.
    fun scheduleNext(context: Context) = enqueue(context, ExistingWorkPolicy.REPLACE)

    // Manual test trigger (debug only): runs the worker once in a few seconds,
    // forced onto the daily or weekly path, without touching the real schedule.
    fun scheduleTest(
        context: Context,
        weekly: Boolean,
    ) {
        val mode = if (weekly) MergeReminderWorker.MODE_WEEKLY else MergeReminderWorker.MODE_DAILY
        val request =
            OneTimeWorkRequestBuilder<MergeReminderWorker>()
                .setInitialDelay(TEST_DELAY_SECONDS, TimeUnit.SECONDS)
                .setInputData(workDataOf(MergeReminderWorker.KEY_FORCE_MODE to mode))
                .addTag(TEST_WORK_NAME)
                .build()
        WorkManager.getInstance(context).enqueueUniqueWork(TEST_WORK_NAME, ExistingWorkPolicy.REPLACE, request)
    }

    private fun enqueue(
        context: Context,
        policy: ExistingWorkPolicy,
    ) {
        val request =
            OneTimeWorkRequestBuilder<MergeReminderWorker>()
                .setInitialDelay(millisUntilNextHour(REMINDER_HOUR), TimeUnit.MILLISECONDS)
                .addTag(WORK_NAME)
                .build()
        WorkManager.getInstance(context).enqueueUniqueWork(WORK_NAME, policy, request)
    }

    // Milliseconds from `now` until the next occurrence of `hour`:00 local time.
    fun millisUntilNextHour(
        hour: Int,
        now: Calendar = Calendar.getInstance(),
    ): Long {
        val next = now.clone() as Calendar
        next.set(Calendar.HOUR_OF_DAY, hour)
        next.set(Calendar.MINUTE, 0)
        next.set(Calendar.SECOND, 0)
        next.set(Calendar.MILLISECOND, 0)
        if (!next.after(now)) {
            next.add(Calendar.DAY_OF_MONTH, 1)
        }
        return next.timeInMillis - now.timeInMillis
    }
}
