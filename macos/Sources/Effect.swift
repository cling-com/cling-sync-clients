import Foundation

enum SettingKey: String, Equatable {
    case syncWorkers, autoMergeIntervalHours, notifyStaleDays, selectedSettingsTab
}

// A side effect the reducer requests and the store performs. Data, not calls, so
// the reducer stays pure and assertable (a test inspects reduction.effects; no IO
// runs). Workspace-scoped effects carry the id. Window/preferences *visibility* is
// NOT an effect: the reducer mutates AppState.openWindows / .preferencesOpen and
// the WindowCoordinator projects them. Bringing an already-open window to the FRONT
// is an effect, because a re-open click changes no state and so triggers no render.
enum Effect: Equatable {
    // Persistence
    case persistWorkspaces
    case persistMergeTracking
    case persistSetting(SettingKey, Int)

    // Operations (store runs the bridge start incl. passphrase prompts, then polls)
    case startOperation(id: UUID, kind: OperationKind, isAutoMerge: Bool)
    case cancelOperation(id: UUID, kind: OperationKind)
    case beginPolling(OperationKind)

    // Test / save flow (store orchestrates Prompter + gateway, dispatches terminal events)
    case runTestDraft(WorkspaceConfig)
    case chooseLocalDirectory

    // Read each folder's workspace refs/head mtime (the "Last Merge" display) into state
    case refreshMergeMtimes

    // Sync targets
    case loadSyncTargets(id: UUID)
    case promptAndAddSyncTarget(id: UUID)
    case removeSyncTarget(id: UUID, name: String)

    // Repository/keychain teardown + directory access
    case clearWorkspacePassphrase(uri: String)
    case activateDirectoryAccess(WorkspaceConfig)
    case deactivateDirectoryAccess(path: String)

    // Timers (store owns the Timer handles; the decision is pure)
    case rescheduleAutoMerge
    case rescheduleStaleCheck

    // Bring an already-open window to the front (re-open clicks change no state)
    case focusPreferences
    case focusProgressWindow(id: UUID, kind: OperationKind)

    // Fire-and-forget UI side effects
    case postNotification(id: UUID, title: String, body: String)
    case showAlert(title: String, message: String)
    case openLocalFolder(path: String)
    case quit
}

struct Reduction: Equatable {
    var state: AppState
    var effects: [Effect] = []
    static func only(_ state: AppState) -> Reduction { Reduction(state: state) }
}
