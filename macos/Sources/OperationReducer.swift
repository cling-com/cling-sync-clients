import Foundation

// Folds one normalized poll/start update into a workspace's operation state. Two
// invariants live here: a terminal state stays sticky against a late empty poll
// (Bug B), and completion side effects (record success, auto-merge notify vs
// alert) fire exactly once on the transition into a terminal state.
enum OperationReducer {
    // swiftlint:disable:next cyclomatic_complexity
    static func fold(_ state: AppState, id: UUID, kind: OperationKind, update: WorkUpdate, now: Date) -> Reduction {
        var state = state
        var effects: [Effect] = []
        guard let index = state.index(id) else { return Reduction(state: state) }
        let previous = state.workspaces[index].operation(kind)

        // Resolve the next state, keeping a terminal phase sticky (Bug B): the old
        // pollers wholesale-replaced the map and filtered empty rows, dropping a
        // terminal failure whose bridge slot had been cleared.
        let next: OperationState
        switch update {
        case .absent:
            if previous.isFinished { return Reduction(state: state) }
            next = .idle
        case .snapshot(let snapshot):
            if snapshot == .idle, previous.isTerminalFailure { return Reduction(state: state) }
            next = snapshot
        }
        state.workspaces[index].setOperation(kind, next)

        // Route only on the transition into a terminal state (the old
        // previous.running || previous.statusMessage != status.statusMessage guard).
        let transitioned = previous.isRunning || previous.statusMessage != next.statusMessage
        guard transitioned, next.isFinished else { return Reduction(state: state, effects: effects) }

        let name = state.workspaces[index].config.displayName
        if kind == .merge {
            if case .finished(.completed) = next {
                AppReducer.recordSuccessfulMerge(&state, &effects, id: id, now: now)
            }
            if state.workspaces[index].isAutoMerge {
                state.workspaces[index].isAutoMerge = false
                handleAutoMergeCompletion(&state, &effects, id: id, name: name, outcome: next)
            } else if case .finished(.failed(let message, _, _)) = next {
                effects.append(.showAlert(title: OperationKind.merge.failureAlertTitle, message: message))
            }
        } else if case .finished(.failed(let message, _, _)) = next {
            effects.append(.showAlert(title: kind.failureAlertTitle, message: message))
        }
        state.lastResultMessage = "\(name): \(next.statusMessage)"
        return Reduction(state: state, effects: effects)
    }

    // A background merge routes its completion to a notification, never a modal
    // alert: up-to-date and cancelled stay silent; a network failure is silent
    // (retried via backoff); other outcomes notify.
    private static func handleAutoMergeCompletion(
        _ state: inout AppState, _ effects: inout [Effect], id: UUID, name: String, outcome: OperationState
    ) {
        switch outcome {
        case .finished(.failed(let message, _, let isNetwork)):
            AppReducer.setNetworkBackoff(&state, &effects, id: id, active: isNetwork)
            if !isNetwork {
                effects.append(.postNotification(id: id, title: "Automatic merge failed", body: message))
            }
        case .finished(.cancelled):
            break
        case .finished(.completed(let message, _, _, let upToDate)):
            guard !upToDate else { break }
            effects.append(.postNotification(id: id, title: "Automatic merge complete", body: "\(name): \(message)"))
        default:
            break
        }
    }
}
