package com.clingsync.android.data

import com.clingsync.android.FileStatus
import org.json.JSONObject
import java.io.File

// Typed read/write of the upload worker's status/result JSON (keyed by absolute
// file path). The worker writes [UploadStatus]; the UI reads [FileStatus] with
// either in-progress or terminal semantics. One schema, two readers.
object UploadProgressIo {
    fun write(
        file: File,
        statuses: Map<String, UploadStatus>,
    ) {
        val json = JSONObject()
        statuses.forEach { (path, status) -> json.put(path, status.wire) }
        file.writeText(json.toString())
    }

    // In-progress semantics: how a still-running upload's statuses map to the list.
    fun readProgress(file: File): Map<String, FileStatus> =
        read(file) { status ->
            when (status) {
                UploadStatus.WAITING -> FileStatus.Waiting
                UploadStatus.UPLOADING -> FileStatus.Uploading
                UploadStatus.UPLOADED -> FileStatus.Uploaded
                UploadStatus.SKIPPED -> FileStatus.Exists("")
                UploadStatus.COMMITTING -> FileStatus.Committing
                null -> FileStatus.New
            }
        }

    // Terminal semantics: how the final result maps to the list. Entries with no
    // terminal meaning are dropped so they don't overwrite existing state.
    fun readResult(file: File): Map<String, FileStatus> =
        read(file) { status ->
            when (status) {
                UploadStatus.COMMITTING, UploadStatus.UPLOADED -> FileStatus.Done
                UploadStatus.SKIPPED -> FileStatus.Exists("")
                else -> null
            }
        }

    private fun read(
        file: File,
        map: (UploadStatus?) -> FileStatus?,
    ): Map<String, FileStatus> {
        val json = JSONObject(file.readText())
        val result = mutableMapOf<String, FileStatus>()
        json.keys().forEach { path ->
            map(UploadStatus.fromWire(json.getString(path)))?.let { result[path] = it }
        }
        return result
    }
}
