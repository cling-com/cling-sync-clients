package com.clingsync.android.presentation

import com.clingsync.android.FileStatus
import com.clingsync.android.UploadInfo
import java.io.File

// Pure transition table for the WorkManager-driven upload state machine. Every
// rule that used to live in MainActivity's LaunchedEffect(uploadWorkInfos) is
// here, operating on plain data so it is exhaustively unit-testable without
// WorkManager, an emulator, or any IO.
object UploadReducer {
    fun reduce(
        state: MainUiState,
        update: WorkUpdate,
    ): MainUiState =
        when (update) {
            is WorkUpdate.Enqueued -> state.copy(currentUploadId = update.id)
            is WorkUpdate.Running -> running(state, update)
            is WorkUpdate.Succeeded -> succeeded(state, update)
            is WorkUpdate.Failed -> failed(state, update)
            WorkUpdate.Cancelled -> cancelled(state)
        }

    private fun running(
        state: MainUiState,
        update: WorkUpdate.Running,
    ): MainUiState {
        // Ignore a progress signal when there is no upload to attach it to: a
        // stale "Running" after the upload ended (the abort race the old code
        // had). A reattached upload after process death has currentUploadId set
        // (idle() nulls it on end), so it is correctly NOT dropped here.
        if (!state.isUploading && !state.isUploadInitiated && state.currentUploadId == null) return state

        // A transient unreadable status file yields no statuses; flag uploading
        // but keep the previous uploadInfo rather than resetting it to 0/0.
        if (update.statuses.isEmpty()) return state.copy(isUploading = true)

        val uploadingPath = update.statuses.entries.firstOrNull { it.value is FileStatus.Uploading }?.key
        val currentFileName = uploadingPath?.let { File(it).name }
        val completed =
            update.statuses.count {
                it.value is FileStatus.Uploaded || it.value is FileStatus.Exists || it.value is FileStatus.Committing
            }
        val total = update.statuses.size
        val info =
            when {
                update.statuses.any { it.value is FileStatus.Committing } ->
                    UploadInfo("Committing changes...", completed, total)
                currentFileName != null -> UploadInfo(currentFileName, completed, total)
                else -> UploadInfo(null, completed, total)
            }
        return state.copy(
            isUploading = true,
            fileStatus = state.fileStatus + update.statuses,
            uploadInfo = info,
            uploadedBytes = update.uploadedBytes,
        )
    }

    private fun succeeded(
        state: MainUiState,
        update: WorkUpdate.Succeeded,
    ): MainUiState =
        idle(state).copy(
            fileStatus = state.fileStatus + update.finalStatuses,
            selectedPaths = emptySet(),
        )

    private fun failed(
        state: MainUiState,
        update: WorkUpdate.Failed,
    ): MainUiState =
        idle(state).copy(
            fileStatus = markUnfinished(state, FileStatus.Failed("Error")),
            // The share surfaces a failure through its own outcome dialog (which returns
            // to the main app), so it must not also raise the error overlay.
            overlay =
                if (!state.shareMode && state.overlay is Overlay.None) {
                    Overlay.Error("Upload Failed", update.error)
                } else {
                    state.overlay
                },
        )

    private fun cancelled(state: MainUiState): MainUiState = idle(state).copy(fileStatus = markUnfinished(state, FileStatus.Aborted))

    // Mark every in-flight file (not already Done/Exists) with the given status.
    private fun markUnfinished(
        state: MainUiState,
        status: FileStatus,
    ): Map<String, FileStatus> {
        val updates =
            state.currentUploadPaths
                .filter { state.fileStatus[it] !is FileStatus.Done && state.fileStatus[it] !is FileStatus.Exists }
                .associateWith { status }
        return state.fileStatus + updates
    }

    // Reset every per-upload field back to the not-uploading baseline.
    private fun idle(state: MainUiState): MainUiState =
        state.copy(
            isUploading = false,
            isUploadInitiated = false,
            currentUploadId = null,
            currentUploadPaths = emptySet(),
            uploadInfo = null,
            uploadedBytes = 0L,
        )
}
