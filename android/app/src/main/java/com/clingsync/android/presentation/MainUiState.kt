package com.clingsync.android.presentation

import androidx.compose.runtime.Immutable
import com.clingsync.android.AppSettings
import com.clingsync.android.FileStatus
import com.clingsync.android.UploadInfo
import com.clingsync.android.getFileFolder
import com.clingsync.android.getSourceDirectory
import com.clingsync.android.isSelectable
import java.io.File
import java.util.UUID

// A transient prompt shown over the main screen (and, where applicable, over the
// open Settings dialog). At most one is shown at a time, which makes the old
// `if (currentErrorDialog == null)` guards a type-level invariant.
sealed interface Overlay {
    data object None : Overlay

    data object StoragePermission : Overlay

    data class Passphrase(val showKeychainOption: Boolean) : Overlay

    data object S3Credentials : Overlay

    data class Error(val title: String, val message: String) : Overlay
}

// The terminal result of a share upload, shown as a dialog whose acknowledgement
// returns to the main app. Set only in share mode.
sealed interface ShareOutcome {
    data class Success(val fileCount: Int) : ShareOutcome

    data class Failure(val message: String) : ShareOutcome
}

// The entire screen state as one immutable value. Selection is keyed by path
// (not File) so the state is value-comparable and trivially assertable.
@Immutable
data class MainUiState(
    val settings: AppSettings,
    val hasPermission: Boolean = false,
    val isLoadingFiles: Boolean = false,
    val files: List<File> = emptyList(),
    val fileStatus: Map<String, FileStatus> = emptyMap(),
    val selectedPaths: Set<String> = emptySet(),
    val searchQuery: String = "",
    val showSearch: Boolean = false,
    val isConnecting: Boolean = false,
    val isConnected: Boolean = false,
    val isScanning: Boolean = false,
    val scanProgress: Pair<Int, Int>? = null,
    val isUploading: Boolean = false,
    val isUploadInitiated: Boolean = false,
    val currentUploadId: UUID? = null,
    val currentUploadPaths: Set<String> = emptySet(),
    val uploadInfo: UploadInfo? = null,
    val uploadedBytes: Long = 0L,
    val showSettings: Boolean = false,
    val overlay: Overlay = Overlay.None,
    // Set when the screen is hosting a share: it shows the target-directory picker
    // and a Cancel-only top bar instead of search/refresh/settings.
    val shareMode: Boolean = false,
    val shareTargetOptions: List<String> = emptyList(),
    val shareOutcome: ShareOutcome? = null,
) {
    // True while an upload is initiated or running; the top bar and refresh/
    // settings/search controls are disabled in this state.
    val isBusy: Boolean get() = isUploading || isUploadInitiated

    // The list after applying the folder-aware search filter.
    val displayedFiles: List<File>
        get() {
            if (searchQuery.isBlank()) return files
            val query = searchQuery.lowercase()
            val sourceDir = getSourceDirectory(settings)
            return files.filter { file ->
                val folder = getFileFolder(file, sourceDir)
                val displayName = if (folder != null) "$folder/${file.name}" else file.name
                displayName.lowercase().contains(query)
            }
        }

    // The paths "Select All" would select: visible and still uploadable.
    val selectAllTargets: Set<String>
        get() = displayedFiles.map { it.absolutePath }.filter { isSelectable(fileStatus[it]) }.toSet()

    // The currently-selected files among those visible.
    val selectedFiles: List<File> get() = displayedFiles.filter { it.absolutePath in selectedPaths }

    companion object {
        fun initial(settings: AppSettings): MainUiState = MainUiState(settings = settings, showSettings = !settings.isValid())
    }
}
