import Foundation

// All state for one folder<->repo workspace, collapsing the per-path dicts of the
// old AppController into one Equatable value keyed inside AppState by `id`.
struct WorkspaceState: Equatable, Identifiable {
    var config: WorkspaceConfig
    var id: UUID { config.id }

    var merge: OperationState = .idle
    var status: OperationState = .idle
    var sync: OperationState = .idle

    var mergeShowsDetails = false
    var statusShowsDetails = false
    var syncShowsDetails = false

    // nil = sync targets not yet read (the old isWorkspaceConfigured nil-vs-present
    // sentinel). [] = read, configured, no targets.
    var syncTargets: [SyncTargetInfo]?

    // The "Last Merge" DISPLAY value: the mtime of the workspace's refs/head on disk
    // (read by the store, not persisted), nil when the head is still the root revision
    // (never merged). Reflects real recency, including a folder merged by another
    // device before this app ever opened it.
    var lastMergeMtime: Date?

    // App-recorded successful merge, kept as the staleness reference + persisted.
    var lastSuccessfulMerge: Date?
    var firstTracked: Date?  // staleness clock for a never-merged folder
    var lastStaleNotified: Date?

    var inNetworkBackoff = false  // last auto-merge hit a connectivity error
    var isAutoMerge = false  // current merge was scheduler-started -> notify, not alert

    var localPath: String { config.normalizedLocalDirectory }

    func operation(_ kind: OperationKind) -> OperationState {
        switch kind {
        case .merge: return merge
        case .status: return status
        case .sync: return sync
        }
    }

    func showsDetails(_ kind: OperationKind) -> Bool {
        switch kind {
        case .merge: return mergeShowsDetails
        case .status: return statusShowsDetails
        case .sync: return syncShowsDetails
        }
    }

    mutating func setOperation(_ kind: OperationKind, _ value: OperationState) {
        switch kind {
        case .merge: merge = value
        case .status: status = value
        case .sync: sync = value
        }
    }

    mutating func setShowsDetails(_ kind: OperationKind, _ value: Bool) {
        switch kind {
        case .merge: mergeShowsDetails = value
        case .status: statusShowsDetails = value
        case .sync: syncShowsDetails = value
        }
    }

    var isBusy: Bool { merge.isRunning || status.isRunning || sync.isRunning }

    // merge > sync > status priority.
    var runningKind: OperationKind? {
        if merge.isRunning { return .merge }
        if sync.isRunning { return .sync }
        if status.isRunning { return .status }
        return nil
    }

    var activeOperationLabel: String? { runningKind?.runningLabel }
    var isConfigured: Bool { syncTargets != nil }
    var lastMergeReference: Date? { lastSuccessfulMerge ?? firstTracked }
}
