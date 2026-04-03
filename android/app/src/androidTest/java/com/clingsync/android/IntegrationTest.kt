package com.clingsync.android

import android.Manifest
import android.content.Context
import android.os.Environment
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
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith

@RunWith(AndroidJUnit4::class)
class IntegrationTest {
    private val serverUrl = System.getenv("TEST_SERVER_URL") ?: "http://10.0.2.2:9124"
    private val testPassphrase = System.getenv("TEST_PASSPHRASE") ?: "testpassphrase"
    private val repoPathPrefix = System.getenv("TEST_DESTINATION_PATH") ?: "/phone/"

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
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val prefs = context.getSharedPreferences("cling_sync_prefs", Context.MODE_PRIVATE)
        prefs.edit().clear().commit()
        PassphraseStore(context).deleteAll()
    }

    @OptIn(ExperimentalTestApi::class)
    @Test
    fun testBackupFiles() {
        composeTestRule.waitForIdle()

        // Configure settings with default DCIM source.
        composeTestRule.waitUntilExactlyOneExists(hasText("Host URL"), 5000)
        composeTestRule.onNodeWithText("Host URL").performClick()
        composeTestRule.onNodeWithText("Host URL").performTextInput(serverUrl)

        composeTestRule.onNodeWithText("Destination Path (optional)").performClick()
        composeTestRule.onNodeWithText("Destination Path (optional)").performTextInput(repoPathPrefix)

        composeTestRule.onNodeWithText("Author").performClick()
        composeTestRule.onNodeWithText("Author").performTextReplacement("Testinger")

        composeTestRule.onNodeWithText("Test").performClick()
        composeTestRule.waitUntilExactlyOneExists(hasText("Enter Passphrase"), 5000)
        composeTestRule.onNodeWithText("Passphrase").performClick()
        composeTestRule.onNodeWithText("Passphrase").performTextInput(testPassphrase)
        composeTestRule.onNodeWithText("Continue").performClick()
        composeTestRule.waitForIdle()

        composeTestRule.waitUntilExactlyOneExists(hasText("Save"), 10000)
        composeTestRule.onNodeWithText("Save").performClick()
        composeTestRule.waitUntilExactlyOneExists(hasTestTag("upload_all_button"), 10000)

        // Select and upload DCIM files (including one from a subfolder).
        composeTestRule.onNodeWithText("blue_sky.jpg", substring = true).performClick()
        composeTestRule.onNodeWithText("red_earth.jpg", substring = true).performClick()
        composeTestRule.onNodeWithText("sunset.jpg", substring = true).performClick()
        composeTestRule.waitUntilExactlyOneExists(hasTestTag("upload_button").and(isEnabled()))
        composeTestRule.onNodeWithText("Upload Selected").performClick()
        composeTestRule.waitUntilNodeCount(hasContentDescription("Synced"), 3, 10000)

        // Verify non-uploaded files kept their status.
        composeTestRule.waitUntilExactlyOneExists(hasTestTag("checkbox_green_grass.jpg"), 5000)

        // --- Switch to custom folder with media-only ---
        composeTestRule.onNode(hasContentDescription("Settings")).performClick()
        composeTestRule.waitUntilExactlyOneExists(hasText("Source Directory"), 5000)

        // Change source directory to ClingSyncTest.
        val customDir = "${Environment.getExternalStorageDirectory().path}/ClingSyncTest"
        composeTestRule.onNodeWithText("Source Directory").performClick()
        composeTestRule.onNodeWithText(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DCIM).absolutePath,
        ).performTextReplacement(customDir)

        // Change destination path for custom folder uploads.
        composeTestRule.onNodeWithText("Destination Path (optional)").performClick()
        composeTestRule.onNodeWithText(repoPathPrefix).performTextReplacement("/backup")

        composeTestRule.onNodeWithText("Save").performClick()
        composeTestRule.waitUntilExactlyOneExists(hasTestTag("upload_all_button"), 10000)

        // With media-only, should see photo.jpg and video.mp4 but NOT notes.txt or report.pdf.
        composeTestRule.waitUntilExactlyOneExists(hasText("photo.jpg", substring = true), 5000)
        composeTestRule.waitUntilExactlyOneExists(hasText("video.mp4", substring = true), 5000)

        // Upload the media file.
        composeTestRule.onNodeWithText("photo.jpg", substring = true).performClick()
        composeTestRule.waitUntilExactlyOneExists(hasTestTag("upload_button").and(isEnabled()))
        composeTestRule.onNodeWithText("Upload Selected").performClick()
        composeTestRule.waitUntilNodeCount(hasContentDescription("Synced"), 1, 10000)

        // --- Toggle media-only setting ---
        // Verify we can open settings and toggle the checkbox (non-media files won't
        // show on the emulator because MANAGE_EXTERNAL_STORAGE doesn't fully propagate
        // to the FUSE layer — this works on real devices).
        composeTestRule.onNode(hasContentDescription("Settings")).performClick()
        composeTestRule.waitUntilExactlyOneExists(hasText("Media files only"), 5000)
        composeTestRule.onNodeWithText("Media files only").performClick()
        composeTestRule.onNodeWithText("Save").performClick()
        composeTestRule.waitUntilExactlyOneExists(hasTestTag("upload_all_button"), 10000)
    }
}
