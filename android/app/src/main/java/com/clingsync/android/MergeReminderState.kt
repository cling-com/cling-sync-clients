package com.clingsync.android

import android.content.Context

// Remembers when the weekly full scan last ran so the daily worker can choose
// between the cheap new-files check and the full new-or-changed scan.
class MergeReminderState(context: Context) {
    private val prefs = context.getSharedPreferences("merge_reminder_prefs", Context.MODE_PRIVATE)

    fun lastWeeklyScan(): Long = prefs.getLong(KEY_LAST_WEEKLY_SCAN, 0L)

    fun setLastWeeklyScan(millis: Long) {
        prefs.edit().putLong(KEY_LAST_WEEKLY_SCAN, millis).apply()
    }

    companion object {
        private const val KEY_LAST_WEEKLY_SCAN = "last_weekly_scan"
    }
}
