import Foundation

// Flat enum; workspace-scoped cases carry the id (store resolves it before
// reducing). Prompts are NOT events: the store runs the Prompter, then dispatches
// the resulting completion event. Events that write a timestamp carry `now: Date`
// so the reducer stays clock-free.
enum AppEvent: Equatable {
    // Launch
    case stateLoaded(workspaces: [WorkspaceConfig], tracking: MergeTracking, settings: AppSettings, now: Date)

    // Workspace list
    case addWorkspaceClicked
    case workspaceSelected(id: UUID?)
    case removeWorkspaceClicked(id: UUID)

    // Preferences / draft
    case draftAccessEdited(WorkspaceConfig, now: Date)  // host/path/prefix edited
    case draftMetadataEdited(WorkspaceConfig, now: Date)  // author edited
    case chooseLocalDirectoryClicked
    case chooseLocalDirectoryCompleted(draft: WorkspaceConfig, inspectionError: String?, now: Date)
    case settingsTabSelected(Int)
    case syncTargetSelected(name: String?)
    case openPreferencesClicked
    case closePreferencesClicked
    case openLocalFolderClicked(id: UUID)

    // Test / save
    case testDraftClicked
    case testDraftSucceeded(verified: WorkspaceConfig, now: Date)
    case testDraftCancelled
    case testDraftFailed(message: String)
    case saveDraftClicked(now: Date)

    // Operations
    case operationClicked(id: UUID, kind: OperationKind)  // menu/host: open-window-or-start
    case operationStartRequested(id: UUID, kind: OperationKind, presentWindow: Bool, isAutoMerge: Bool)
    case operationStartFailed(id: UUID, kind: OperationKind, message: String, isNetwork: Bool, isAutoMerge: Bool)
    case operationStartCancelled(id: UUID, kind: OperationKind)
    case cancelClicked(id: UUID, kind: OperationKind)
    case workUpdated(id: UUID, kind: OperationKind, update: WorkUpdate, now: Date)
    case detailsToggled(id: UUID, kind: OperationKind, show: Bool)
    case openProgressWindowRequested(id: UUID, kind: OperationKind)
    case progressWindowClosed(id: UUID, kind: OperationKind)

    // Sync targets
    case syncTargetsLoaded(id: UUID, targets: [SyncTargetInfo]?)
    case addSyncTargetClicked
    case syncTargetAdded(id: UUID)
    case removeSyncTargetClicked
    case syncTargetRemoved(id: UUID)
    case syncTargetActionFailed(title: String, message: String)

    // Settings
    case syncWorkersChanged(Int)
    case autoMergeIntervalChanged(Int)
    case notifyStaleDaysChanged(Int)

    // Timers
    case autoMergeTimerFired(now: Date)
    case staleCheckTimerFired(now: Date)
    case testReminderRequested  // debug: force a reminder notification for every folder
    case mergeMtimesRefreshed([UUID: Date])  // workspace refs/head mtimes read from disk by the store

    // App
    case quitClicked
}
