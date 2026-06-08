import Foundation

// The three per-workspace operations. Parameterizes the unified operation state,
// progress view, and menu items so merge/status/sync share one code path.
enum OperationKind: String, CaseIterable, Equatable {
    case merge, status, sync

    // The progress-window title suffix: "<name> Merge" etc.
    var windowTitleSuffix: String {
        switch self {
        case .merge: return "Merge"
        case .status: return "Status"
        case .sync: return "Sync"
        }
    }

    // The running-tooltip label and menu running-row label.
    var label: String {
        switch self {
        case .merge: return "Merge"
        case .status: return "Status"
        case .sync: return "Sync"
        }
    }

    var runningLabel: String { "\(label) (in progress)" }

    // The NSAlert title for a manual terminal failure.
    var failureAlertTitle: String { "\(label) Failed" }

    // The NSAlert title when the cancel/abort request itself fails (sync says "Abort").
    var cancelFailureAlertTitle: String {
        switch self {
        case .merge: return "Cancel Merge Failed"
        case .status: return "Cancel Status Failed"
        case .sync: return "Abort Sync Failed"
        }
    }
}
