package com.clingsync.android

import android.Manifest
import android.content.Context
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isEnabled
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.compose.ui.test.performTextReplacement
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class IntegrationTest {
    private val serverUrl = System.getenv("TEST_SERVER_URL") ?: "http://10.0.2.2:9124"
    private val testPassphrase = System.getenv("TEST_PASSPHRASE") ?: "testpassphrase"
    private val repoPathPrefix = System.getenv("TEST_DESTINATION_PATH") ?: "/phone/camera/"

    @get:Rule(order = 1)
    val permissionRule: GrantPermissionRule =
        GrantPermissionRule.grant(
            Manifest.permission.READ_MEDIA_IMAGES,
            Manifest.permission.READ_MEDIA_VIDEO,
            Manifest.permission.READ_EXTERNAL_STORAGE,
            Manifest.permission.WRITE_EXTERNAL_STORAGE,
        )

    @get:Rule(order = 2)
    val composeTestRule = createAndroidComposeRule<MainActivity>()

    @Before
    fun setup() {
        // Clear SharedPreferences to ensure settings dialog appears.
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val prefs = context.getSharedPreferences("cling_sync_prefs", Context.MODE_PRIVATE)
        prefs.edit().clear().commit()
        // Test files are pushed to /sdcard/DCIM/Camera/ via adb in the Go test harness.
    }

    @After
    fun teardown() {
        // file1.delete()
        // file2.delete()
        // file3.delete()
    }

    @OptIn(ExperimentalTestApi::class)
    @Test
    fun testBackupFiles() {
        // Wait for activity to load and settings dialog to appear.
        composeTestRule.waitForIdle()

        // Fill in settings and save.
        composeTestRule.waitUntilExactlyOneExists(hasText("Host URL"), 5000)
        composeTestRule.onNodeWithText("Host URL").performClick()
        composeTestRule.onNodeWithText("Host URL").performTextInput(serverUrl)

        composeTestRule.onNodeWithText("Password").performClick()
        composeTestRule.onNodeWithText("Password").performTextInput(testPassphrase)

        composeTestRule.onNodeWithText("Destination Path (optional)").performClick()
        composeTestRule.onNodeWithText("Destination Path (optional)").performTextInput(repoPathPrefix)

        composeTestRule.onNodeWithText("Author").performClick()
        composeTestRule.onNodeWithText("Author").performTextReplacement("Testinger")

        composeTestRule.onNodeWithText("Save").performClick()
        composeTestRule.waitForIdle()

        // Wait for file cards to be displayed.
        composeTestRule.waitUntilExactlyOneExists(hasText("blue_sky.jpg"), 5000)
        composeTestRule.waitUntilExactlyOneExists(hasText("red_earth.jpg"), 5000)

        // Select files.
        composeTestRule.onNodeWithText("blue_sky.jpg", substring = true).performClick()
        composeTestRule.onNodeWithText("red_earth.jpg", substring = true).performClick()

        // Upload.
        composeTestRule.waitUntilExactlyOneExists(hasTestTag("upload_button").and(isEnabled()))
        composeTestRule.onNodeWithText("Upload Selected").performClick()
        composeTestRule.waitForIdle()

        // Wait for both files to show "Synced" status
        composeTestRule.waitUntilNodeCount(hasContentDescription("Synced"), 2, 10000)
    }
}
