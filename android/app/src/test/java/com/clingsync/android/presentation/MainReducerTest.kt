package com.clingsync.android.presentation

import com.clingsync.android.AppSettings
import com.clingsync.android.FileStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import java.io.File

class MainReducerTest {
    private val source = "/sdcard/DCIM"

    private fun settings(
        host: String = "s3+http://server-a",
        prefix: String = "/phone/",
        sourceDir: String = source,
        mediaOnly: Boolean = true,
    ) = AppSettings(
        hostUrl = host,
        repoPathPrefix = prefix,
        author = "Tester",
        sourceDirectory = sourceDir,
        mediaOnly = mediaOnly,
    )

    private fun path(name: String) = "$source/$name"

    private fun stateWithFiles(statuses: Map<String, FileStatus>) =
        MainUiState(
            settings = settings(),
            files = statuses.keys.map { File(it) },
            fileStatus = statuses,
            isConnected = true,
        )

    @Test
    fun toggleSelectionAddsThenRemoves() {
        val s0 = stateWithFiles(mapOf(path("a.jpg") to FileStatus.New))
        val selected = MainReducer.reduce(s0, MainEvent.FileSelectionChanged(path("a.jpg"), true)).state
        assertEquals(setOf(path("a.jpg")), selected.selectedPaths)
        val deselected = MainReducer.reduce(selected, MainEvent.FileSelectionChanged(path("a.jpg"), false)).state
        assertTrue(deselected.selectedPaths.isEmpty())
    }

    @Test
    fun selectAllPicksOnlySelectableFiles() {
        val s0 =
            stateWithFiles(
                mapOf(
                    path("new.jpg") to FileStatus.New,
                    path("synced.jpg") to FileStatus.Exists("phone/synced.jpg"),
                    path("done.jpg") to FileStatus.Done,
                    path("aborted.jpg") to FileStatus.Aborted,
                ),
            )

        val next = MainReducer.reduce(s0, MainEvent.SelectAllClicked).state

        assertEquals(setOf(path("new.jpg"), path("aborted.jpg")), next.selectedPaths)
    }

    @Test
    fun searchQueryChangeClearsSelection() {
        val s0 = stateWithFiles(mapOf(path("a.jpg") to FileStatus.New)).copy(selectedPaths = setOf(path("a.jpg")))
        val next = MainReducer.reduce(s0, MainEvent.SearchQueryChanged("foo")).state
        assertEquals("foo", next.searchQuery)
        assertTrue(next.selectedPaths.isEmpty())
    }

    @Test
    fun clearingSearchKeepsSelection() {
        val s0 =
            stateWithFiles(mapOf(path("a.jpg") to FileStatus.New))
                .copy(searchQuery = "a", selectedPaths = setOf(path("a.jpg")))

        val next = MainReducer.reduce(s0, MainEvent.SearchCleared).state

        assertEquals("", next.searchQuery)
        // Unlike editing the query, the clear-X preserves the selection.
        assertEquals(setOf(path("a.jpg")), next.selectedPaths)
    }

    @Test
    fun searchFilterMatchesFolderAndName() {
        val s0 =
            stateWithFiles(
                mapOf(
                    path("beach.jpg") to FileStatus.New,
                    "$source/vacation/sunset.jpg" to FileStatus.New,
                ),
            ).copy(searchQuery = "vacation")

        assertEquals(listOf(File("$source/vacation/sunset.jpg")), s0.displayedFiles)
    }

    @Test
    fun openingSearchClearsSelectionClosingClearsQuery() {
        val s0 = stateWithFiles(mapOf(path("a.jpg") to FileStatus.New)).copy(selectedPaths = setOf(path("a.jpg")))

        val opened = MainReducer.reduce(s0, MainEvent.SearchToggled).state
        assertTrue(opened.showSearch)
        assertTrue(opened.selectedPaths.isEmpty())

        val withQuery = opened.copy(searchQuery = "x")
        val closed = MainReducer.reduce(withQuery, MainEvent.SearchToggled).state
        assertFalse(closed.showSearch)
        assertEquals("", closed.searchQuery)
    }

    @Test
    fun uploadEnqueuesSelectedFilesAndMarksThemWaiting() {
        val s0 =
            stateWithFiles(mapOf(path("a.jpg") to FileStatus.New, path("b.jpg") to FileStatus.New))
                .copy(selectedPaths = setOf(path("a.jpg"), path("b.jpg")))

        val reduction = MainReducer.reduce(s0, MainEvent.UploadClicked)

        assertTrue(reduction.state.isUploadInitiated)
        assertEquals(setOf(path("a.jpg"), path("b.jpg")), reduction.state.currentUploadPaths)
        assertEquals(FileStatus.Waiting, reduction.state.fileStatus[path("a.jpg")])
        assertTrue(reduction.state.selectedPaths.isEmpty())
        assertEquals(2, reduction.state.uploadInfo?.totalFiles)
        assertEquals(
            listOf(Effect.EnqueueUpload(listOf(path("a.jpg"), path("b.jpg")), "Tester")),
            reduction.effects,
        )
    }

