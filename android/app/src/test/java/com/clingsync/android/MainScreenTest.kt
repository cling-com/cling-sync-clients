@file:OptIn(ExperimentalTestApi::class)

package com.clingsync.android

import androidx.compose.ui.input.key.Key
import androidx.compose.ui.test.ExperimentalTestApi
import androidx.compose.ui.test.SemanticsNodeInteraction
import androidx.compose.ui.test.assertIsDisplayed
import androidx.compose.ui.test.assertIsEnabled
import androidx.compose.ui.test.assertIsNotEnabled
import androidx.compose.ui.test.hasTestTag
import androidx.compose.ui.test.hasText
import androidx.compose.ui.test.invokeGlobalAssertions
import androidx.compose.ui.test.junit4.createComposeRule
import androidx.compose.ui.test.performKeyInput
import androidx.compose.ui.test.requestFocus
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.clingsync.android.presentation.MainEvent
import com.clingsync.android.presentation.MainUiState
import com.clingsync.android.ui.theme.ClingSyncTheme
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import java.io.File

/**
 * MainScreen is now render-only: it draws MainUiState and emits MainEvents. The
 * upload/selection/connection logic is covered by the pure reducer tests; this
 * is just a Compose smoke test that the state renders and events are emitted.
 */
@RunWith(AndroidJUnit4::class)
@Config(sdk = [30], qualifiers = "w1000dp-h2000dp")
class MainScreenTest {
    @get:Rule
    val composeTestRule = createComposeRule()

    private val events = mutableListOf<MainEvent>()

    private val settings =
        AppSettings(hostUrl = "s3+http://h", author = "Tester", sourceDirectory = "/sdcard/DCIM")

    private fun render(state: MainUiState) {
        composeTestRule.setContent {
            ClingSyncTheme {
                MainScreen(state = state, onEvent = { events.add(it) }, onBrowseDirectory = {})
            }
        }
    }

    private fun connectedState(fileStatus: Map<String, FileStatus>) =
        MainUiState(
            settings = settings,
            hasPermission = true,
            isConnected = true,
            files = fileStatus.keys.map { File(it) },
            fileStatus = fileStatus,
        )

    @Test
    fun rendersFilesAndSelectAllWhenConnected() {
        render(connectedState(mapOf("/sdcard/DCIM/a.jpg" to FileStatus.New)))

        composeTestRule.waitForIdle()
        composeTestRule.onNode(hasTestTag("checkbox_a.jpg")).assertIsDisplayed()
        composeTestRule.onNode(hasTestTag("select_all_button")).assertIsDisplayed()
    }

    @Test
    fun togglingACheckboxEmitsSelectionEvent() {
        render(connectedState(mapOf("/sdcard/DCIM/a.jpg" to FileStatus.New)))
        composeTestRule.waitForIdle()

        composeTestRule.onNode(hasTestTag("checkbox_a.jpg")).performClickWorkaround()

        assertTrue(
            events.any {
                it is MainEvent.FileSelectionChanged && it.path.endsWith("a.jpg") && it.selected
            },
        )
    }

    @Test
    fun selectionShowsTheUploadButton() {
        render(
            connectedState(mapOf("/sdcard/DCIM/a.jpg" to FileStatus.New))
                .copy(selectedPaths = setOf("/sdcard/DCIM/a.jpg")),
        )

        composeTestRule.waitForIdle()
        composeTestRule.onNode(hasTestTag("upload_button")).assertIsDisplayed()
        composeTestRule.onNode(hasText("Upload")).assertIsDisplayed()
    }

    @Test
    fun aSyncedRowIsNotSelectable() {
        // The whole row is toggleable; a synced (Exists/Done) file must not be
        // selectable by tapping it, matching Select All which already excludes it.
        render(connectedState(mapOf("/sdcard/DCIM/synced.jpg" to FileStatus.Exists)))
        composeTestRule.waitForIdle()
        composeTestRule.onNode(hasText("synced.jpg", substring = true)).assertIsNotEnabled()
    }

    @Test
    fun aNewRowIsSelectable() {
        render(connectedState(mapOf("/sdcard/DCIM/new.jpg" to FileStatus.New)))
        composeTestRule.waitForIdle()
        composeTestRule.onNode(hasText("new.jpg", substring = true)).assertIsEnabled()
    }

    @Test
    fun connectBannerShownWhenDisconnected() {
        render(
            MainUiState(settings = settings, hasPermission = true, isConnected = false)
                .copy(files = listOf(File("/sdcard/DCIM/a.jpg")), fileStatus = mapOf("/sdcard/DCIM/a.jpg" to FileStatus.New)),
        )

        composeTestRule.waitForIdle()
        composeTestRule.onNode(hasText("Repository access needed")).assertIsDisplayed()
    }

    // Workaround https://issuetracker.google.com/issues/372512084
    private fun SemanticsNodeInteraction.performClickWorkaround(): SemanticsNodeInteraction =
        this.invokeGlobalAssertions()
            .requestFocus()
            .performKeyInput {
                keyDown(Key.Enter)
                keyUp(Key.Enter)
            }
}
