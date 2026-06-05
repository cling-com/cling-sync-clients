package com.clingsync.android

import org.junit.Assert.assertEquals
import org.junit.Test
import java.util.Calendar
import java.util.TimeZone
import java.util.concurrent.TimeUnit

class MergeReminderSchedulerTest {
    private fun at(
        hour: Int,
        minute: Int,
    ): Calendar =
        Calendar.getInstance(TimeZone.getTimeZone("UTC")).apply {
            set(2026, Calendar.JUNE, 4, hour, minute, 0)
            set(Calendar.MILLISECOND, 0)
        }

    @Test
    fun beforeTargetHourSchedulesSameDay() {
        assertEquals(TimeUnit.HOURS.toMillis(8), MergeReminderScheduler.millisUntilNextHour(18, at(10, 0)))
    }

    @Test
    fun partialHourBeforeTargetIsAccountedFor() {
        assertEquals(TimeUnit.MINUTES.toMillis(30), MergeReminderScheduler.millisUntilNextHour(18, at(17, 30)))
    }

    @Test
    fun afterTargetHourSchedulesNextDay() {
        assertEquals(TimeUnit.HOURS.toMillis(23), MergeReminderScheduler.millisUntilNextHour(18, at(19, 0)))
    }

    @Test
    fun exactlyAtTargetHourSchedulesNextDay() {
        assertEquals(TimeUnit.DAYS.toMillis(1), MergeReminderScheduler.millisUntilNextHour(18, at(18, 0)))
    }
}
