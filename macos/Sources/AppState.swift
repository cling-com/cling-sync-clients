import Foundation

// A progress window the projection should keep open. Closing one removes the key
// but NEVER touches OperationState (Bug C fix).
struct WindowKey: Hashable, Equatable {
    let workspaceID: UUID
    let kind: OperationKind
}

// The whole menu-bar app as one immutable Equatable value. No AppKit, no bridge,
// no clock. Every menu/tray/window/preferences value is stored here or computed.
struct AppState: Equatable {
    var workspaces: [WorkspaceState] = []
    var selectedWorkspaceID: UUID?
    var draftConfig = WorkspaceConfig()
    var selectedSyncTargetName: String?

    var syncWorkers = 2
    var autoMergeIntervalHours = 0
    var notifyStaleDays = 0
    var selectedSettingsTab = 0

    var isTesting = false
    var lastResultMessage = ""
    var errorMessage = ""

    // The projection's desired-open set (drives WindowCoordinator) + whether the
    // preferences window is open.
    var openWindows: Set<WindowKey> = []
    var preferencesOpen = false

    // MARK: - Lookup

    func workspace(_ id: UUID) -> WorkspaceState? { workspaces.first { $0.id == id } }
    func index(_ id: UUID) -> Int? { workspaces.firstIndex { $0.id == id } }
    var selectedSavedWorkspace: WorkspaceState? {
        guard let selectedWorkspaceID else { return nil }
        return workspace(selectedWorkspaceID)
    }

    // MARK: - Running

    var hasActiveMerges: Bool { workspaces.contains { $0.merge.isRunning } }
    var hasActiveStatuses: Bool { workspaces.contains { $0.status.isRunning } }
    var hasActiveSyncs: Bool { workspaces.contains { $0.sync.isRunning } }
    var anyOperationRunning: Bool { workspaces.contains { $0.isBusy } }
    func hasRunning(_ kind: OperationKind) -> Bool { workspaces.contains { $0.operation(kind).isRunning } }

    var runningOperationLabels: [String] {
        var labels: [String] = []
        for workspace in workspaces {
            if workspace.merge.isRunning { labels.append(OperationKind.merge.label) }
            if workspace.sync.isRunning { labels.append(OperationKind.sync.label) }
            if workspace.status.isRunning { labels.append(OperationKind.status.label) }
        }
        return labels
    }

    var trayTooltip: String {
        let labels = runningOperationLabels
        switch labels.count {
        case 0: return "Cling Sync"
        case 1: return "\(labels[0]) in progress"
        default: return "\(labels.count) operations in progress"
        }
    }

    // Mirrors the old updateStatusMessage precedence exactly. hasActiveMerges
    // replaces the old stored isMerging (which was always == hasActiveMerges).
    var statusMessage: String {
        if let workspace = workspaces.first(where: { $0.merge.isRunning }) {
            let text = workspace.merge.statusMessage.isEmpty ? lastMergeText(workspace) : workspace.merge.statusMessage
            return "\(workspace.config.displayName): \(text)"
        }
        if hasActiveMerges { return "Merging..." }
        if isTesting { return "Testing..." }
        if !lastResultMessage.isEmpty { return lastResultMessage }
        if workspaces.isEmpty { return "Setup required" }
        if workspaces.count == 1, let workspace = workspaces.first { return workspace.config.displayName }
        return "\(workspaces.count) folders"
    }

    // The "Last Merge: 5m ago" / "never" text. Reads the workspace refs/head mtime
    // (lastMergeMtime), so a folder merged by another device or before this app opened
    // it shows its real recency. A display helper read by the projection; the reducer
    // never calls it (so the reducer stays clock-free).
    func lastMergeText(_ workspace: WorkspaceState) -> String {
        guard let date = workspace.lastMergeMtime else { return "Last Merge: never" }
        return "Last Merge: \(AutoMergePolicy.coarseAge(Date().timeIntervalSince(date))) ago"
    }

    // MARK: - Draft gates

    var canSaveDraft: Bool {
        selectedWorkspaceID != nil && draftConfig.isValidForSave && !isTesting
    }
    var canTestDraft: Bool {
        selectedWorkspaceID != nil && draftConfig.isReadyForTest && !isTesting
    }
    var draftNeedsTest: Bool {
        selectedWorkspaceID != nil && draftConfig.isReadyForTest && !draftConfig.isAccessVerified
    }

    // MARK: - Auto-merge

    var autoMergeBackoffActive: Bool { workspaces.contains { $0.inNetworkBackoff } }
}
