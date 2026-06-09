package com.clingsync.android

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [28])
class RecentTargetsTest {
    private lateinit var context: Context

    @Before
    fun setup() {
        context = ApplicationProvider.getApplicationContext()
        context.getSharedPreferences("recent_share_targets", Context.MODE_PRIVATE).edit().clear().commit()
    }

    @Test
    fun recordsMostRecentFirstDedupedAndCapped() {
        repeat(12) { RecentTargets.record(context, "dir$it") }

        val list = RecentTargets.load(context)
        assertEquals(RecentTargets.MAX, list.size)
        assertEquals("dir11", list.first())

        RecentTargets.record(context, "dir5")
        val moved = RecentTargets.load(context)
        assertEquals("dir5", moved.first())
        assertEquals(1, moved.count { it == "dir5" })
        assertEquals(RecentTargets.MAX, moved.size)
    }

    @Test
    fun recordTrimsWhitespace() {
        RecentTargets.record(context, "  photos/2024  ")
        assertEquals(listOf("photos/2024"), RecentTargets.load(context))
    }

    @Test
    fun recordNormalizesSurroundingSlashesSoEquivalentPathsCollapse() {
        RecentTargets.record(context, "/photos/2024/")
        RecentTargets.record(context, "photos/2024")
        assertEquals(listOf("photos/2024"), RecentTargets.load(context))
    }

    @Test
    fun optionsPutRecentFirstThenSettingsPrefixWithLastUsedDefault() {
        val options = ShareTargetOptions.from(settingsPrefix = "backup", recent = listOf("photos", "docs"))
        assertEquals(listOf("photos", "docs", "backup"), options.options)
        assertEquals("photos", options.default)
    }

    @Test
    fun optionsWithoutRecentDefaultToSettingsPrefix() {
        val options = ShareTargetOptions.from(settingsPrefix = "backup", recent = emptyList())
        assertEquals(listOf("backup"), options.options)
        assertEquals("backup", options.default)
    }

    @Test
    fun optionsDoNotDuplicateSettingsPrefixAlreadyInRecent() {
        val options = ShareTargetOptions.from(settingsPrefix = "photos", recent = listOf("photos", "docs"))
        assertEquals(listOf("photos", "docs"), options.options)
        assertEquals("photos", options.default)
    }
}
