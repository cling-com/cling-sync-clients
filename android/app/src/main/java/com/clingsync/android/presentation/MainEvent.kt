package com.clingsync.android.presentation

import com.clingsync.android.AppSettings
import com.clingsync.android.FileStatus
import com.clingsync.android.PassphraseResult
import com.clingsync.android.S3CredentialsResult
import java.io.File

// Everything that can change the screen: user intents and internal completions
// (file loads, scan progress, connection results). The ViewModel translates
// launcher/biometric/work callbacks into these.
sealed interface MainEvent {
    // --- File list & selection ---
    data class FileSelectionChanged(val path: String, val selected: Boolean) : MainEvent

    data object SelectAllClicked : MainEvent

    data class SearchQueryChanged(val query: String) : MainEvent

    data object SearchToggled : MainEvent

    // The clear-X inside the search field: resets the query only, keeping the
    // current selection (unlike editing the query, which clears it).
    data object SearchCleared : MainEvent

    data object RefreshClicked : MainEvent

    // --- Upload ---
    data object UploadClicked : MainEvent

    data object AbortClicked : MainEvent

    // --- Permissions & file loading ---
    data class PermissionResult(val granted: Boolean) : MainEvent

    data object LoadingStarted : MainEvent

    data class FilesLoaded(
        val files: List<File>,
        val needsStoragePermission: Boolean,
    ) : MainEvent

    // --- Scanning ---
    data class ScanStarted(val paths: List<String>) : MainEvent

    data class ScanProgress(
        val processed: Int,
        val total: Int,
        val statuses: Map<String, FileStatus>,
    ) : MainEvent

    data class ScanCompleted(val statuses: Map<String, FileStatus>) : MainEvent

    data class ScanFailed(
        val message: String,
        val paths: List<String>,
    ) : MainEvent

    // --- Settings dialog ---
    data object SettingsClicked : MainEvent

    data object SettingsDismissed : MainEvent

    data class SettingsSaved(val settings: AppSettings) : MainEvent

    data class SettingsTestConnection(val settings: AppSettings) : MainEvent

    // --- Connection (dispatched as the gateway flow progresses) ---
    data object ConnectClicked : MainEvent

    data object ConnectStarted : MainEvent

    data object ConnectSucceeded : MainEvent

    data class ConnectFailed(val message: String) : MainEvent

    data class ShowPassphrasePrompt(val showKeychainOption: Boolean) : MainEvent

    data class PassphraseEntered(val result: PassphraseResult) : MainEvent

    data object PassphraseDismissed : MainEvent

    // Results of the Activity-driven biometric load of a stored passphrase.
    data class PassphraseLoaded(val passphrase: String) : MainEvent

    data class PassphraseLoadFailed(val error: String) : MainEvent

    data object ShowS3Prompt : MainEvent

    data class S3CredentialsEntered(val result: S3CredentialsResult) : MainEvent

    data object S3CredentialsDismissed : MainEvent

    // --- Dialogs / misc ---
    data object ErrorDismissed : MainEvent

    data object StoragePermissionDismissed : MainEvent

    data object OpenStorageSettingsClicked : MainEvent
}
