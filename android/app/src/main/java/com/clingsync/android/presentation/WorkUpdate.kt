package com.clingsync.android.presentation

import com.clingsync.android.FileStatus
import java.util.UUID

// A normalized WorkManager signal. The ViewModel produces it from the raw
// List<WorkInfo> plus the parsed status/result JSON, so the reducer never sees
// androidx.work types and never touches the filesystem.
sealed interface WorkUpdate {
    data class Enqueued(val id: UUID) : WorkUpdate

    data class Running(
        val statuses: Map<String, FileStatus>,
        val uploadedBytes: Long,
    ) : WorkUpdate

    data class Succeeded(val finalStatuses: Map<String, FileStatus>) : WorkUpdate

    data class Failed(val error: String) : WorkUpdate

    data object Cancelled : WorkUpdate
}
