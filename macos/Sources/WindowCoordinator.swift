import SwiftUI

// Lets the store bring an already-open window to the front (a re-open click changes
// no state, so it cannot ride on render).
@MainActor
protocol WindowFronting: AnyObject {
    func focusPreferences()
    func focusProgressWindow(id: UUID, kind: OperationKind)
}

// Projects AppState.openWindows + .preferencesOpen onto real NSWindows: opens the
// new ones, closes the gone ones. The hosted SwiftUI views observe the store, so
// existing windows self-update; the coordinator only opens/closes. Closing via the
// titlebar folds back through the reducer (so a running op is never stranded).
@MainActor
final class WindowCoordinator: NSObject, NSWindowDelegate, WindowFronting {
    private unowned let store: AppStore
    private var progressWindows: [WindowKey: NSWindow] = [:]
    private var preferencesWindow: NSWindow?

    init(store: AppStore) {
        self.store = store
        super.init()
    }

    func render(_ state: AppState) {
        for key in state.openWindows where progressWindows[key] == nil {
            openProgressWindow(key)
        }
        for (key, window) in progressWindows where !state.openWindows.contains(key) {
            progressWindows[key] = nil
            window.delegate = nil
            window.close()
        }
        // Keep titles fresh when a still-open workspace is renamed.
        for (key, window) in progressWindows {
            if let workspace = state.workspace(key.workspaceID) {
                window.title = "\(workspace.config.displayName) \(key.kind.windowTitleSuffix)"
            }
        }

        if state.preferencesOpen, preferencesWindow == nil {
            openPreferences()
        } else if !state.preferencesOpen, let window = preferencesWindow {
            preferencesWindow = nil
            window.delegate = nil
            window.close()
        }
    }

    private func openProgressWindow(_ key: WindowKey) {
        guard let workspace = store.state.workspace(key.workspaceID) else { return }
        let view = OperationProgressView(store: store, workspaceID: key.workspaceID, kind: key.kind)
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "\(workspace.config.displayName) \(key.kind.windowTitleSuffix)"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 760, height: 420))
        window.minSize = NSSize(width: 640, height: 320)
        window.center()
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.delegate = self
        progressWindows[key] = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func openPreferences() {
        let window = NSWindow(contentViewController: NSHostingController(rootView: PreferencesView(store: store)))
        window.title = "Cling Sync Settings"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 880, height: 560))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        preferencesWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func focusPreferences() {
        bringToFront(preferencesWindow)
    }

    func focusProgressWindow(id: UUID, kind: OperationKind) {
        bringToFront(progressWindows[WindowKey(workspaceID: id, kind: kind)])
    }

    // No-op when the window isn't open yet; render() opens (and fronts) it instead.
    private func bringToFront(_ window: NSWindow?) {
        guard let window else { return }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        if window === preferencesWindow {
            preferencesWindow = nil
            store.dispatch(.closePreferencesClicked)
            return
        }
        if let key = progressWindows.first(where: { $0.value === window })?.key {
            progressWindows[key] = nil
            store.dispatch(.progressWindowClosed(id: key.workspaceID, kind: key.kind))
        }
    }
}
