package com.clingsync.android

// Per-file state shown in the list and driven by scanning + the upload worker.
sealed class FileStatus {
    object Scanning : FileStatus()

    object New : FileStatus()

    object Exists : FileStatus()

    object Waiting : FileStatus()

    object Uploading : FileStatus()

    object Uploaded : FileStatus()

    object Committing : FileStatus()

    object Done : FileStatus()

    object Aborted : FileStatus()

    data class Failed(val error: String) : FileStatus()
}

// Progress shown in the top bar while an upload runs.
data class UploadInfo(
    val currentFile: String? = null,
    val currentIndex: Int = 0,
    val totalFiles: Int = 0,
)

// A file can be (de)selected only in a not-yet-uploaded state. Used by both the
// row (whether a tap toggles it) and Select All, so they stay consistent.
fun isSelectable(status: FileStatus?): Boolean =
    status is FileStatus.New || status is FileStatus.Failed || status is FileStatus.Aborted || status == null
