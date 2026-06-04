package com.clingsync.android.presentation

// One-time actions only the Activity can perform: biometric prompts (need a
// FragmentActivity), the SAF directory picker and permission launchers, and
// settings intents. The ViewModel emits these; the Activity performs them and
// feeds results back as [MainEvent]s.
sealed interface ViewAction {
    data class LoadStoredPassphrase(val repositoryId: String) : ViewAction

    data class SavePassphrase(
        val passphrase: String,
        val repositoryId: String,
    ) : ViewAction

    data object RequestPermissions : ViewAction

    data object OpenStorageSettings : ViewAction
}
