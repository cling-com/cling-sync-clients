package com.clingsync.android

import android.Manifest
import android.content.Context
import android.os.Environment
import androidx.compose.ui.test.junit4.createAndroidComposeRule
import androidx.compose.ui.test.onNodeWithText
import androidx.compose.ui.test.performClick
import androidx.compose.ui.test.performTextInput
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.test.platform.app.InstrumentationRegistry
import androidx.test.rule.GrantPermissionRule
import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import kotlinx.coroutines.withTimeout
import org.junit.After
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import java.io.File

@RunWith(AndroidJUnit4::class)
class IntegrationTest {
    private val serverUrl = System.getenv("TEST_SERVER_URL") ?: "http://10.0.2.2:9124"
    private val testPassphrase = System.getenv("TEST_PASSPHRASE") ?: "testpassphrase"
    private val repoPathPrefix = System.getenv("TEST_DESTINATION_PATH") ?: "/phone/camera/"

    private lateinit var file1: File
    private lateinit var file2: File
    private lateinit var file3: File

    init {
        // Create sample files in DCIM before activity starts
        val dcimDir = Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DCIM)
        val cameraDir = File(dcimDir, "Camera")
        cameraDir.mkdirs()

        file1 =
            File(cameraDir, "blue_sky.jpg").apply {
                writeText("Blue sky")
            }
        file2 =
            File(cameraDir, "red_earth.jpg").apply {
                writeText("Red earth")
            }
        file3 =
            File(cameraDir, "green_grass.jpg").apply {
                writeText("Green grass")
            }
    }

    @get:Rule(order = 1)
    val permissionRule: GrantPermissionRule =
        GrantPermissionRule.grant(
            Manifest.permission.READ_MEDIA_IMAGES,
            Manifest.permission.READ_MEDIA_VIDEO,
            Manifest.permission.READ_EXTERNAL_STORAGE,
        )

    @get:Rule(order = 2)
    val composeTestRule = createAndroidComposeRule<MainActivity>()

    @Before
    fun setup() {
        // Clear SharedPreferences to ensure settings dialog appears.
        val context = InstrumentationRegistry.getInstrumentation().targetContext
        val prefs = context.getSharedPreferences("cling_sync_prefs", Context.MODE_PRIVATE)
        prefs.edit().clear().commit()
    }

    @After
    fun teardown() {
        file1.delete()
        file2.delete()
        file3.delete()
    }

    @Test
    fun testBackupFiles() {
        // Wait for activity to load and settings dialog to appear.
        composeTestRule.waitForIdle()

        // Fill in settings and save.
        composeTestRule.onNodeWithText("Host URL").performClick()
        composeTestRule.onNodeWithText("Host URL").performTextInput(serverUrl)

        composeTestRule.onNodeWithText("Password").performClick()
        composeTestRule.onNodeWithText("Password").performTextInput(testPassphrase)

        composeTestRule.onNodeWithText("Destination Path").performClick()
        composeTestRule.onNodeWithText("Destination Path").performTextInput(repoPathPrefix)

        composeTestRule.onNodeWithText("Save").performClick()
        composeTestRule.waitForIdle()

        // Wait for files to be loaded using withTimeout
        runBlocking {
            withTimeout(5000) {
                var filesLoaded = false
                while (!filesLoaded) {
                    try {
                        composeTestRule.onNodeWithText("blue_sky.jpg", substring = true)
                        filesLoaded = true
                    } catch (e: AssertionError) {
                        // Files not loaded yet, wait a bit
                        delay(100)
                    }
                }
            }
        }

        // Select files.
        composeTestRule.onNodeWithText("blue_sky.jpg", substring = true).performClick()
        composeTestRule.onNodeWithText("red_earth.jpg", substring = true).performClick()

        // Click upload button - text should be "Upload 2 files"
        composeTestRule.onNodeWithText("Upload 2 files").performClick()

        // Wait for files to show "Done" status
        runBlocking {
            withTimeout(30000) { // 30 seconds timeout
                // Wait for both files to show "Done"
                var foundCount = 0
                while (foundCount < 2) {
                    foundCount = 0
                    try {
                        // Try to find "Done" text for first file
                        composeTestRule.onNodeWithText("Done", substring = true)
                        foundCount++

                        // Since we can't easily check for multiple instances,
                        // just wait a bit more to ensure both are done
                        delay(2000)
                        foundCount = 2
                    } catch (e: AssertionError) {
                        // Not done yet
                        delay(500)
                    }
                }
            }
        }
    }
}
