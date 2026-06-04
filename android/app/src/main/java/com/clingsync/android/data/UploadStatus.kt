package com.clingsync.android.data

// The status vocabulary the upload worker writes to its progress/result files.
// Centralised here so the worker (writer) and the UI (reader) share one schema.
enum class UploadStatus(val wire: String) {
    WAITING("waiting"),
    UPLOADING("uploading"),
    UPLOADED("uploaded"),
    SKIPPED("skipped"),
    COMMITTING("committing"),
    ;

    companion object {
        fun fromWire(wire: String): UploadStatus? = entries.firstOrNull { it.wire == wire }
    }
}
