import AppKit
import Foundation
import SwiftUI

struct PassphrasePromptResult {
    let passphrase: String
    let rememberInKeychain: Bool
}

@MainActor
final class AppController: NSObject, NSApplicationDelegate, ObservableObject, NSWindowDelegate {
    @Published var workspaceConfigs: [WorkspaceConfig] = []
    @Published var selectedWorkspaceID: UUID?
    @Published var draftConfig = WorkspaceConfig()
    @Published var isSaving = false
    @Published var isTesting = false
    @Published var isMerging = false
    @Published var errorMessage = ""
    @Published var statusMessage = "Not configured"
    @Published var lastResultMessage = ""
    @Published var mergeStatusesByPath: [String: MergeWorkspaceStatus] = [:]
    @Published var mergeShowsDetailsByPath: [String: Bool] = [:]

    private let defaults: UserDefaults
    private let workspaceConfigsKey = "workspaceConfigs"
    private var statusItem: NSStatusItem?
    private var preferencesWindow: NSWindow?
    private var testMenuHostWindow: NSWindow?
    private var testAppMenuHostButton: NSButton?
    private var testStatusLabel: NSTextField?
    private var mergeProgressWindow: NSWindow?
    private var mergeProgressWorkspaceID: UUID?
    private var statusMenuItem: NSMenuItem?
    private var mergePollTask: Task<Void, Never>?

    private var menuBuilder: AppMenuBuilder {
        AppMenuBuilder(controller: self)
    }

    override init() {
        let suiteName = ProcessInfo.processInfo.environment["CLING_SYNC_TEST_DEFAULTS_SUITE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let suiteName, !suiteName.isEmpty, let suiteDefaults = UserDefaults(suiteName: suiteName) {
            defaults = suiteDefaults
        } else {
            defaults = UserDefaults.standard
        }
        super.init()
        loadWorkspaceConfigs()
        selectInitialWorkspace()
        updateDraftFromSelection()
        updateStatusMessage()
    }

    var selectedWorkspaceIndex: Int? {
        guard let selectedWorkspaceID else { return nil }
        return workspaceConfigs.firstIndex(where: { $0.id == selectedWorkspaceID })
    }

    var canSaveDraft: Bool {
        selectedWorkspaceID != nil && draftConfig.isValidForSave && !isSaving && !isTesting
    }

    var canTestDraft: Bool {
        selectedWorkspaceID != nil && draftConfig.isReadyForTest && !isSaving && !isTesting
    }

    var draftNeedsTest: Bool {
        selectedWorkspaceID != nil && draftConfig.isReadyForTest && !draftConfig.isAccessVerified
    }

    var hasActiveMerges: Bool {
        mergeStatusesByPath.values.contains(where: { $0.running })
    }

    var isTestMode: Bool {
        ProcessInfo.processInfo.environment["CLING_SYNC_TEST_MENU_HOST"] == "1"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let image = NSImage(named: "AppIcon") {
            NSApp.applicationIconImage = image
        }
        setupStatusItem()
        if isTestMode {
            showTestMenuHost()
        }
        if workspaceConfigs.isEmpty {
            showPreferences()
        }
    }

