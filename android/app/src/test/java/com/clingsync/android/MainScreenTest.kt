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
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.requestFocus
import androidx.fragment.app.FragmentActivity
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.work.Configuration
import androidx.work.WorkManager
import androidx.work.testing.SynchronousExecutor
import androidx.work.testing.WorkManagerTestInitHelper
import com.clingsync.android.ui.theme.ClingSyncTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.runTest
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.Robolectric
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import org.robolectric.shadows.ShadowLog
import java.io.File

/**
 * We employ several strategies to get this test to be non-flaky:
 *
 * - Use `UnconfinedTestDispatcher` to run coroutines immediately.
 *
 * - Use `waitUntil` with long timeouts to wait for asynchronous scanning.
 *
 * - Force looper idle state manually when needed.
 *
 * - Use mutableStateMapOf in MainActivity for better state tracking.
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [28], qualifiers = "w1000dp-h2000dp")
class MainScreenTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    private lateinit var mockBridge: MockGoBridge
    private lateinit var context: Context
    private lateinit var testWorkManager: WorkManager
    private lateinit var testPassphraseStore: PassphraseStore
    private lateinit var cameraDir: File
    private val testFiles = mutableListOf<File>()

    private val testDispatcher = UnconfinedTestDispatcher()

    @OptIn(ExperimentalCoroutinesApi::class)
    @Before
    fun setup() {
        Dispatchers.setMain(testDispatcher)

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
        testPassphraseStore = PassphraseStore(context)

        // Setup MockGoBridge in success mode.
        mockBridge = MockGoBridge()
        mockBridge.isOpen = true
        mockBridge.shouldFailOpenRepository = false
        mockBridge.shouldFailUploadFile = false
        mockBridge.shouldFailCommit = false
        mockBridge.uploadDelay = 0L

        // Replace the bridge instance with our mock.
        GoBridgeProvider.setInstance(mockBridge)

        // Grant permissions for camera access.
        grantCameraPermissions()
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    @After
    fun tearDown() {
        // Reset mock bridge state.
        mockBridge.reset()

        // Clean up test files.
        testFiles.forEach { it.delete() }
        if (::cameraDir.isInitialized) {
            cameraDir.delete()
        }

        testWorkManager.cancelAllWork()
        SHA256Cache.resetForTesting()
        Dispatchers.resetMain()
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
        shadowOf(android.os.Looper.getMainLooper()).idle()

        // Create test image files.
        val testFileNames = listOf("IMG_001.jpg", "IMG_002.jpg", "VID_001.mp4")
        testFileNames.forEach { fileName ->
            val file = File(cameraDir, fileName)
            file.writeText("Test content for $fileName")
            testFiles.add(file)
        }
    }

    fun onNode(matcher: SemanticsMatcher): SemanticsNodeInteraction {
        composeTestRule.waitForIdle()
        return composeTestRule.onNode(matcher)
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    @Test
    fun testFileDisplayAndSelection() =
        runTest(testDispatcher) {
            val activity = Robolectric.buildActivity(FragmentActivity::class.java).setup().get()
            val settingsManager = SettingsManager(context)
            settingsManager.saveSettings(
                AppSettings(
                    hostUrl = "https://test.example.com",
                    repoPathPrefix = "test/",
                ),
            )

            composeTestRule.setContent {
                ClingSyncTheme {
                    MainScreen(
                        activity = activity,
                        goBridge = mockBridge,
                        settingsManager = settingsManager,
                        passphraseStore = testPassphraseStore,
                        workManager = testWorkManager,
                        ioDispatcher = testDispatcher,
                    )
                }
            }

            shadowOf(android.os.Looper.getMainLooper()).idle()

            // Wait for checkboxes to appear.
            composeTestRule.waitUntil(30000) {
                shadowOf(android.os.Looper.getMainLooper()).idle()
                composeTestRule.onAllNodes(hasTestTag("checkbox_IMG_001.jpg")).fetchSemanticsNodes().isNotEmpty() &&
                    composeTestRule.onAllNodes(hasTestTag("checkbox_IMG_002.jpg")).fetchSemanticsNodes().isNotEmpty()
            }

            // Select first file.
            onNode(hasTestTag("checkbox_IMG_001.jpg")).performClickWorkaround()
            onNode(hasTestTag("upload_button")).assertIsDisplayed()
            onNode(hasText("Upload")).assertIsDisplayed()

            // Select second file.
            onNode(hasTestTag("checkbox_IMG_002.jpg")).performClickWorkaround()
            onNode(hasTestTag("upload_button")).assertIsDisplayed()

            // Deselect first file.
            onNode(hasTestTag("checkbox_IMG_001.jpg")).performClickWorkaround()
            onNode(hasTestTag("upload_button")).assertIsDisplayed()

            // Deselect second file.
            onNode(hasTestTag("checkbox_IMG_002.jpg")).performClickWorkaround()
            onNode(hasText("No files selected")).assertIsDisplayed()
            onNode(hasTestTag("upload_button")).assertDoesNotExist()
            onNode(hasTestTag("select_all_button")).assertIsDisplayed()
            onNode(hasText("Select All")).assertIsDisplayed()
        }

    @OptIn(ExperimentalCoroutinesApi::class)
    @Test
    fun testFullRoundtripWorkflow() =
        runTest(testDispatcher) {
            val activity = Robolectric.buildActivity(FragmentActivity::class.java).setup().get()
            val settingsManager = SettingsManager(context)
            settingsManager.saveSettings(
                AppSettings(
                    hostUrl = "https://test.example.com",
                    repoPathPrefix = "test/",
                ),
            )

            composeTestRule.setContent {
                ClingSyncTheme {
                    MainScreen(
                        activity = activity,
                        goBridge = mockBridge,
                        settingsManager = settingsManager,
                        passphraseStore = testPassphraseStore,
                        workManager = testWorkManager,
                        ioDispatcher = testDispatcher,
                    )
                }
            }

            shadowOf(android.os.Looper.getMainLooper()).idle()

            // Wait for checkboxes to appear.
            composeTestRule.waitUntil(30000) {
                shadowOf(android.os.Looper.getMainLooper()).idle()
                composeTestRule.onAllNodes(hasTestTag("checkbox_IMG_001.jpg")).fetchSemanticsNodes().isNotEmpty() &&
                    composeTestRule.onAllNodes(hasTestTag("checkbox_IMG_002.jpg")).fetchSemanticsNodes().isNotEmpty()
            }

            // Select first two files.
            onNode(hasTestTag("checkbox_IMG_001.jpg")).performClickWorkaround()
            onNode(hasTestTag("checkbox_IMG_002.jpg")).performClickWorkaround()
            onNode(hasText("Upload")).assertIsDisplayed()

            // Click upload button.
            onNode(hasText("Upload")).performClickWorkaround()

            // Wait for work to complete.
            composeTestRule.waitUntil(timeoutMillis = 10000) {
                shadowOf(android.os.Looper.getMainLooper()).idle()
                mockBridge.getCommitCount() > 0
            }

            // Verify mock was called correctly.
            val uploadCalls = mockBridge.getUploadCalls()
            val commitCalls = mockBridge.getCommitCalls()

            assertEquals(2, uploadCalls.size)
            assertEquals(1, commitCalls.size)
            assertEquals(setOf("IMG_001.jpg", "IMG_002.jpg"), uploadCalls.map { File(it).name }.toSet())
            val commitMessage = commitCalls[0].third
            assertTrue("Commit message should say '2 files' but was: $commitMessage", commitMessage.contains("2 file"))
        }

// Workaround https://issuetracker.google.com/issues/372512084
    fun SemanticsNodeInteraction.performClickWorkaround(): SemanticsNodeInteraction {
        @OptIn(ExperimentalTestApi::class)
        return this.invokeGlobalAssertions()
            .requestFocus()
            .performKeyInput {
                keyDown(Key.Enter)
                keyUp(Key.Enter)
            }
    }
}
