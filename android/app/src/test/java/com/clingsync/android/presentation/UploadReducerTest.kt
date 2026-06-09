package com.clingsync.android.presentation

import com.clingsync.android.AppSettings
import com.clingsync.android.FileStatus
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import java.util.UUID

class UploadReducerTest {
    private val settings =
        AppSettings(hostUrl = "s3+http://h", author = "Tester", sourceDirectory = "/sdcard/DCIM")

    private fun uploading(
        paths: List<String>,
        status: FileStatus = FileStatus.Waiting,
    ) = MainUiState(
        settings = settings,
        isUploading = true,
        isUploadInitiated = true,
        currentUploadId = UUID.fromString("00000000-0000-0000-0000-000000000001"),
        currentUploadPaths = paths.toSet(),
        fileStatus = paths.associateWith { status },
    )

    @Test
    fun enqueuedRecordsTheWorkId() {
        val id = UUID.fromString("00000000-0000-0000-0000-0000000000aa")
        val next = UploadReducer.reduce(MainUiState(settings), WorkUpdate.Enqueued(id))
        assertEquals(id, next.currentUploadId)
    }

    @Test
    fun runningMergesStatusesAndSetsUploading() {
        val state = uploading(listOf("/a", "/b"))
        val update =
            WorkUpdate.Running(
                statuses = mapOf("/a" to FileStatus.Uploading, "/b" to FileStatus.Waiting),
                uploadedBytes = 1234,
            )

        val next = UploadReducer.reduce(state, update)

        assertTrue(next.isUploading)
        assertEquals(FileStatus.Uploading, next.fileStatus["/a"])
        assertEquals(1234, next.uploadedBytes)
        assertEquals("a", next.uploadInfo?.currentFile)
        assertEquals(2, next.uploadInfo?.totalFiles)
    }

    @Test
    fun runningShowsCommittingWhenAnyFileIsCommitting() {
        val state = uploading(listOf("/a", "/b"))
        val update =
            WorkUpdate.Running(
                statuses = mapOf("/a" to FileStatus.Committing, "/b" to FileStatus.Committing),
                uploadedBytes = 0,
            )

        val next = UploadReducer.reduce(state, update)

        assertEquals("Committing changes...", next.uploadInfo?.currentFile)
        assertEquals(2, next.uploadInfo?.currentIndex)
    }

    @Test
    fun reattachAfterProcessDeathThenRunningShowsProgress() {
        // Fresh process: no busy flags, no id. Reattach assigns the id, then a
        // Running must NOT be dropped (it has an id to attach to).
        val id = UUID.fromString("00000000-0000-0000-0000-0000000000bb")
        val reattached = UploadReducer.reduce(MainUiState(settings), WorkUpdate.Enqueued(id))
        val running =
            UploadReducer.reduce(reattached, WorkUpdate.Running(mapOf("/a" to FileStatus.Uploading), uploadedBytes = 7))

        assertTrue(running.isUploading)
        assertEquals(FileStatus.Uploading, running.fileStatus["/a"])
        assertEquals("a", running.uploadInfo?.currentFile)
    }

    @Test
    fun runningWithNoStatusesKeepsPreviousUploadInfo() {
        val previous = uploading(listOf("/a")).copy(uploadInfo = com.clingsync.android.UploadInfo("a", 1, 3))
        val next = UploadReducer.reduce(previous, WorkUpdate.Running(emptyMap(), uploadedBytes = 0))
        assertTrue(next.isUploading)
        assertEquals("a", next.uploadInfo?.currentFile)
    }

    @Test
    fun staleRunningAfterUploadEndedIsIgnored() {
        // The abort race: a late progress signal must not revive a finished upload.
        val ended =
            MainUiState(
                settings = settings,
                isUploading = false,
                isUploadInitiated = false,
                fileStatus = mapOf("/a" to FileStatus.Aborted),
            )
        val update = WorkUpdate.Running(mapOf("/a" to FileStatus.Uploading), uploadedBytes = 5)

        val next = UploadReducer.reduce(ended, update)

        assertEquals(ended, next)
        assertEquals(FileStatus.Aborted, next.fileStatus["/a"])
    }

    @Test
    fun succeededMarksFinalStatusesClearsSelectionAndResets() {
        val state = uploading(listOf("/a", "/b"), FileStatus.Committing).copy(selectedPaths = setOf("/x"))
        val update =
            WorkUpdate.Succeeded(mapOf("/a" to FileStatus.Done, "/b" to FileStatus.Exists))

        val next = UploadReducer.reduce(state, update)

        assertEquals(FileStatus.Done, next.fileStatus["/a"])
        assertEquals(FileStatus.Exists, next.fileStatus["/b"])
        assertFalse(next.isUploading)
        assertFalse(next.isUploadInitiated)
        assertNull(next.currentUploadId)
        assertTrue(next.currentUploadPaths.isEmpty())
        assertNull(next.uploadInfo)
        assertTrue(next.selectedPaths.isEmpty())
    }

    @Test
    fun failedMarksInflightFailedAndShowsDialog() {
        val state = uploading(listOf("/a", "/b"), FileStatus.Uploading)
        val next = UploadReducer.reduce(state, WorkUpdate.Failed("boom"))

        assertEquals(FileStatus.Failed("Error"), next.fileStatus["/a"])
        assertEquals(FileStatus.Failed("Error"), next.fileStatus["/b"])
        assertFalse(next.isUploading)
        assertEquals(Overlay.Error("Upload Failed", "boom"), next.overlay)
    }

    @Test
    fun shareModeFailureRoutesToTheDialogNotTheErrorOverlay() {
        val state = uploading(listOf("/a"), FileStatus.Uploading).copy(shareMode = true)
        val next = UploadReducer.reduce(state, WorkUpdate.Failed("boom"))

        assertEquals(FileStatus.Failed("Error"), next.fileStatus["/a"])
        // The share surfaces the failure via its own outcome dialog (set by the
        // ViewModel), so the reducer must not also raise the error overlay.
        assertEquals(Overlay.None, next.overlay)
    }

    @Test
    fun cancelledMarksInflightAbortedButKeepsCompletedFiles() {
        val state =
            uploading(listOf("/a", "/b"), FileStatus.Uploading)
                .copy(fileStatus = mapOf("/a" to FileStatus.Uploading, "/b" to FileStatus.Done))

        val next = UploadReducer.reduce(state, WorkUpdate.Cancelled)

        assertEquals(FileStatus.Aborted, next.fileStatus["/a"])
        // Already-finished files are preserved, not reverted to Aborted.
        assertEquals(FileStatus.Done, next.fileStatus["/b"])
        assertFalse(next.isUploading)
        assertTrue(next.currentUploadPaths.isEmpty())
    }

    @Test
    fun failedDoesNotReplaceAnExistingOverlay() {
        val state = uploading(listOf("/a")).copy(overlay = Overlay.Error("Connection Error", "earlier"))
        val next = UploadReducer.reduce(state, WorkUpdate.Failed("boom"))
        assertEquals(Overlay.Error("Connection Error", "earlier"), next.overlay)
    }
}
