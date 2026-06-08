import Foundation

// A pure, Equatable projection of AppState into everything the tray menu shows,
// so the menu is rebuilt only when the menu-relevant state actually changes.
struct MenuSnapshot: Equatable {
    var isEmpty: Bool
    var isSingle: Bool
    var running: [RunningRow]
    var workspaces: [WorkspaceMenu]

    struct RunningRow: Equatable {
        let id: UUID
        let localPath: String
        let title: String
    }

    struct ItemState: Equatable {
        let title: String
        let enabled: Bool
    }

    struct WorkspaceMenu: Equatable {
        let id: UUID
        let displayName: String
        let detailText: String
        let localPath: String
        let lastMergeText: String
        let merge: ItemState
        let status: ItemState
        let sync: ItemState
    }
}

extension AppState {
    func menuSnapshot() -> MenuSnapshot {
        let sorted = workspaces.sorted {
            $0.config.displayName.localizedCaseInsensitiveCompare($1.config.displayName) == .orderedAscending
        }
        let running = sorted.filter(\.isBusy).map {
            MenuSnapshot.RunningRow(
                id: $0.id, localPath: $0.localPath,
                title: "\($0.config.displayName) - \($0.activeOperationLabel ?? "In progress")")
        }
        let items = sorted.map { workspace -> MenuSnapshot.WorkspaceMenu in
            let idle = !workspace.isBusy && !isTesting
            let mergeRunning = workspace.merge.isRunning
            let mergeFailed = workspace.merge.isTerminalFailure
            let mergeTitle = mergeRunning ? "Merge (in progress)" : (mergeFailed ? "Merge (failed)" : "Merge")
            let hasSyncTargets = workspace.syncTargets?.isEmpty == false
            return MenuSnapshot.WorkspaceMenu(
                id: workspace.id,
                displayName: workspace.config.displayName,
                detailText: workspace.config.detailText,
                localPath: workspace.localPath,
                lastMergeText: lastMergeText(workspace),
                merge: MenuSnapshot.ItemState(title: mergeTitle, enabled: mergeRunning || mergeFailed || idle),
                status: MenuSnapshot.ItemState(
                    title: workspace.status.isRunning ? "Status (in progress)" : "Status",
                    enabled: workspace.status.isRunning || idle),
                sync: MenuSnapshot.ItemState(
                    title: workspace.sync.isRunning ? "Sync Repository (in progress)" : "Sync Repository",
                    enabled: workspace.sync.isRunning || (hasSyncTargets && idle)))
        }
        return MenuSnapshot(
            isEmpty: workspaces.isEmpty, isSingle: workspaces.count == 1, running: running, workspaces: items)
    }
}
