import AppKit
import Combine
import UserNotifications

// The thin AppKit shell: owns the store and renders it (tray icon + menu, windows,
// test host) whenever state changes. All behavior lives in the store/reducer.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let store = AppStore()
    private lazy var menuActions = MenuActions(store: store)
    private lazy var windowCoordinator = WindowCoordinator(store: store)
    private var statusItem: NSStatusItem?
    private var trayAnimator: TrayIconAnimator?
    private var stateCancellable: AnyCancellable?
    private var lastMenuSnapshot: MenuSnapshot?

    private var testMenuHostWindow: NSWindow?
    private var testStatusLabel: NSTextField?

    private var isTestMode: Bool { ProcessInfo.processInfo.environment["CLING_SYNC_TEST_MENU_HOST"] == "1" }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let image = NSImage(named: "AppIcon") { NSApp.applicationIconImage = image }
        UNUserNotificationCenter.current().delegate = self
        store.windowFronter = windowCoordinator
        setupStatusItem()
        if isTestMode { showTestMenuHost() }
        // store.$state fires in willSet (before the property is assigned), so defer a
        // tick to read the committed state.
        stateCancellable = store.$state
            .receive(on: RunLoop.main)
            .sink { [weak self] state in self?.render(state) }
        store.onStart()
    }

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let idleImage = trayIconImage()
        item.button?.image = idleImage
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "Cling Sync"
        item.button?.setAccessibilityLabel("Cling Sync")
        statusItem = item
        trayAnimator = TrayIconAnimator(button: item.button, idleImage: idleImage)
    }

    private func render(_ state: AppState) {
        let snapshot = state.menuSnapshot()
        if snapshot != lastMenuSnapshot {
            lastMenuSnapshot = snapshot
            statusItem?.menu = AppMenuBuilder.build(snapshot, actions: menuActions)
        }
        trayAnimator?.setAnimating(state.anyOperationRunning)
        statusItem?.button?.toolTip = state.trayTooltip
        statusItem?.button?.setAccessibilityLabel(state.trayTooltip)
        windowCoordinator.render(state)
        testStatusLabel?.stringValue = state.statusMessage
        testStatusLabel?.setAccessibilityLabel(state.statusMessage)
    }

    private func trayIconImage() -> NSImage? {
        guard let image = NSImage(named: "AppIcon") else {
            return NSImage(systemSymbolName: "arrow.trianglehead.2.clockwise", accessibilityDescription: "Cling Sync")
        }
        let size = NSSize(width: 18, height: 18)
        let rounded = NSImage(size: size)
        rounded.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        let rect = NSRect(origin: .zero, size: size)
        NSBezierPath(ovalIn: rect.insetBy(dx: 0.5, dy: 0.5)).addClip()
        image.draw(in: rect, from: .zero, operation: .sourceOver, fraction: 1)
        rounded.unlockFocus()
        rounded.isTemplate = false
        return rounded
    }

    // Test affordance: a window exposing the status text and a button that pops the
    // tray menu (the status-bar item itself is awkward to drive from XCUI).
    private func showTestMenuHost() {
        let statusLabel = NSTextField(labelWithString: store.state.statusMessage)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setAccessibilityIdentifier("testStatusLabel")
        statusLabel.setAccessibilityLabel(store.state.statusMessage)

        let appMenuButton = NSButton(title: "App Menu", target: self, action: #selector(openHostedAppMenu(_:)))
        appMenuButton.setAccessibilityIdentifier("testAppMenuHostButton")

        let stack = NSStackView(views: [statusLabel, appMenuButton])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 120),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Test Menu Host"
        window.contentView = stack
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        testStatusLabel = statusLabel
        testMenuHostWindow = window
    }

    @objc private func openHostedAppMenu(_ sender: NSButton) {
        let menu = AppMenuBuilder.build(store.state.menuSnapshot(), actions: menuActions)
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }
}

extension AppDelegate: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let raw = response.notification.request.content.userInfo[UserNotificationsNotifier.workspaceIDKey] as? String
        Task { @MainActor in
            if let raw, let id = UUID(uuidString: raw), self.store.state.workspace(id) != nil {
                NSApp.activate(ignoringOtherApps: true)
                self.store.dispatch(.openProgressWindowRequested(id: id, kind: .merge))
            }
            completionHandler()
        }
    }
}
