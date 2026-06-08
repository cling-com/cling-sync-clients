import Foundation

// One workspace operation's lifecycle, unifying the two bridge flag-structs
// (MergeWorkspaceStatus / StatusWorkspaceStatus). An enum so illegal combos
// (running AND completed) are unrepresentable and a terminal phase can be made
// sticky against a late empty poll (Bug B).
enum OperationState: Equatable {
    case idle
    case running(message: String, detail: String, canCancel: Bool)
    case finished(Outcome)

    enum Outcome: Equatable {
        case completed(message: String, detail: String, revisionId: String, upToDate: Bool)
        case cancelled(message: String, detail: String)
        case failed(message: String, detail: String, isNetwork: Bool)
    }

    var isRunning: Bool {
        if case .running = self { return true }
        return false
    }
    var isFinished: Bool {
        if case .finished = self { return true }
        return false
    }
    var isTerminalFailure: Bool {
        if case .finished(.failed) = self { return true }
        return false
    }
    var ranSuccessfully: Bool {
        if case .finished(.completed) = self { return true }
        return false
    }
    var canCancel: Bool {
        if case .running(_, _, let canCancel) = self { return canCancel }
        return false
    }

    // The live one-liner for menu/window header/testStatusLabel. Empty for idle.
    var statusMessage: String {
        switch self {
        case .idle: return ""
        case .running(let message, _, _): return message
        case .finished(.completed(let message, _, _, _)): return message
        case .finished(.cancelled(let message, _)): return message
        case .finished(.failed(let message, _, _)): return message
        }
    }

    var detailedOutput: String {
        switch self {
        case .idle: return ""
        case .running(_, let detail, _): return detail
        case .finished(.completed(_, let detail, _, _)): return detail
        case .finished(.cancelled(_, let detail)): return detail
        case .finished(.failed(_, let detail, _)): return detail
        }
    }

    // Non-empty only in the terminal failed state; drives the red error label and
    // the "(failed)" menu suffix.
    var errorMessage: String {
        if case .finished(.failed(let message, _, _)) = self { return message }
        return ""
    }
}

extension OperationState {
    // Maps a unified bridge poll snapshot. running wins over completed;
    // completed+error -> .failed, completed+cancelled -> .cancelled. (The empty-row
    // case is handled by the caller via OperationProgress.isEmptyRow -> .absent.)
    static func from(_ progress: OperationProgress) -> OperationState {
        if progress.running {
            return .running(
                message: progress.statusMessage, detail: progress.detailedOutput, canCancel: progress.canCancel)
        }
        if progress.completed {
            if !progress.errorMessage.isEmpty {
                return .finished(
                    .failed(
                        message: progress.errorMessage, detail: progress.detailedOutput,
                        isNetwork: progress.errorIsNetwork))
            }
            if progress.cancelled {
                return .finished(.cancelled(message: progress.statusMessage, detail: progress.detailedOutput))
            }
            return .finished(
                .completed(
                    message: progress.statusMessage, detail: progress.detailedOutput,
                    revisionId: progress.revisionId, upToDate: progress.upToDate))
        }
        return .idle
    }
}
