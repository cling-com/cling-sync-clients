package com.clingsync.android

import android.Manifest
import android.content.Context
import android.os.Environment
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.assertCountEquals
import androidx.compose.ui.test.hasContentDescription
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.isEnabled
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onAllNodesWithText
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
    private val serverUrl = System.getenv("TEST_SERVER_URL") ?: "s3+http://10.0.2.2:9124"
    private val embeddedServerUrl = System.getenv("TEST_SERVER_URL_EMBEDDED") ?: ""
    private val testPassphrase = System.getenv("TEST_PASSPHRASE") ?: "testpassphrase"
    private val testS3AccessKeyId = System.getenv("TEST_S3_ACCESS_KEY_ID") ?: "minioadmin"
    private val testS3AccessKey = System.getenv("TEST_S3_ACCESS_KEY") ?: "minioadmin"
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
        // First try an invalid URL (missing the `s3+` prefix) to verify the
        // validation dialog appears.
        composeTestRule.onNodeWithText("Host URL").performTextInput("https://wrong.example.com")
        composeTestRule.onNodeWithText("Author").performClick()
        composeTestRule.onNodeWithText("Author").performTextReplacement("Testinger")
        composeTestRule.onNodeWithText("Test").performClick()
        composeTestRule.waitUntilExactlyOneExists(hasText("Invalid Host URL"), 5000)
        composeTestRule.onNodeWithText("OK").performClick()
        // Replace with the valid URL and continue.
        composeTestRule.onNodeWithText("Host URL").performTextReplacement(serverUrl)

        composeTestRule.onNodeWithText("Destination Path (optional)").performClick()
        composeTestRule.onNodeWithText("Destination Path (optional)").performTextInput(repoPathPrefix)

        composeTestRule.onNodeWithText("Test").performClick()
        composeTestRule.waitUntilExactlyOneExists(hasText("Enter Passphrase"), 5000)
        composeTestRule.onNodeWithText("Passphrase").performClick()
        composeTestRule.onNodeWithText("Passphrase").performTextInput(testPassphrase)
        composeTestRule.onNodeWithText("Continue").performClick()
        composeTestRule.waitUntilExactlyOneExists(hasText("S3 Credentials"), 5000)
        composeTestRule.onNodeWithText("S3 Key ID").performClick()
        composeTestRule.onNodeWithText("S3 Key ID").performTextInput(testS3AccessKeyId)
        composeTestRule.onNodeWithText("S3 Access Key").performClick()
        composeTestRule.onNodeWithText("S3 Access Key").performTextInput(testS3AccessKey)
        composeTestRule.onNodeWithText("Continue").performClick()
        composeTestRule.waitForIdle()

        composeTestRule.waitUntilExactlyOneExists(hasText("Save"), 10000)
        composeTestRule.onNodeWithText("Save").performClick()
        composeTestRule.waitUntilExactlyOneExists(hasTestTag("select_all_button"), 10000)

        // Select and upload DCIM files (including one from a subfolder).
        composeTestRule.onNodeWithText("blue_sky.jpg", substring = true).performClick()
        composeTestRule.onNodeWithText("red_earth.jpg", substring = true).performClick()
        composeTestRule.onNodeWithText("sunset.jpg", substring = true).performClick()
        composeTestRule.waitUntilExactlyOneExists(hasTestTag("upload_button").and(isEnabled()))
        composeTestRule.onNodeWithText("Upload").performClick()
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
        composeTestRule.waitUntilExactlyOneExists(hasTestTag("select_all_button"), 10000)

        // With media-only, should see photo.jpg and video.mp4 but NOT notes.txt or report.pdf.
        composeTestRule.waitUntilExactlyOneExists(hasText("photo.jpg", substring = true), 5000)
        composeTestRule.waitUntilExactlyOneExists(hasText("video.mp4", substring = true), 5000)

        // Upload the media file.
        composeTestRule.onNodeWithText("photo.jpg", substring = true).performClick()
        composeTestRule.waitUntilExactlyOneExists(hasTestTag("upload_button").and(isEnabled()))
        composeTestRule.onNodeWithText("Upload").performClick()
        composeTestRule.waitUntilNodeCount(hasContentDescription("Synced"), 1, 10000)

        // --- Toggle media-only setting ---
        // Verify we can open settings and toggle the checkbox (non-media files won't
        // show on the emulator because MANAGE_EXTERNAL_STORAGE doesn't fully propagate
        // to the FUSE layer — this works on real devices).
        composeTestRule.onNode(hasContentDescription("Settings")).performClick()
        composeTestRule.waitUntilExactlyOneExists(hasText("Media files only"), 5000)
        composeTestRule.onNodeWithText("Media files only").performClick()
        composeTestRule.onNodeWithText("Save").performClick()
        composeTestRule.waitUntilExactlyOneExists(hasTestTag("select_all_button"), 10000)
    }

    @OptIn(ExperimentalTestApi::class)
    @Test
    fun testEmbeddedCredentialsUrlSkipsS3Prompt() {
        if (embeddedServerUrl.isEmpty()) {
            // The Go-side harness produces this URL. Skip when running gradle alone.
            return
        }
        composeTestRule.waitForIdle()

        composeTestRule.waitUntilExactlyOneExists(hasText("Host URL"), 5000)
        composeTestRule.onNodeWithText("Host URL").performClick()
        composeTestRule.onNodeWithText("Host URL").performTextInput(embeddedServerUrl)

        composeTestRule.onNodeWithText("Destination Path (optional)").performClick()
        composeTestRule.onNodeWithText("Destination Path (optional)").performTextInput(repoPathPrefix)

        composeTestRule.onNodeWithText("Author").performClick()
        composeTestRule.onNodeWithText("Author").performTextReplacement("Testinger")

        composeTestRule.onNodeWithText("Test").performClick()
        composeTestRule.waitUntilExactlyOneExists(hasText("Enter Passphrase"), 5000)
        composeTestRule.onNodeWithText("Passphrase").performClick()
        composeTestRule.onNodeWithText("Passphrase").performTextInput(testPassphrase)
        composeTestRule.onNodeWithText("Continue").performClick()

        // Connection should succeed without any S3 prompt. We assert this by
        // waiting for the Save button to enable while the S3 dialog never
        // shows.
        composeTestRule.waitUntilExactlyOneExists(hasText("Save"), 10000)
        composeTestRule.onAllNodesWithText("S3 Credentials").assertCountEquals(0)
    }
}
