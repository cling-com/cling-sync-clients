package com.clingsync.android.presentation

import com.clingsync.android.AppSettings

// A side effect the reducer requests and the ViewModel performs. Keeping these
// as data (rather than calling out directly) is what lets the reducers stay pure
// and assertable: a test checks `reduction.effects`, no IO runs.
sealed interface Effect {
    data class EnqueueUpload(val paths: List<String>, val author: String) : Effect

    data object CancelUpload : Effect

    data class PersistSettings(val settings: AppSettings) : Effect

    // Drop the stored passphrase + encoded URI of a repository we navigated away from.
    data class InvalidateRepository(val repositoryId: String) : Effect

    data object LoadFiles : Effect

    // Open the repository (the ViewModel drives the passphrase/S3 dialogs + gateway).
    data object Connect : Effect

    data object OpenStorageSettings : Effect
}

data class Reduction(
    val state: MainUiState,
    val effects: List<Effect> = emptyList(),
)
