@file:OptIn(ExperimentalTestApi::class)

package com.clingsync.android

import android.Manifest
import android.app.Application
import android.content.Context
import android.os.Environment
import android.util.Log
import androidx.compose.ui.input.key.Key
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.SemanticsMatcher
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.invokeGlobalAssertions
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.onRoot
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.printToString
import androidx.compose.ui.test.requestFocus
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.work.Configuration
import androidx.work.WorkManager
import androidx.work.testing.SynchronousExecutor
import androidx.work.testing.WorkManagerTestInitHelper
import com.clingsync.android.ui.theme.ClingSyncTheme
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLog
import java.io.File

/**
 * We employ several strategies to get this test to be non-flaky (which is uneccessarily hard to do):
 *
 * - Wrapping tests in UnconfinedTestDispatcher() to run coroutines immediately.
 *
 * - Use `onNode` to wait for idle UI state before attempting to find a node.
 *
 * - Use `performClickWorkaround` to work around a bug in Robolectric.
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [28])
class MainScreenTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    private lateinit var mockBridge: MockGoBridge
    private lateinit var context: Context
    private lateinit var testWorkManager: WorkManager
    private lateinit var cameraDir: File
    private val testFiles = mutableListOf<File>()

    @Before
    fun setup() {
        // Create test camera directory and files.
        setupTestCameraFiles()

        ShadowLog.stream = System.out
        context = ApplicationProvider.getApplicationContext()

        // Initialize test WorkManager before UI creation.
        val config =
            Configuration.Builder()
                .setMinimumLoggingLevel(Log.DEBUG)
                .setExecutor(SynchronousExecutor())
                .build()

        WorkManagerTestInitHelper.initializeTestWorkManager(context, config)
        testWorkManager = WorkManager.getInstance(context)

        // Setup MockGoBridge in success mode.
        mockBridge = MockGoBridge()
        mockBridge.isOpen = true
        mockBridge.shouldFailEnsureOpen = false
        mockBridge.shouldFailUploadFile = false
        mockBridge.shouldFailCommit = false
        mockBridge.uploadDelay = 10L

        // Replace the bridge instance with our mock.
        GoBridgeProvider.setInstanceForTesting(mockBridge)

        // Grant permissions for camera access.
        grantCameraPermissions()
    }

    @After
    fun tearDown() {
        // Reset mock bridge state.
        mockBridge.reset()

        // Clean up test files.
        testFiles.forEach { it.delete() }
        if (::cameraDir.isInitialized) {
            cameraDir.delete()
        }

        // Clear any pending work
        testWorkManager.cancelAllWork()
    }

    private fun grantCameraPermissions() {
        val shadowApp = shadowOf(context as Application)
        shadowApp.grantPermissions(
            Manifest.permission.READ_EXTERNAL_STORAGE,
            Manifest.permission.READ_MEDIA_IMAGES,
            Manifest.permission.READ_MEDIA_VIDEO,
        )
    }

    private fun setupTestCameraFiles() {
        // Create camera directory structure.
        cameraDir =
            File(
                Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DCIM),
                "Camera",
            )
        cameraDir.mkdirs()

        // Create test image files.
        val testFileNames = listOf("IMG_001.jpg", "IMG_002.jpg", "VID_001.mp4")
        testFileNames.forEach { fileName ->
            val file = File(cameraDir, fileName)
            file.writeText("Test content for $fileName")
            testFiles.add(file)
        }
    }

    fun onNode(matcher: SemanticsMatcher): SemanticsNodeInteraction {
        try {
            // Test tend to be flaky without this waitForIdle.
            composeTestRule.waitForIdle()
            return composeTestRule.onNode(matcher)
        } catch (e: RuntimeException) {
            val s = composeTestRule.onRoot().printToString()
            println(s)
            throw e
        }
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    @Test
    fun testFileDisplayAndSelection() =
        runTest(UnconfinedTestDispatcher()) {
            {
                val settingsManager = SettingsManager(context)
                settingsManager.saveSettings(
                    AppSettings(
                        hostUrl = "https://test.example.com",
                        password = "test123",
                        repoPathPrefix = "test/",
                    ),
                )

                composeTestRule.setContent {
                    ClingSyncTheme {
                        MainScreen(
                            goBridge = mockBridge,
                            settingsManager = settingsManager,
                            workManager = testWorkManager,
                        )
                    }
                }

                // Initial state - no files selected, no upload button visible.
                onNode(hasText("0 of 3 selected")).assertIsDisplayed()
                onNode(hasTestTag("upload_button")).assertDoesNotExist()

                // Select first file.
                onNode(hasTestTag("checkbox_IMG_001.jpg")).performClickWorkaround()
                onNode(hasText("1 of 3 selected")).assertIsDisplayed()
                onNode(hasTestTag("upload_button")).assertIsDisplayed()
                onNode(hasText("Upload 1 file")).assertIsDisplayed()

                // Select second file.
                onNode(hasTestTag("checkbox_IMG_002.jpg")).performClickWorkaround()
                onNode(hasText("2 of 3 selected")).assertIsDisplayed()
                onNode(hasTestTag("upload_button")).assertIsDisplayed()
                onNode(hasText("Upload 2 files")).assertIsDisplayed()

                // Deselect first file.
                onNode(hasTestTag("checkbox_IMG_001.jpg")).performClickWorkaround()
                onNode(hasText("1 of 3 selected")).assertIsDisplayed()
                onNode(hasTestTag("upload_button")).assertIsDisplayed()
                onNode(hasText("Upload 1 file")).assertIsDisplayed()

                // Select first file again.
                onNode(hasTestTag("checkbox_IMG_001.jpg")).performClickWorkaround()
                onNode(hasText("2 of 3 selected")).assertIsDisplayed()
                onNode(hasTestTag("upload_button")).assertIsDisplayed()
                onNode(hasText("Upload 2 files")).assertIsDisplayed()

                // Select all.
                onNode(hasTestTag("select_all")).performClickWorkaround()
                onNode(hasText("3 of 3 selected")).assertIsDisplayed()
                onNode(hasTestTag("upload_button")).assertIsDisplayed()
                onNode(hasText("Upload 3 files")).assertIsDisplayed()

                // Deselect all.
                onNode(hasTestTag("select_all")).performClickWorkaround()
                onNode(hasText("0 of 3 selected")).assertIsDisplayed()
                onNode(hasTestTag("upload_button")).assertDoesNotExist()
            }

            @OptIn(ExperimentalCoroutinesApi::class)
            @Test
            fun testFullRoundtripWorkflow() =
                runTest(UnconfinedTestDispatcher()) {
                    val settingsManager = SettingsManager(context)
                    settingsManager.saveSettings(
                        AppSettings(
                            hostUrl = "https://test.example.com",
                            password = "test123",
                            repoPathPrefix = "test/",
                        ),
                    )

                    // Create MainScreen.
                    composeTestRule.setContent {
                        ClingSyncTheme {
                            MainScreen(
                                goBridge = mockBridge,
                                settingsManager = settingsManager,
                                workManager = testWorkManager,
                            )
                        }
                    }
                    onNode(hasText("0 of 3 selected")).assertIsDisplayed()

                    // Select first two files.
                    onNode(hasTestTag("checkbox_IMG_001.jpg")).performClickWorkaround()
                    onNode(hasText("1 of 3 selected")).assertIsDisplayed()
                    onNode(hasTestTag("checkbox_IMG_002.jpg")).performClickWorkaround()
                    onNode(hasText("2 of 3 selected")).assertIsDisplayed()

                    // Click upload button.
                    onNode(hasText("Upload 2 files")).performClickWorkaround()

                    // Wait for work to complete.
                    composeTestRule.waitUntil(timeoutMillis = 2000) {
                        mockBridge.getCommitCalls().isNotEmpty()
                    }

                    // Verify mock was called correctly.
                    val uploadCalls = mockBridge.getUploadCalls()
                    val commitCalls = mockBridge.getCommitCalls()

                    assertEquals(2, uploadCalls.size)
                    assertEquals(1, commitCalls.size)
                    assertEquals(setOf("IMG_001.jpg", "IMG_002.jpg"), uploadCalls.map { File(it.first).name }.toSet())
                }
        }

// Workaround https://issuetracker.google.com/issues/372512084
    fun SemanticsNodeInteraction.performClickWorkaround(): SemanticsNodeInteraction {
        @OptIn(ExperimentalTestApi::class)
        try {
            return this.invokeGlobalAssertions()
                .requestFocus()
                .performKeyInput {
                    keyDown(Key.Enter)
                    keyUp(Key.Enter)
                }
        } catch (e: RuntimeException) {
            val s = this.printToString()
            println(s)
            throw e
        }
    }
}