    @Test
    fun uploadWithNoSelectionDoesNothing() {
        val s0 = stateWithFiles(mapOf(path("a.jpg") to FileStatus.New))
        val reduction = MainReducer.reduce(s0, MainEvent.UploadClicked)
        assertEquals(s0, reduction.state)
        assertTrue(reduction.effects.isEmpty())
    }

    @Test
    fun abortResetsInitiatedAndRequestsCancel() {
        val s0 = stateWithFiles(emptyMap()).copy(isUploadInitiated = true)
        val reduction = MainReducer.reduce(s0, MainEvent.AbortClicked)
        assertFalse(reduction.state.isUploadInitiated)
        assertEquals(listOf(Effect.CancelUpload), reduction.effects)
    }

    @Test
    fun savingANewRepositoryInvalidatesTheOldOne() {
        val s0 =
            stateWithFiles(mapOf(path("a.jpg") to FileStatus.Done))
                .copy(selectedPaths = setOf(path("a.jpg")), isConnected = true)
        val newSettings = settings(host = "s3+http://server-b")

        val reduction = MainReducer.reduce(s0, MainEvent.SettingsSaved(newSettings))

        assertFalse(reduction.state.isConnected)
        assertTrue(reduction.state.fileStatus.isEmpty())
        assertTrue(reduction.state.selectedPaths.isEmpty())
        assertFalse(reduction.state.showSettings)
        assertEquals(
            listOf(
                Effect.PersistSettings(newSettings),
                Effect.InvalidateRepository("s3+http://server-a"),
                Effect.LoadFiles,
            ),
            reduction.effects,
        )
    }

    @Test
    fun changingOnlyTheSourceKeepsTheConnectionButReloads() {
        val s0 = stateWithFiles(mapOf(path("a.jpg") to FileStatus.Done)).copy(isConnected = true)
        val newSettings = settings(sourceDir = "/sdcard/Pictures")

        val reduction = MainReducer.reduce(s0, MainEvent.SettingsSaved(newSettings))

        assertTrue(reduction.state.isConnected)
        assertTrue(reduction.state.fileStatus.isEmpty())
        assertEquals(listOf(Effect.PersistSettings(newSettings), Effect.LoadFiles), reduction.effects)
    }

    @Test
    fun savingUnchangedSettingsJustPersists() {
        val s0 = stateWithFiles(mapOf(path("a.jpg") to FileStatus.Done)).copy(isConnected = true)

        val reduction = MainReducer.reduce(s0, MainEvent.SettingsSaved(s0.settings))

        assertTrue(reduction.state.isConnected)
        assertEquals(mapOf(path("a.jpg") to FileStatus.Done), reduction.state.fileStatus)
        assertEquals(listOf(Effect.PersistSettings(s0.settings)), reduction.effects)
    }

    @Test
    fun savingAnInvalidHostUrlShowsErrorAndDoesNotPersist() {
        val s0 = stateWithFiles(emptyMap())
        val reduction = MainReducer.reduce(s0, MainEvent.SettingsSaved(settings(host = "https://nope")))

        assertTrue(reduction.state.overlay is Overlay.Error)
        assertEquals("Invalid Host URL", (reduction.state.overlay as Overlay.Error).title)
        assertEquals(s0.settings, reduction.state.settings)
        assertTrue(reduction.effects.isEmpty())
    }

    @Test
    fun connectFailureShowsConnectionErrorWhenNoOverlayPresent() {
        val s0 = stateWithFiles(emptyMap()).copy(isConnecting = true)
        val next = MainReducer.reduce(s0, MainEvent.ConnectFailed("Failed to connect: nope")).state
        assertFalse(next.isConnecting)
        assertFalse(next.isConnected)
        assertEquals(Overlay.Error("Connection Error", "Failed to connect: nope"), next.overlay)
    }

    @Test
    fun scanFailureRevertsScanningFilesToNew() {
        val s0 =
            stateWithFiles(mapOf(path("a.jpg") to FileStatus.Scanning, path("b.jpg") to FileStatus.Done))
        val next = MainReducer.reduce(s0, MainEvent.ScanFailed("io", listOf(path("a.jpg"), path("b.jpg")))).state
        assertEquals(FileStatus.New, next.fileStatus[path("a.jpg")])
        // Only files that were Scanning are reverted.
        assertEquals(FileStatus.Done, next.fileStatus[path("b.jpg")])
        assertFalse(next.isScanning)
    }
}
