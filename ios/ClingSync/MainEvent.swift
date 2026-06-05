import Foundation

// Everything that can change the screen: user intents and internal completions
// (file loads, scan progress, connection results). The store translates
// permission/upload/connect callbacks into these. Passphrase and S3 prompts are
// resolved via continuations in the store, so they are not events here.
enum MainEvent {
    // --- File list & selection ---
    case fileSelectionChanged(id: String, selected: Bool)
    case selectAllClicked
    case deselectAllClicked
    case searchQueryChanged(String)
    case searchToggled
    // The clear-X inside the search field resets the query only, keeping the
    // current selection (unlike editing the query, which clears it).
    case searchCleared
    case refreshClicked

    // --- Upload ---
    case uploadClicked
    case abortClicked

    // --- File loading ---
    case loadingStarted
    case filesLoaded([SourceFile])

    // --- Scanning ---
    case scanStarted(ids: [String])
    case scanProgress(processed: Int, total: Int, statuses: [String: FileStatus])
    case scanCompleted(statuses: [String: FileStatus])
    case scanFailed(message: String, ids: [String])

    // --- Settings ---
    case settingsClicked
    case settingsDismissed
    case settingsSaved(RepositoryConfiguration)

    // --- Connection (dispatched as the gateway flow progresses) ---
    case connectClicked
    case connectStarted
    case connectSucceeded
    case connectFailed(String)

    // --- Overlay ---
    case errorDismissed
}
