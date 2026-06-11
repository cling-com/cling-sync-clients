package com.clingsync.android

import android.content.Context
import android.os.Environment
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [30])
class SettingsTest {
    private lateinit var context: Context

    @Before
    fun setup() {
        context = ApplicationProvider.getApplicationContext()
        context.getSharedPreferences("cling_sync_prefs", Context.MODE_PRIVATE).edit().clear().commit()
    }

    @Test
    fun validateHostUrlAcceptsS3Schemes() {
        assertNull(validateHostUrl("s3+http://10.0.2.2:9124"))
        assertNull(validateHostUrl("s3+https://bucket.s3.example.com"))
        // Surrounding whitespace is tolerated.
        assertNull(validateHostUrl("  s3+https://bucket.example.com  "))
    }

    @Test
    fun validateHostUrlRejectsOtherSchemes() {
        assertNotNull(validateHostUrl("https://bucket.example.com"))
        assertNotNull(validateHostUrl("http://10.0.2.2:9124"))
        assertNotNull(validateHostUrl("ftp://example.com"))
        assertNotNull(validateHostUrl(""))
    }

    @Test
    fun isValidRequiresHostAndAuthor() {
        assertFalse(AppSettings(hostUrl = "", author = "Bob").isValid())
        assertFalse(AppSettings(hostUrl = "s3+http://h", author = "").isValid())
        assertFalse(AppSettings(hostUrl = "   ", author = "Bob").isValid())
        assertTrue(AppSettings(hostUrl = "s3+http://h", author = "Bob").isValid())
    }

    @Test
    fun repositoryIdTrimsTrailingSlashesAndWhitespace() {
        assertEquals("s3+http://h/repo", AppSettings(hostUrl = "  s3+http://h/repo/  ").repositoryID())
        assertEquals("s3+http://h", AppSettings(hostUrl = "s3+http://h///").repositoryID())
    }

    @Test
    fun settingsManagerRoundTrips() {
        val manager = SettingsManager(context)
        val settings =
            AppSettings(
                hostUrl = "s3+https://bucket.example.com",
                repoPathPrefix = "/phone/",
                author = "Tester",
                sourceDirectory = "/sdcard/Pictures",
                mediaOnly = false,
            )
        manager.saveSettings(settings)

        assertEquals(settings, SettingsManager(context).getSettings())
    }

    @Test
    fun settingsManagerReturnsDefaultsWhenEmpty() {
        val defaults = SettingsManager(context).getSettings()

        assertEquals("", defaults.hostUrl)
        assertEquals("Android User", defaults.author)
        assertTrue(defaults.mediaOnly)
        assertEquals(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DCIM).absolutePath,
            defaults.sourceDirectory,
        )
    }

    @Test
    fun settingsManagerNeverPersistsPassword() {
        val manager = SettingsManager(context)
        val prefs = context.getSharedPreferences("cling_sync_prefs", Context.MODE_PRIVATE)
        prefs.edit().putString("password", "secret").commit()

        manager.saveSettings(AppSettings(hostUrl = "s3+http://h", author = "Bob"))

        assertFalse(prefs.contains("password"))
    }
}
