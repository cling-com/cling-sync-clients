import AppKit

@MainActor
struct AppMenuBuilder {
    unowned let controller: AppController

    private enum MenuItemID {
        static func workspace(_ workspace: WorkspaceConfig) -> NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier("workspace.menu.\(workspace.normalizedLocalDirectory)")
        }

        static func merge(_ workspace: WorkspaceConfig) -> NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier("workspace.merge.\(workspace.normalizedLocalDirectory)")
        }

        static func openFolder(_ workspace: WorkspaceConfig) -> NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier("workspace.open-folder.\(workspace.normalizedLocalDirectory)")
        }

        static func edit(_ workspace: WorkspaceConfig) -> NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier("workspace.edit.\(workspace.normalizedLocalDirectory)")
        }

        static func remove(_ workspace: WorkspaceConfig) -> NSUserInterfaceItemIdentifier {
            NSUserInterfaceItemIdentifier("workspace.remove.\(workspace.normalizedLocalDirectory)")
        }
    }

    func buildRootMenu() -> NSMenu {
        let menu = NSMenu()

        if controller.workspaceConfigs.isEmpty {
            let emptyItem = NSMenuItem(title: "No folders configured", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            let runningWorkspaces = controller.workspaceConfigs
                .filter { controller.mergeStatus(for: $0).running }
                .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }

            for workspace in runningWorkspaces {
                let progressItem = NSMenuItem(
                    title: "\(workspace.displayName) - \(controller.mergeStatusText(for: workspace))",
                    action: #selector(AppController.handleOpenMergeProgress(_:)),
                    keyEquivalent: "",
                )
                progressItem.target = controller
                progressItem.representedObject = workspace.id.uuidString
                progressItem.image = NSImage(
                    systemSymbolName: "arrow.trianglehead.2.clockwise.circle.fill",
                    accessibilityDescription: "Merge in progress",
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
            title: "Manage Folders...",
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

        appendWorkspaceItems(for: workspace, to: menu)
        return menu
    }

    private func appendWorkspaceItems(for workspace: WorkspaceConfig, to menu: NSMenu) {
        let pathItem = NSMenuItem(title: workspace.detailText, action: nil, keyEquivalent: "")
        pathItem.isEnabled = false
        menu.addItem(pathItem)
        menu.addItem(.separator())

        if !controller.mergeStatus(for: workspace).running {
            let mergeItem = NSMenuItem(
                title: "Merge Now",
                action: #selector(AppController.handleMergeWorkspace(_:)),
                keyEquivalent: "",
            )
            mergeItem.target = controller
            mergeItem.representedObject = workspace.id.uuidString
            mergeItem.isEnabled = !controller.isSaving && !controller.isTesting
            mergeItem.identifier = MenuItemID.merge(workspace)
            menu.addItem(mergeItem)
        }

        let openFolderItem = NSMenuItem(
            title: "Open Local Folder",
            action: #selector(AppController.handleOpenWorkspaceFolder(_:)),
            keyEquivalent: "",
        )
        openFolderItem.target = controller
        openFolderItem.representedObject = workspace.id.uuidString
        openFolderItem.identifier = MenuItemID.openFolder(workspace)
        menu.addItem(openFolderItem)

        let editItem = NSMenuItem(
            title: "Edit...",
            action: #selector(AppController.handleEditWorkspace(_:)),
            keyEquivalent: "",
        )
        editItem.target = controller
        editItem.representedObject = workspace.id.uuidString
        editItem.identifier = MenuItemID.edit(workspace)
        menu.addItem(editItem)

        let removeItem = NSMenuItem(
            title: "Remove Folder",
            action: #selector(AppController.handleRemoveWorkspace(_:)),
            keyEquivalent: "",
        )
        removeItem.target = controller
        removeItem.representedObject = workspace.id.uuidString
        removeItem.identifier = MenuItemID.remove(workspace)
        menu.addItem(removeItem)
    }
}
