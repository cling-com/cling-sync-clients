import AppKit

@MainActor
struct AppMenuBuilder {
    unowned let controller: AppController

    private enum MenuItemID {
        static func workspace(_ workspace: WorkspaceConfig) -> NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier("workspace.menu.\(workspace.normalizedLocalDirectory)")
        }

        static func status(_ workspace: WorkspaceConfig) -> NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier("workspace.status.\(workspace.normalizedLocalDirectory)")
        }

        static func merge(_ workspace: WorkspaceConfig) -> NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier("workspace.merge.\(workspace.normalizedLocalDirectory)")
        }

        static func sync(_ workspace: WorkspaceConfig) -> NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier("workspace.sync.\(workspace.normalizedLocalDirectory)")
        }

        static func progress(_ workspace: WorkspaceConfig) -> NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier("workspace.progress.\(workspace.normalizedLocalDirectory)")
        }

        static func openFolder(_ workspace: WorkspaceConfig) -> NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier("workspace.open-folder.\(workspace.normalizedLocalDirectory)")
        }

    }

    func buildRootMenu() -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        if controller.workspaceConfigs.isEmpty {
            let emptyItem = NSMenuItem(title: "No folders configured", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            let runningWorkspaces = controller.workspaceConfigs
                .filter { controller.isBusy($0) }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

            for workspace in runningWorkspaces {
                let label = controller.activeOperationLabel(for: workspace) ?? "In progress"
                let progressItem = NSMenuItem(
                    title: "\(workspace.displayName) - \(label)",
                    action: #selector(AppController.handleOpenActiveProgress(_:)),
                    keyEquivalent: "",
                )
                progressItem.target = controller
                progressItem.representedObject = workspace.id.uuidString
                progressItem.identifier = MenuItemID.progress(workspace)
                progressItem.image = NSImage(
                    systemSymbolName: "arrow.trianglehead.2.clockwise.circle.fill",
                    accessibilityDescription: "Operation in progress",
                )
                menu.addItem(progressItem)
            }

            if !runningWorkspaces.isEmpty {
                menu.addItem(.separator())
            }

            let workspaces = controller.workspaceConfigs.sorted(by: {
                $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            })
            if workspaces.count == 1, let workspace = workspaces.first {
                appendWorkspaceItems(for: workspace, to: menu)
                menu.addItem(.separator())
            } else {
                for workspace in workspaces {
                    let item = NSMenuItem(
                        title: workspace.displayName,
                        action: nil,
                        keyEquivalent: ""
                    )
                    item.identifier = MenuItemID.workspace(workspace)
                    item.submenu = buildWorkspaceMenu(for: workspace)
                    menu.addItem(item)
                }
            }

        }

        let manageItem = NSMenuItem(
            title: "Settings",
            action: #selector(AppController.handleOpenPreferences),
            keyEquivalent: ",",
        )
        manageItem.target = controller
        menu.addItem(manageItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(
            title: "Quit Cling Sync",
            action: #selector(AppController.handleQuit),
            keyEquivalent: "q",
        )
        quitItem.target = controller
        menu.addItem(quitItem)

        return menu
    }

    func buildWorkspaceMenu(for workspace: WorkspaceConfig) -> NSMenu {
        let menu = NSMenu(title: workspace.displayName)
        menu.autoenablesItems = false

        appendWorkspaceItems(for: workspace, to: menu)
        return menu
    }

    private func appendWorkspaceItems(for workspace: WorkspaceConfig, to menu: NSMenu) {
        let pathItem = NSMenuItem(title: workspace.detailText, action: nil, keyEquivalent: "")
        pathItem.isEnabled = false
        menu.addItem(pathItem)
        menu.addItem(.separator())

        // Each operation's own item carries its "(in progress)" label and stays
        // clickable (to reopen its window) while it runs; the other operations
        // are disabled so they cannot start concurrently.
        let mergeRunning = controller.mergeStatus(for: workspace).running
        let statusRunning = controller.statusStatus(for: workspace).running
        let syncRunning = controller.syncStatus(for: workspace).running
        let idle = !controller.isBusy(workspace) && !controller.isSaving && !controller.isTesting

        let mergeItem = NSMenuItem(
            title: mergeRunning ? "Merge (in progress)" : "Merge",
            action: #selector(AppController.handleMergeWorkspace(_:)),
            keyEquivalent: "",
        )
        mergeItem.target = controller
        mergeItem.representedObject = workspace.id.uuidString
        mergeItem.isEnabled = mergeRunning || idle
        mergeItem.identifier = MenuItemID.merge(workspace)
        menu.addItem(mergeItem)

        let statusItem = NSMenuItem(
            title: statusRunning ? "Status (in progress)" : "Status",
            action: #selector(AppController.handleStatusWorkspace(_:)),
            keyEquivalent: "",
        )
        statusItem.target = controller
        statusItem.representedObject = workspace.id.uuidString
        statusItem.isEnabled = statusRunning || idle
        statusItem.identifier = MenuItemID.status(workspace)
        menu.addItem(statusItem)

        let hasSyncTargets = !controller.syncTargets(for: workspace).isEmpty
        let syncItem = NSMenuItem(
            title: syncRunning ? "Sync Repository (in progress)" : "Sync Repository",
            action: #selector(AppController.handleSyncWorkspace(_:)),
            keyEquivalent: "",
        )
        syncItem.target = controller
        syncItem.representedObject = workspace.id.uuidString
        syncItem.isEnabled = syncRunning || (hasSyncTargets && idle)
        syncItem.identifier = MenuItemID.sync(workspace)
        menu.addItem(syncItem)

        let openFolderItem = NSMenuItem(
            title: "Open Local Folder",
            action: #selector(AppController.handleOpenWorkspaceFolder(_:)),
            keyEquivalent: "",
        )
        openFolderItem.target = controller
        openFolderItem.representedObject = workspace.id.uuidString
        openFolderItem.identifier = MenuItemID.openFolder(workspace)
        menu.addItem(openFolderItem)
    }
}
