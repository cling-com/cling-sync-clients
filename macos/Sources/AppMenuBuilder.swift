import AppKit

// Builds the tray NSMenu purely from a MenuSnapshot. All item identifiers and
// titles are part of the frozen XCUITest contract; do not rename them.
enum AppMenuBuilder {
    static func build(_ snapshot: MenuSnapshot, actions: MenuActions) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false

        if snapshot.isEmpty {
            let empty = NSMenuItem(title: "No folders configured", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for row in snapshot.running {
                let item = NSMenuItem(
                    title: row.title, action: #selector(MenuActions.openActiveProgress(_:)), keyEquivalent: "")
                item.target = actions
                item.representedObject = row.id.uuidString
                item.identifier = NSUserInterfaceItemIdentifier("workspace.progress.\(row.localPath)")
                item.image = NSImage(
                    systemSymbolName: "arrow.trianglehead.2.clockwise.circle.fill",
                    accessibilityDescription: "Operation in progress")
                menu.addItem(item)
            }
            if !snapshot.running.isEmpty { menu.addItem(.separator()) }

            if snapshot.isSingle, let workspace = snapshot.workspaces.first {
                appendWorkspaceItems(workspace, to: menu, actions: actions)
                menu.addItem(.separator())
            } else {
                for workspace in snapshot.workspaces {
                    let item = NSMenuItem(title: workspace.displayName, action: nil, keyEquivalent: "")
                    item.identifier = NSUserInterfaceItemIdentifier("workspace.menu.\(workspace.localPath)")
                    let submenu = NSMenu(title: workspace.displayName)
                    submenu.autoenablesItems = false
                    appendWorkspaceItems(workspace, to: submenu, actions: actions)
                    item.submenu = submenu
                    menu.addItem(item)
                }
            }
        }

        let settings = NSMenuItem(
            title: "Settings", action: #selector(MenuActions.openPreferences), keyEquivalent: ",")
        settings.target = actions
        menu.addItem(settings)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Cling Sync", action: #selector(MenuActions.quit), keyEquivalent: "q")
        quit.target = actions
        menu.addItem(quit)
        return menu
    }

    private static func appendWorkspaceItems(
        _ workspace: MenuSnapshot.WorkspaceMenu, to menu: NSMenu, actions: MenuActions
    ) {
        let pathItem = NSMenuItem(title: workspace.detailText, action: nil, keyEquivalent: "")
        pathItem.isEnabled = false
        menu.addItem(pathItem)

        let lastItem = NSMenuItem(title: workspace.lastMergeText, action: nil, keyEquivalent: "")
        lastItem.isEnabled = false
        lastItem.identifier = NSUserInterfaceItemIdentifier("workspace.last.\(workspace.localPath)")
        menu.addItem(lastItem)

        menu.addItem(.separator())

        menu.addItem(
            actionItem(
                workspace.merge, id: workspace.id, identifier: "workspace.merge.\(workspace.localPath)",
                selector: #selector(MenuActions.merge(_:)), actions: actions))
        menu.addItem(
            actionItem(
                workspace.status, id: workspace.id, identifier: "workspace.status.\(workspace.localPath)",
                selector: #selector(MenuActions.status(_:)), actions: actions))
        menu.addItem(
            actionItem(
                workspace.sync, id: workspace.id, identifier: "workspace.sync.\(workspace.localPath)",
                selector: #selector(MenuActions.sync(_:)), actions: actions))

        let openItem = NSMenuItem(
            title: "Open Local Folder", action: #selector(MenuActions.openFolder(_:)), keyEquivalent: "")
        openItem.target = actions
        openItem.representedObject = workspace.id.uuidString
        openItem.identifier = NSUserInterfaceItemIdentifier("workspace.open-folder.\(workspace.localPath)")
        menu.addItem(openItem)
    }

    private static func actionItem(
        _ state: MenuSnapshot.ItemState, id: UUID, identifier: String, selector: Selector, actions: MenuActions
    ) -> NSMenuItem {
        let item = NSMenuItem(title: state.title, action: selector, keyEquivalent: "")
        item.target = actions
        item.representedObject = id.uuidString
        item.isEnabled = state.enabled
        item.identifier = NSUserInterfaceItemIdentifier(identifier)
        return item
    }
}

// Routes menu clicks into the store. A running-summary or operation click opens the
// window or starts the op (the reducer decides); the rest map straight to events.
@MainActor
@objc
final class MenuActions: NSObject {
    private unowned let store: AppStore

    init(store: AppStore) {
        self.store = store
        super.init()
    }

    private func workspaceID(_ sender: NSMenuItem) -> UUID? {
        (sender.representedObject as? String).flatMap(UUID.init)
    }

    @objc func openActiveProgress(_ sender: NSMenuItem) {
        guard let id = workspaceID(sender), let kind = store.state.workspace(id)?.runningKind else { return }
        store.dispatch(.operationClicked(id: id, kind: kind))
    }

    @objc func merge(_ sender: NSMenuItem) {
        guard let id = workspaceID(sender) else { return }
        store.dispatch(.operationClicked(id: id, kind: .merge))
    }

    @objc func status(_ sender: NSMenuItem) {
        guard let id = workspaceID(sender) else { return }
        store.dispatch(.operationClicked(id: id, kind: .status))
    }

    @objc func sync(_ sender: NSMenuItem) {
        guard let id = workspaceID(sender) else { return }
        store.dispatch(.operationClicked(id: id, kind: .sync))
    }

    @objc func openFolder(_ sender: NSMenuItem) {
        guard let id = workspaceID(sender) else { return }
        store.dispatch(.openLocalFolderClicked(id: id))
    }

    @objc func openPreferences() {
        store.dispatch(.openPreferencesClicked)
    }

    @objc func quit() {
        store.dispatch(.quitClicked)
    }
}