    func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.image = trayIconImage()
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "Cling Sync"
        item.button?.setAccessibilityLabel("Cling Sync")
        statusItem = item
        rebuildMenu()
    }

    func trayIconImage() -> NSImage? {
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

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === preferencesWindow {
            preferencesWindow = nil
            return
        }
        if notification.object as? NSWindow === mergeProgressWindow {
            mergeProgressWindow = nil
            mergeProgressWorkspaceID = nil
        }
    }

    func updateStatusMessage() {
        if isMerging {
            if let workspace = workspaceConfigs.first(where: { mergeStatus(for: $0).running }) {
                statusMessage = "\(workspace.displayName): \(mergeStatusText(for: workspace))"
            } else {
                statusMessage = "Merging..."
            }
        } else if isTesting {
            statusMessage = "Testing..."
        } else if isSaving {
            statusMessage = "Saving workspace..."
        } else if !lastResultMessage.isEmpty {
            statusMessage = lastResultMessage
        } else if workspaceConfigs.isEmpty {
            statusMessage = "Setup required"
        } else if workspaceConfigs.count == 1, let workspace = workspaceConfigs.first {
            statusMessage = workspace.displayName
        } else {
            statusMessage = "\(workspaceConfigs.count) folders"
        }
        statusMenuItem?.title = statusMessage
    }

    func refreshMenu() {
        updateStatusMessage()
        rebuildMenu()
        if let hostingController = preferencesWindow?.contentViewController as? NSHostingController<PreferencesView> {
            hostingController.rootView = PreferencesView(controller: self)
        }
        if let workspace = mergeProgressWorkspaceID.flatMap(workspace(for:)),
            let hostingController = mergeProgressWindow?.contentViewController
                as? NSHostingController<MergeProgressView>
        {
            hostingController.rootView = MergeProgressView(controller: self, workspace: workspace)
            mergeProgressWindow?.title = workspace.displayName + " Merge"
        }
    }

    func rebuildMenu() {
        let menu = menuBuilder.buildRootMenu()
        statusMenuItem = nil
        statusItem?.menu = menu
        refreshTestMenuHostWindow()
    }

    func showPreferences() {
        if let window = preferencesWindow {
            updateDraftFromSelection()
            refreshMenu()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hostingController = NSHostingController(rootView: PreferencesView(controller: self))
        let window = NSWindow(contentViewController: hostingController)
        window.title = "Cling Sync Folders"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 860, height: 500))
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        preferencesWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func closePreferences() {
        updateDraftFromSelection()
        preferencesWindow?.close()
        if isTestMode, let window = testMenuHostWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.orderFrontRegardless()
        }
    }

    func showMergeProgressWindow(for workspace: WorkspaceConfig) {
        mergeProgressWorkspaceID = workspace.id
        if let window = mergeProgressWindow,
            let hostingController = window.contentViewController as? NSHostingController<MergeProgressView>
        {
            hostingController.rootView = MergeProgressView(controller: self, workspace: workspace)
            window.title = workspace.displayName + " Merge"
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hostingController = NSHostingController(rootView: MergeProgressView(controller: self, workspace: workspace))
        let window = NSWindow(contentViewController: hostingController)
        window.title = workspace.displayName + " Merge"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 760, height: 420))
        window.minSize = NSSize(width: 640, height: 320)
        window.center()
        window.isReleasedWhenClosed = false
        window.delegate = self
        mergeProgressWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func closeMergeProgressWindow() {
        mergeProgressWindow?.close()
        mergeProgressWindow = nil
        mergeProgressWorkspaceID = nil
    }

    func chooseLocalDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if !draftConfig.localDirectory.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: draftConfig.localDirectory)
        }
        if panel.runModal() == .OK, let url = panel.url {
            draftConfig.localDirectory = url.path
            draftConfig.verifiedAccessSignature = ""
            do {
                let inspection = try Bridge.inspectWorkspace(localPath: url.path)
                if inspection.exists {
                    draftConfig.hostURL = inspection.hostURL
                    draftConfig.repoPathPrefix = inspection.repoPathPrefix
                    if inspection.hasStoredAccess {
                        draftConfig.verifiedAccessSignature = draftConfig.accessSignature
                    }
                }
                errorMessage = ""
            } catch {
                errorMessage =
                    (error as? BridgeError)?.message
                    ?? error.localizedDescription
            }
            updateDraftInList()
        }
    }

    func addWorkspace() {
        errorMessage = ""
        let config = WorkspaceConfig()
        workspaceConfigs.append(config)
        persistWorkspaceConfigs()
        selectedWorkspaceID = config.id
        draftConfig = config
        showPreferences()
        refreshMenu()
    }

    func selectWorkspace(_ workspaceID: UUID?) {
        selectedWorkspaceID = workspaceID
        updateDraftFromSelection()
        errorMessage = ""
    }

    func removeSelectedWorkspace() {
        guard let selectedWorkspaceID else { return }
        removeWorkspace(id: selectedWorkspaceID)
    }

    func removeWorkspace(id: UUID) {
        if let workspace = workspace(for: id) {
            try? Bridge.clearWorkspacePassphrase(hostURL: workspace.normalizedHostURL)
            mergeStatusesByPath.removeValue(forKey: workspace.normalizedLocalDirectory)
            mergeShowsDetailsByPath.removeValue(forKey: workspace.normalizedLocalDirectory)
        }
        workspaceConfigs.removeAll(where: { $0.id == id })
        persistWorkspaceConfigs()
        if selectedWorkspaceID == id {
            selectInitialWorkspace()
            updateDraftFromSelection()
        }
        lastResultMessage = "Folder removed"
        refreshMenu()
        if workspaceConfigs.isEmpty {
            showPreferences()
        }
    }

    func testDraft() {
        guard canTestDraft else { return }
        errorMessage = ""
        isTesting = true
        refreshMenu()
        let config = normalizedDraftConfig()
        Task {
            do {
                try await configureWorkspace(config)
                try await testWorkspaceAccess(config, password: nil)
                markDraftVerified(config)
            } catch let bridgeError as BridgeError where bridgeError.isPassphraseRequired {
                do {
                    guard let prompt = promptForPassphrase(for: config) else {
                        isTesting = false
                        refreshMenu()
                        return
                    }
                    try await testWorkspaceAccess(config, password: prompt.passphrase)
                    if prompt.rememberInKeychain {
                        try await storeWorkspacePassphrase(config, passphrase: prompt.passphrase)
                    }
                    markDraftVerified(config)
                } catch {
                    isTesting = false
                    errorMessage = (error as? BridgeError)?.message ?? error.localizedDescription
                    refreshMenu()
                }
            } catch {
                isTesting = false
                errorMessage = (error as? BridgeError)?.message ?? error.localizedDescription
                refreshMenu()
            }
        }
    }

    func markDraftVerified(_ config: WorkspaceConfig) {
        var verified = config
        verified.verifiedAccessSignature = verified.accessSignature
        upsertWorkspace(verified)
        draftConfig = verified
        isTesting = false
        lastResultMessage = "Tested \(verified.displayName)"
        refreshMenu()
    }

    func saveDraft() {
        guard !isSaving else { return }
        errorMessage = ""
        isSaving = true
        refreshMenu()
        let config = normalizedDraftConfig()
        Task {
            upsertWorkspace(config)
            isSaving = false
            lastResultMessage = "Saved \(config.displayName)"
            refreshMenu()
            closePreferences()
        }
    }

    func openLocalFolder(_ workspace: WorkspaceConfig) {
        NSWorkspace.shared.open(URL(fileURLWithPath: workspace.normalizedLocalDirectory))
    }

    func lastMergeLabel(for workspace: WorkspaceConfig) -> String {
        guard let date = workspace.lastMergeDate else {
            return "Never merged"
        }
        return Self.syncDateFormatter.localizedString(for: date, relativeTo: Date())
    }

    func mergeStatus(for workspace: WorkspaceConfig) -> MergeWorkspaceStatus {
        mergeStatusesByPath[workspace.normalizedLocalDirectory]
            ?? MergeWorkspaceStatus(
                running: false,
                canCancel: false,
                completed: false,
                cancelled: false,
                upToDate: false,
                statusMessage: "",
                detailedOutput: "",
                revisionId: "",
                errorMessage: ""
            )
    }

    func mergeShowsDetails(for workspace: WorkspaceConfig) -> Bool {
        mergeShowsDetailsByPath[workspace.normalizedLocalDirectory] ?? false
    }

    func setMergeShowsDetails(_ showsDetails: Bool, for workspace: WorkspaceConfig) {
        mergeShowsDetailsByPath[workspace.normalizedLocalDirectory] = showsDetails
    }

    func mergeStatusText(for workspace: WorkspaceConfig) -> String {
        let status = mergeStatus(for: workspace)
        if status.running || status.completed {
            return status.statusMessage
        }
        return lastMergeLabel(for: workspace)
    }

    func loadWorkspaceConfigs() {
        if let data = defaults.data(forKey: workspaceConfigsKey),
            let decoded = try? JSONDecoder().decode([WorkspaceConfig].self, from: data)
        {
            workspaceConfigs = decoded
        } else {
            workspaceConfigs = []
        }
    }

    func persistWorkspaceConfigs() {
        if let data = try? JSONEncoder().encode(workspaceConfigs) {
            defaults.set(data, forKey: workspaceConfigsKey)
        }
    }

    func selectInitialWorkspace() {
        if let selectedWorkspaceID, workspaceConfigs.contains(where: { $0.id == selectedWorkspaceID }) {
            return
        }
        selectedWorkspaceID = workspaceConfigs.first?.id
    }

    func updateDraftFromSelection() {
        if let workspace = selectedWorkspaceIndex.map({ workspaceConfigs[$0] }) {
            draftConfig = workspace
            if draftConfig.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                draftConfig.author = loginAuthorName
            }
        } else {
            draftConfig = WorkspaceConfig()
        }
    }

    func handleDraftAccessChange() {
        if draftConfig.verifiedAccessSignature != draftConfig.accessSignature {
            draftConfig.verifiedAccessSignature = ""
        }
        updateDraftInList()
    }

    func handleDraftMetadataChange() {
        draftConfig.verifiedAccessSignature = ""
        updateDraftInList()
    }

    func updateDraftInList() {
        guard let selectedWorkspaceID,
            let index = workspaceConfigs.firstIndex(where: { $0.id == selectedWorkspaceID })
        else {
            return
        }
        workspaceConfigs[index] = draftConfig
        persistWorkspaceConfigs()
        refreshMenu()
    }

    func normalizedDraftConfig() -> WorkspaceConfig {
        WorkspaceConfig(
            id: draftConfig.id,
            hostURL: draftConfig.normalizedHostURL,
            localDirectory: draftConfig.normalizedLocalDirectory,
            repoPathPrefix: draftConfig.normalizedRepoPathPrefix,
            author: draftConfig.normalizedAuthor,
            verifiedAccessSignature: draftConfig.verifiedAccessSignature
        )
    }

    func upsertWorkspace(_ config: WorkspaceConfig) {
        if let index = workspaceConfigs.firstIndex(where: { $0.id == config.id }) {
            let previous = workspaceConfigs[index]
            if previous.normalizedLocalDirectory != config.normalizedLocalDirectory
                || previous.normalizedHostURL != config.normalizedHostURL
            {
                try? Bridge.clearWorkspacePassphrase(hostURL: previous.normalizedHostURL)
                mergeStatusesByPath.removeValue(forKey: previous.normalizedLocalDirectory)
                mergeShowsDetailsByPath.removeValue(forKey: previous.normalizedLocalDirectory)
            }
            workspaceConfigs[index] = config
        } else {
            workspaceConfigs.append(config)
        }
        persistWorkspaceConfigs()
        selectedWorkspaceID = config.id
        draftConfig = config
    }

    func configureWorkspace(_ config: WorkspaceConfig) async throws {
        try await Task.detached(priority: .userInitiated) {
            try Bridge.configureWorkspace(
                url: config.normalizedHostURL,
                localPath: config.normalizedLocalDirectory,
                repoPathPrefix: config.normalizedRepoPathPrefix
            )
        }.value
    }

    func testWorkspaceAccess(_ config: WorkspaceConfig, password: String?) async throws {
        try await Task.detached(priority: .userInitiated) {
            try Bridge.testWorkspaceAccess(localPath: config.normalizedLocalDirectory, password: password)
        }.value
    }

    func storeWorkspacePassphrase(_ config: WorkspaceConfig, passphrase: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            try Bridge.storeWorkspacePassphrase(localPath: config.normalizedLocalDirectory, password: passphrase)
        }.value
    }

    func startMergeFromMenu(_ workspace: WorkspaceConfig) async {
        guard !mergeStatus(for: workspace).running else { return }
        errorMessage = ""
        do {
            try await startMergeWorkspace(workspace, password: nil, storePassword: false)
        } catch let bridgeError as BridgeError where bridgeError.isPassphraseRequired {
            guard let prompt = promptForPassphrase(for: workspace) else { return }
            do {
                try await startMergeWorkspace(
                    workspace,
                    password: prompt.passphrase,
                    storePassword: prompt.rememberInKeychain,
                )
            } catch {
                showAlert(
                    title: "Merge Failed",
                    message: (error as? BridgeError)?.message ?? error.localizedDescription,
                )
            }
        } catch {
            showAlert(
                title: "Merge Failed",
                message: (error as? BridgeError)?.message ?? error.localizedDescription,
            )
        }
    }

    func startMergeWorkspace(_ workspace: WorkspaceConfig, password: String?, storePassword: Bool) async throws {
        lastResultMessage = ""
        let runningStatus = MergeWorkspaceStatus(
            running: true,
            canCancel: true,
            completed: false,
            cancelled: false,
            upToDate: false,
            statusMessage: "Preparing merge...",
            detailedOutput: "",
            revisionId: "",
            errorMessage: ""
        )
        mergeStatusesByPath[workspace.normalizedLocalDirectory] = runningStatus
        isMerging = hasActiveMerges
        refreshMenu()
        showMergeProgressWindow(for: workspace)
        try await Task.detached(priority: .userInitiated) {
            try Bridge.startMergeWorkspace(
                localPath: workspace.normalizedLocalDirectory,
                password: password,
                author: workspace.normalizedAuthor,
                message: "Merge from macOS menu bar",
                storePassword: storePassword,
            )
        }.value
        beginMergeStatusPolling()
    }

    func cancelMerge(workspace: WorkspaceConfig) {
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try Bridge.cancelMergeWorkspace(localPath: workspace.normalizedLocalDirectory)
                }.value
                beginMergeStatusPolling()
            } catch {
                showAlert(
                    title: "Cancel Merge Failed",
                    message: (error as? BridgeError)?.message ?? error.localizedDescription,
                )
            }
        }
    }

    func beginMergeStatusPolling() {
        guard mergePollTask == nil else { return }
        mergePollTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.pollMergeStatuses()
                if !self.hasActiveMerges {
                    break
                }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            await MainActor.run {
                self.mergePollTask = nil
                self.refreshMenu()
            }
        }
    }

    func pollMergeStatuses() async {
        let workspaces = workspaceConfigs
        var statuses: [String: MergeWorkspaceStatus] = [:]
        for workspace in workspaces {
            let localPath = workspace.normalizedLocalDirectory
            guard !localPath.isEmpty else { continue }
            do {
                let status = try await Task.detached(priority: .userInitiated) {
                    try Bridge.getMergeWorkspaceStatus(localPath: localPath)
                }.value
                if status.running || status.completed || !status.statusMessage.isEmpty || !status.errorMessage.isEmpty {
                    statuses[localPath] = status
                }
            } catch {
                statuses[localPath] = MergeWorkspaceStatus(
                    running: false,
                    canCancel: false,
                    completed: true,
                    cancelled: false,
                    upToDate: false,
                    statusMessage: "Merge failed",
                    detailedOutput: "",
                    revisionId: "",
                    errorMessage: (error as? BridgeError)?.message ?? error.localizedDescription
                )
            }
        }
        await MainActor.run {
            let previousStatuses = mergeStatusesByPath
            mergeStatusesByPath = statuses
            isMerging = hasActiveMerges
            for workspace in workspaceConfigs {
                let localPath = workspace.normalizedLocalDirectory
                guard let status = statuses[localPath], status.completed else { continue }
                let previous = previousStatuses[localPath]
                if previous?.running == true || previous?.statusMessage != status.statusMessage {
                    if !status.errorMessage.isEmpty {
                        showAlert(title: "Merge Failed", message: status.errorMessage)
                    }
                    lastResultMessage = "\(workspace.displayName): \(status.statusMessage)"
                }
            }
            refreshMenu()
        }
    }

    func promptForPassphrase(for workspace: WorkspaceConfig) -> PassphrasePromptResult? {
        while true {
            let alert = NSAlert()
            alert.messageText = "Enter Passphrase"
            alert.informativeText = "Cling Sync needs the repository passphrase for \(workspace.displayName)."
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 56))
            let stack = NSStackView(frame: container.bounds)
            stack.orientation = .vertical
            stack.spacing = 8
            stack.alignment = .leading
            stack.autoresizingMask = [.width, .height]
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            field.placeholderString = "Passphrase"
            field.setAccessibilityIdentifier("passphrasePromptField")
            let checkbox = NSButton(
                checkboxWithTitle: "Save access in macOS Keychain",
                target: nil,
                action: nil,
            )
            checkbox.setAccessibilityIdentifier("passphrasePromptRemember")
            stack.addArrangedSubview(field)
            stack.addArrangedSubview(checkbox)
            container.addSubview(stack)
            alert.accessoryView = container
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            alert.window.initialFirstResponder = field
            DispatchQueue.main.async {
                alert.window.makeFirstResponder(field)
                field.selectText(nil)
            }
            if alert.runModal() != .alertFirstButtonReturn {
                return nil
            }
            let passphrase = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !passphrase.isEmpty {
                return PassphrasePromptResult(passphrase: passphrase, rememberInKeychain: checkbox.state == .on)
            }
        }
    }

    func workspaceID(from sender: NSMenuItem) -> UUID? {
        guard let raw = sender.representedObject as? String else { return nil }
        return UUID(uuidString: raw)
    }

    func workspace(for id: UUID) -> WorkspaceConfig? {
        workspaceConfigs.first(where: { $0.id == id })
    }

    func showAlert(title: String, message: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    @objc func handleMergeWorkspace(_ sender: NSMenuItem) {
        guard let id = workspaceID(from: sender), let workspace = workspace(for: id) else { return }
        Task { await startMergeFromMenu(workspace) }
    }
    @objc func handleOpenMergeProgress(_ sender: NSMenuItem) {
        guard let id = workspaceID(from: sender), let workspace = workspace(for: id) else { return }
        showMergeProgressWindow(for: workspace)
    }
    @objc func handleOpenWorkspaceFolder(_ sender: NSMenuItem) {
        guard let id = workspaceID(from: sender), let workspace = workspace(for: id) else { return }
        openLocalFolder(workspace)
    }
    @objc func handleEditWorkspace(_ sender: NSMenuItem) {
        guard let id = workspaceID(from: sender) else { return }
        selectWorkspace(id)
        showPreferences()
    }
    @objc func handleRemoveWorkspace(_ sender: NSMenuItem) {
        guard let id = workspaceID(from: sender) else { return }
        removeWorkspace(id: id)
    }
    @objc func handleOpenPreferences() { showPreferences() }
    @objc func handleQuit() { NSApp.terminate(nil) }

    func showTestMenuHost() {
        let statusLabel = NSTextField(labelWithString: statusMessage)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setAccessibilityIdentifier("testStatusLabel")
        statusLabel.setAccessibilityLabel(statusMessage)

        let appMenuButton = NSButton(
            title: "App Menu",
            target: self,
            action: #selector(handleOpenHostedAppMenu(_:)),
        )
        appMenuButton.setAccessibilityIdentifier("testAppMenuHostButton")

        let stack = NSStackView(views: [statusLabel, appMenuButton])
        stack.orientation = .vertical
        stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 280, height: 120),
            styleMask: [.titled],
            backing: .buffered,
            defer: false,
        )
        window.title = "Test Menu Host"
        window.contentView = stack
        window.isReleasedWhenClosed = false
        window.orderFront(nil)
        testStatusLabel = statusLabel
        testAppMenuHostButton = appMenuButton
        testMenuHostWindow = window
        refreshTestMenuHostWindow()
    }

    func refreshTestMenuHostWindow() {
        testStatusLabel?.stringValue = statusMessage
        testStatusLabel?.setAccessibilityLabel(statusMessage)
        testAppMenuHostButton?.isEnabled = true
    }

    @objc func handleOpenHostedAppMenu(_ sender: NSButton) {
        let menu = menuBuilder.buildRootMenu()
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: sender.bounds.height), in: sender)
    }

    static let syncDateFormatter: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter
    }()
}
