import AppKit
import Foundation
import SwiftUI

struct PassphrasePromptResult {
    let passphrase: String
    let rememberInKeychain: Bool
}

// Holds a status poller's task plus a flag an operation sets when it registers
// while the poller is winding down, so the poller does one more pass and never
// leaves a freshly started operation unobserved.
@MainActor
private final class PollerState {
    var task: Task<Void, Never>?
    var restartRequested = false
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
    @Published var statusStatusesByPath: [String: StatusWorkspaceStatus] = [:]
    @Published var statusShowsDetailsByPath: [String: Bool] = [:]
    @Published var syncStatusesByPath: [String: MergeWorkspaceStatus] = [:]
    @Published var syncShowsDetailsByPath: [String: Bool] = [:]
    @Published var syncTargetsByPath: [String: [SyncTargetInfo]] = [:]
    @Published var selectedSyncTargetName: String?
    @Published var syncWorkers: Int = 2 {
        didSet { defaults.set(syncWorkers, forKey: syncWorkersKey) }
    }
    @Published var autoMergeIntervalHours: Int = 0 {
        didSet {
            guard autoMergeIntervalHours != oldValue else { return }
            defaults.set(autoMergeIntervalHours, forKey: autoMergeIntervalHoursKey)
            // Honor the chosen interval rather than a leftover backoff interval.
            networkBackoffPaths.removeAll()
            rescheduleAutoMerge()
        }
    }
    @Published var notifyStaleDays: Int = 0 {
        didSet {
            guard notifyStaleDays != oldValue else { return }
            defaults.set(notifyStaleDays, forKey: notifyStaleDaysKey)
            rescheduleStaleCheck()
        }
    }
    @Published var selectedSettingsTab = 0

    private let defaults: UserDefaults
    private let workspaceConfigsKey = "workspaceConfigs"
    private let syncWorkersKey = "syncWorkers"
    private let autoMergeIntervalHoursKey = "autoMergeIntervalHours"
    private let notifyStaleDaysKey = "notifyStaleDays"
    private let lastSuccessfulMergeKey = "lastSuccessfulMergeByPath"
    private let firstTrackedKey = "firstTrackedByPath"
    private let lastStaleNotifiedKey = "lastStaleNotifiedByPath"
    var autoMergeTimer: Timer?
    // Background merges in flight, so their completion routes to a notification
    // rather than a modal alert.
    var autoMergePaths: Set<String> = []
    var lastSuccessfulMergeByPath: [String: Date] = [:]
    // The staleness clock for a workspace that has never merged.
    var firstTrackedByPath: [String: Date] = [:]
    var lastStaleNotifiedByPath: [String: Date] = [:]
    // Paths whose last auto-merge hit a connectivity error. While non-empty the
    // auto-merge interval is shortened until they recover.
    var networkBackoffPaths: Set<String> = []
    var staleCheckTimer: Timer?
    var manualAutoMergeTimer: Timer?
    private var trayAnimator: TrayIconAnimator?
    private var statusItem: NSStatusItem?
    private var preferencesWindow: NSWindow?
    private var testMenuHostWindow: NSWindow?
    private var testAppMenuHostButton: NSButton?
    private var testStatusLabel: NSTextField?
    private var mergeProgressWindow: NSWindow?
    private var mergeProgressWorkspaceID: UUID?
    private var statusProgressWindow: NSWindow?
    private var statusProgressWorkspaceID: UUID?
    private var syncProgressWindow: NSWindow?
    private var syncProgressWorkspaceID: UUID?
    private var statusMenuItem: NSMenuItem?
    private let mergePoller = PollerState()
    private let statusPoller = PollerState()
    private let syncPoller = PollerState()
    // Security-scoped folder URLs we hold access to, keyed by local path. In the
    // sandbox a user-selected folder is only reachable while its bookmark is
    // resolved and access is held open; we keep it open for the app's lifetime.
    private var directoryAccessURLs: [String: URL] = [:]

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
        syncWorkers = max(1, (defaults.object(forKey: syncWorkersKey) as? Int) ?? 2)
        autoMergeIntervalHours = max(0, (defaults.object(forKey: autoMergeIntervalHoursKey) as? Int) ?? 0)
        notifyStaleDays = max(0, (defaults.object(forKey: notifyStaleDaysKey) as? Int) ?? 0)
        loadWorkspaceConfigs()
        loadMergeTrackingState()
        ensureMergeTracking()
        activateAllDirectoryAccess()
        selectInitialWorkspace()
        updateDraftFromSelection()
        updateStatusMessage()
    }

    func loadMergeTrackingState() {
        lastSuccessfulMergeByPath = loadDateDict(lastSuccessfulMergeKey)
        firstTrackedByPath = loadDateDict(firstTrackedKey)
        lastStaleNotifiedByPath = loadDateDict(lastStaleNotifiedKey)
    }

    func persistMergeTrackingState() {
        saveDateDict(lastSuccessfulMergeByPath, lastSuccessfulMergeKey)
        saveDateDict(firstTrackedByPath, firstTrackedKey)
        saveDateDict(lastStaleNotifiedByPath, lastStaleNotifiedKey)
    }

    private func loadDateDict(_ key: String) -> [String: Date] {
        let raw = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        return raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    private func saveDateDict(_ dict: [String: Date], _ key: String) {
        defaults.set(dict.mapValues { $0.timeIntervalSince1970 }, forKey: key)
    }

    // Starts the staleness clock for any complete workspace not seen before, so a
    // folder that never once merges still trips the overdue notification.
    func ensureMergeTracking() {
        let now = Date()
        var changed = false
        for workspace in workspaceConfigs where workspace.isComplete {
            let path = workspace.normalizedLocalDirectory
            guard !path.isEmpty, firstTrackedByPath[path] == nil else { continue }
            firstTrackedByPath[path] = now
            changed = true
        }
        if changed {
            persistMergeTrackingState()
        }
    }

    // "up to date" also counts: a reachable repository with nothing to merge ends
    // the staleness clock and the path's connectivity backoff.
    func recordSuccessfulMerge(_ path: String) {
        lastSuccessfulMergeByPath[path] = Date()
        lastStaleNotifiedByPath.removeValue(forKey: path)
        persistMergeTrackingState()
        setNetworkBackoff(false, for: path)
    }

    func forgetMergeTracking(_ path: String) {
        autoMergePaths.remove(path)
        lastSuccessfulMergeByPath.removeValue(forKey: path)
        firstTrackedByPath.removeValue(forKey: path)
        lastStaleNotifiedByPath.removeValue(forKey: path)
        persistMergeTrackingState()
        setNetworkBackoff(false, for: path)
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

    var selectedSavedWorkspace: WorkspaceConfig? {
        guard let selectedWorkspaceID else { return nil }
        return workspaceConfigs.first(where: { $0.id == selectedWorkspaceID })
    }

    func isBusy(_ workspace: WorkspaceConfig) -> Bool {
        mergeStatus(for: workspace).running
            || statusStatus(for: workspace).running
            || syncStatus(for: workspace).running
    }

    func activeOperationLabel(for workspace: WorkspaceConfig) -> String? {
        if mergeStatus(for: workspace).running {
            return "Merge (in progress)"
        }
        if syncStatus(for: workspace).running {
            return "Sync (in progress)"
        }
        if statusStatus(for: workspace).running {
            return "Status (in progress)"
        }
        return nil
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
        loadAllSyncTargets()
        rescheduleAutoMerge()
        rescheduleStaleCheck()
        if isTestMode {
            showTestMenuHost()
        }
        if workspaceConfigs.isEmpty {
            showPreferences()
        }
    }

    func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let idleImage = trayIconImage()
        item.button?.image = idleImage
        item.button?.imagePosition = .imageOnly
        item.button?.toolTip = "Cling Sync"
        item.button?.setAccessibilityLabel("Cling Sync")
        statusItem = item
        trayAnimator = TrayIconAnimator(button: item.button, idleImage: idleImage)
        rebuildMenu()
    }

    var anyOperationRunning: Bool {
        hasActiveMerges || hasActiveStatuses || hasActiveSyncs
    }

    // One label per running operation across every workspace, used to build the
    // "X in progress" tray tooltip.
    var runningOperationLabels: [String] {
        var labels: [String] = []
        for workspace in workspaceConfigs {
            if mergeStatus(for: workspace).running { labels.append("Merge") }
            if syncStatus(for: workspace).running { labels.append("Sync") }
            if statusStatus(for: workspace).running { labels.append("Status") }
        }
        return labels
    }

    var trayTooltip: String {
        let labels = runningOperationLabels
        switch labels.count {
        case 0: return "Cling Sync"
        case 1: return "\(labels[0]) in progress"
        default: return "\(labels.count) operations in progress"
        }
    }

    func updateTrayIcon() {
        trayAnimator?.setAnimating(anyOperationRunning)
        statusItem?.button?.toolTip = trayTooltip
        statusItem?.button?.setAccessibilityLabel(trayTooltip)
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
        if notification.object as? NSWindow === statusProgressWindow {
            statusProgressWindow = nil
            statusProgressWorkspaceID = nil
        }
        if notification.object as? NSWindow === syncProgressWindow {
            syncProgressWindow = nil
            syncProgressWorkspaceID = nil
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
        updateTrayIcon()
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
        if let workspace = syncProgressWorkspaceID.flatMap(workspace(for:)),
            let hostingController = syncProgressWindow?.contentViewController
                as? NSHostingController<SyncProgressView>
        {
            hostingController.rootView = SyncProgressView(controller: self, workspace: workspace)
            syncProgressWindow?.title = workspace.displayName + " Sync"
        }
    }

    func rebuildMenu() {
        let menu = menuBuilder.buildRootMenu()
        statusMenuItem = nil
        statusItem?.menu = menu
        refreshTestMenuHostWindow()
    }

    func showPreferences() {
        if workspaceConfigs.isEmpty {
            let config = WorkspaceConfig()
            workspaceConfigs.append(config)
            persistWorkspaceConfigs()
            selectedWorkspaceID = config.id
            draftConfig = config
        }
        if let workspace = selectedSavedWorkspace {
            loadSyncTargets(for: workspace)
        }
        if let window = preferencesWindow {
            updateDraftFromSelection()
            refreshMenu()
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }
        let hostingController = NSHostingController(rootView: PreferencesView(controller: self))
        let window = NSWindow(contentViewController: hostingController)
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
        window.level = .floating
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

    func showStatusProgressWindow(for workspace: WorkspaceConfig) {
        statusProgressWorkspaceID = workspace.id
        if let window = statusProgressWindow,
            let hostingController = window.contentViewController as? NSHostingController<StatusProgressView>
        {
            hostingController.rootView = StatusProgressView(controller: self, workspace: workspace)
            window.title = workspace.displayName + " Status"
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hostingController = NSHostingController(
            rootView: StatusProgressView(controller: self, workspace: workspace))
        let window = NSWindow(contentViewController: hostingController)
        window.title = workspace.displayName + " Status"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 760, height: 420))
        window.minSize = NSSize(width: 640, height: 320)
        window.center()
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.delegate = self
        statusProgressWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func closeStatusProgressWindow() {
        if let id = statusProgressWorkspaceID, let workspace = workspace(for: id) {
            statusStatusesByPath.removeValue(forKey: workspace.normalizedLocalDirectory)
        }
        statusProgressWindow?.close()
        statusProgressWindow = nil
        statusProgressWorkspaceID = nil
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
            draftConfig.localDirectoryBookmark = try? url.bookmarkData(
                options: .withSecurityScope,
                includingResourceValuesForKeys: nil,
                relativeTo: nil
            )
            draftConfig.verifiedAccessSignature = ""
            activateDirectoryAccess(for: draftConfig)
            do {
                let inspection = try Bridge.inspectWorkspace(localPath: url.path)
                if inspection.exists {
                    // The workspace stores the openable URI; show its cleartext form.
                    draftConfig.repositoryURI = inspection.hostURL
                    draftConfig.hostURL = WorkspaceConfig.displayURL(forRepositoryURI: inspection.hostURL)
                    draftConfig.repoPathPrefix = inspection.repoPathPrefix
                    if inspection.hasStoredAccess {
                        draftConfig.verifiedAccessSignature = draftConfig.accessSignature
                    }
                    loadSyncTargets(for: draftConfig)
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
        selectedSyncTargetName = nil
        updateDraftFromSelection()
        errorMessage = ""
        if let workspace = selectedSavedWorkspace {
            loadSyncTargets(for: workspace)
        }
    }

    func removeSelectedWorkspace() {
        guard let selectedWorkspaceID else { return }
        removeWorkspace(id: selectedWorkspaceID)
    }

    func removeWorkspace(id: UUID) {
        if let workspace = workspace(for: id) {
            try? Bridge.clearWorkspacePassphrase(hostURL: workspace.bridgeRepositoryURI)
            deactivateDirectoryAccess(forPath: workspace.normalizedLocalDirectory)
            forgetMergeTracking(workspace.normalizedLocalDirectory)
            mergeStatusesByPath.removeValue(forKey: workspace.normalizedLocalDirectory)
            mergeShowsDetailsByPath.removeValue(forKey: workspace.normalizedLocalDirectory)
            syncStatusesByPath.removeValue(forKey: workspace.normalizedLocalDirectory)
            syncShowsDetailsByPath.removeValue(forKey: workspace.normalizedLocalDirectory)
            syncTargetsByPath.removeValue(forKey: workspace.normalizedLocalDirectory)
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
        let config = normalizedDraftConfig()
        if let urlError = validateHostURL(config.normalizedHostURL) {
            errorMessage = urlError
            refreshMenu()
            return
        }
        isTesting = true
        refreshMenu()
        Task {
            do {
                let verified =
                    isFileRepositoryPath(config.normalizedHostURL)
                    ? try await testFileRepository(config)
                    : try await testS3Repository(config)
                if let verified {
                    markDraftVerified(verified)
                } else {
                    isTesting = false
                    refreshMenu()
                }
            } catch {
                isTesting = false
                errorMessage = userFacingMessage(for: error)
                refreshMenu()
            }
        }
    }

    // Returns the verified config, or nil if the user cancelled a prompt.
    private func testFileRepository(_ config: WorkspaceConfig) async throws -> WorkspaceConfig? {
        if try await !fileRepositoryExists(config) {
            guard confirmCreateNewRepository(at: config.normalizedHostURL),
                let passphrase = promptForNewRepositoryPassphrase(at: config.normalizedHostURL)
            else {
                return nil
            }
            try await initNewFileRepository(config, passphrase: passphrase)
            try await configureWorkspace(config)
            try await testWorkspaceAccess(config, password: passphrase)
            return config
        }
        try await configureWorkspace(config)
        return try await testAccessPromptingIfNeeded(config)
    }

    // For S3, the credentials are encrypted into `repositoryURI` once, here, and
    // sent with every later request; the passphrase decrypts them at open time.
    private func testS3Repository(_ config: WorkspaceConfig) async throws -> WorkspaceConfig? {
        var config = config
        // A URL pasted with its credentials already embedded is openable as-is;
        // adopt it and show the cleartext form.
        if WorkspaceConfig.s3URIHasEmbeddedCredentials(config.normalizedHostURL) {
            config.repositoryURI = config.normalizedHostURL
            config.hostURL = WorkspaceConfig.displayURL(forRepositoryURI: config.normalizedHostURL)
        }
        if config.needsS3Credentials {
            guard let prompt = promptForPassphrase(for: config),
                let creds = S3CredentialsPrompt.run(for: config.normalizedHostURL)
            else {
                return nil
            }
            config.repositoryURI = try await encodeS3URI(config, creds: creds, passphrase: prompt.passphrase)
            try await configureWorkspace(config)
            try await testWorkspaceAccess(config, password: prompt.passphrase)
            if prompt.rememberInKeychain {
                try await storeWorkspacePassphrase(config, passphrase: prompt.passphrase)
            }
            return config
        }
        try await configureWorkspace(config)
        return try await testAccessPromptingIfNeeded(config)
    }

    // Tries the stored passphrase, prompting once if the repository needs one.
    private func testAccessPromptingIfNeeded(_ config: WorkspaceConfig) async throws -> WorkspaceConfig? {
        do {
            try await testWorkspaceAccess(config, password: nil)
            return config
        } catch let error as BridgeError where error.isPassphraseRequired {
            guard let prompt = promptForPassphrase(for: config) else {
                return nil
            }
            try await testWorkspaceAccess(config, password: prompt.passphrase)
            if prompt.rememberInKeychain {
                try await storeWorkspacePassphrase(config, passphrase: prompt.passphrase)
            }
            return config
        }
    }

    func isFileRepositoryPath(_ hostURL: String) -> Bool {
        let lower = hostURL.lowercased()
        return !lower.hasPrefix("http://")
            && !lower.hasPrefix("https://")
            && !lower.hasPrefix("s3+")
    }

    func encodeS3URI(_ config: WorkspaceConfig, creds: S3CredentialsPromptResult, passphrase: String) async throws
        -> String
    {
        try await Task.detached(priority: .userInitiated) {
            try Bridge.encodeS3URI(
                hostUrl: config.normalizedHostURL,
                passphrase: passphrase,
                accessKeyId: creds.accessKeyId,
                accessKey: creds.accessKey)
        }.value
    }

    func fileRepositoryExists(_ config: WorkspaceConfig) async throws -> Bool {
        try await Task.detached(priority: .userInitiated) {
            try Bridge.checkFileRepositoryExists(localPath: config.bridgeRepositoryURI)
        }.value
    }

    func initNewFileRepository(_ config: WorkspaceConfig, passphrase: String) async throws {
        try await Task.detached(priority: .userInitiated) {
            try Bridge.initNewFileRepository(localPath: config.bridgeRepositoryURI, password: passphrase)
        }.value
    }

    func confirmCreateNewRepository(at path: String) -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Create New Repository?"
        alert.informativeText = "No repository was found at \(path). Do you want to create a new repository there?"
        alert.addButton(withTitle: "Create")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn
    }

    func promptForNewRepositoryPassphrase(at path: String) -> String? {
        while true {
            let alert = NSAlert()
            alert.messageText = "Set Repository Passphrase"
            alert.informativeText =
                "Choose a passphrase to protect the new repository at \(path). "
                + "This passphrase cannot be recovered if lost."
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            field.placeholderString = "Passphrase"
            field.setAccessibilityIdentifier("newRepositoryPassphraseField")
            alert.accessoryView = field
            alert.addButton(withTitle: "Create")
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
                return passphrase
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
        loadSyncTargets(for: verified)
        refreshMenu()
    }

    func saveDraft() {
        guard !isSaving else { return }
        errorMessage = ""
        let config = normalizedDraftConfig()
        if let urlError = validateHostURL(config.normalizedHostURL) {
            errorMessage = urlError
            refreshMenu()
            return
        }
        isSaving = true
        refreshMenu()
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

    func statusStatus(for workspace: WorkspaceConfig) -> StatusWorkspaceStatus {
        statusStatusesByPath[workspace.normalizedLocalDirectory]
            ?? StatusWorkspaceStatus(
                running: false,
                canCancel: false,
                completed: false,
                cancelled: false,
                statusMessage: "",
                detailedOutput: "",
                errorMessage: ""
            )
    }

    func statusShowsDetails(for workspace: WorkspaceConfig) -> Bool {
        statusShowsDetailsByPath[workspace.normalizedLocalDirectory] ?? false
    }

    func setStatusShowsDetails(_ showsDetails: Bool, for workspace: WorkspaceConfig) {
        statusShowsDetailsByPath[workspace.normalizedLocalDirectory] = showsDetails
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

    func activateAllDirectoryAccess() {
        for config in workspaceConfigs {
            activateDirectoryAccess(for: config)
        }
    }

    func activateDirectoryAccess(for config: WorkspaceConfig) {
        let path = config.normalizedLocalDirectory
        guard !path.isEmpty, directoryAccessURLs[path] == nil, let bookmark = config.localDirectoryBookmark else {
            return
        }
        var isStale = false
        guard
            let url = try? URL(
                resolvingBookmarkData: bookmark,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &isStale
            ),
            url.startAccessingSecurityScopedResource()
        else {
            return
        }
        directoryAccessURLs[path] = url
    }

    func deactivateDirectoryAccess(forPath path: String) {
        guard let url = directoryAccessURLs.removeValue(forKey: path) else { return }
        url.stopAccessingSecurityScopedResource()
    }

    // The sandbox drops a workspace folder's access once its security scope is
    // gone (e.g. configs saved before bookmarks existed, or a relaunch where the
    // bookmark no longer resolves), so the bridge's `local_access_denied` code is
    // turned into guidance to re-pick the folder.
    func userFacingMessage(for error: Error) -> String {
        if let bridgeError = error as? BridgeError, bridgeError.isLocalAccessDenied {
            return "macOS is blocking access to this workspace’s folder. "
                + "Open Settings and use “Browse...” under Local Folder to select the folder again and restore access."
        }
        return (error as? BridgeError)?.message ?? error.localizedDescription
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
        ensureMergeTracking()
        refreshMenu()
    }

    func normalizedDraftConfig() -> WorkspaceConfig {
        WorkspaceConfig(
            id: draftConfig.id,
            hostURL: draftConfig.normalizedHostURL,
            localDirectory: draftConfig.normalizedLocalDirectory,
            repoPathPrefix: draftConfig.normalizedRepoPathPrefix,
            author: draftConfig.normalizedAuthor,
            verifiedAccessSignature: draftConfig.verifiedAccessSignature,
            repositoryURI: draftConfig.repositoryURI,
            localDirectoryBookmark: draftConfig.localDirectoryBookmark
        )
    }

    func upsertWorkspace(_ config: WorkspaceConfig) {
        if let index = workspaceConfigs.firstIndex(where: { $0.id == config.id }) {
            let previous = workspaceConfigs[index]
            if previous.normalizedLocalDirectory != config.normalizedLocalDirectory
                || previous.bridgeRepositoryURI != config.bridgeRepositoryURI
            {
                try? Bridge.clearWorkspacePassphrase(hostURL: previous.bridgeRepositoryURI)
                forgetMergeTracking(previous.normalizedLocalDirectory)
                mergeStatusesByPath.removeValue(forKey: previous.normalizedLocalDirectory)
                mergeShowsDetailsByPath.removeValue(forKey: previous.normalizedLocalDirectory)
            }
            workspaceConfigs[index] = config
        } else {
            workspaceConfigs.append(config)
        }
        persistWorkspaceConfigs()
        ensureMergeTracking()
        selectedWorkspaceID = config.id
        draftConfig = config
    }

    func configureWorkspace(_ config: WorkspaceConfig) async throws {
        try await Task.detached(priority: .userInitiated) {
            try Bridge.configureWorkspace(
                url: config.bridgeRepositoryURI,
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
        guard !isBusy(workspace) else { return }
        errorMessage = ""
        do {
            try await startMergeWorkspace(workspace, password: nil)
        } catch let bridgeError as BridgeError where bridgeError.isPassphraseRequired {
            guard let prompt = promptForPassphrase(for: workspace) else { return }
            if prompt.rememberInKeychain {
                try? await storeWorkspacePassphrase(workspace, passphrase: prompt.passphrase)
            }
            do {
                try await startMergeWorkspace(workspace, password: prompt.passphrase)
            } catch {
                showAlert(
                    title: "Merge Failed",
                    message: userFacingMessage(for: error),
                )
            }
        } catch {
            showAlert(
                title: "Merge Failed",
                message: userFacingMessage(for: error),
            )
        }
    }

    func startMergeWorkspace(_ workspace: WorkspaceConfig, password: String?, presentWindow: Bool = true) async throws {
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
        if presentWindow {
            showMergeProgressWindow(for: workspace)
        }
        do {
            try await Task.detached(priority: .userInitiated) {
                try Bridge.startMergeWorkspace(
                    localPath: workspace.normalizedLocalDirectory,
                    password: password,
                    author: workspace.normalizedAuthor,
                    message: "Merge from macOS menu bar",
                )
            }.value
        } catch {
            // The operation never started, so clear the optimistic "in progress"
            // state instead of leaving it stuck running.
            mergeStatusesByPath[workspace.normalizedLocalDirectory] = MergeWorkspaceStatus(
                running: false,
                canCancel: false,
                completed: true,
                cancelled: false,
                upToDate: false,
                statusMessage: "Merge failed",
                detailedOutput: "",
                revisionId: "",
                errorMessage: userFacingMessage(for: error)
            )
            isMerging = hasActiveMerges
            refreshMenu()
            throw error
        }
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
                    message: userFacingMessage(for: error),
                )
            }
        }
    }

    func beginMergeStatusPolling() {
        drivePoller(
            mergePoller,
            hasActive: { [weak self] in self?.hasActiveMerges ?? false },
            poll: { [weak self] in await self?.pollMergeStatuses() }
        )
    }

    // Clearing poller.task and re-checking restartRequested happen together under
    // MainActor, so an operation that registered while the task was winding down
    // restarts the poller instead of being stranded with none.
    private func drivePoller(
        _ poller: PollerState,
        hasActive: @escaping () -> Bool,
        poll: @escaping () async -> Void
    ) {
        if poller.task != nil {
            poller.restartRequested = true
            return
        }
        poller.task = Task { [weak self] in
            guard let self else { return }
            while true {
                await poll()
                if hasActive() {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    continue
                }
                let stop = await MainActor.run { () -> Bool in
                    if poller.restartRequested {
                        poller.restartRequested = false
                        return false
                    }
                    poller.task = nil
                    self.refreshMenu()
                    return true
                }
                if stop {
                    return
                }
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
                    errorMessage: userFacingMessage(for: error)
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
                    if status.errorMessage.isEmpty, !status.cancelled {
                        recordSuccessfulMerge(localPath)
                    }
                    if autoMergePaths.remove(localPath) != nil {
                        handleAutoMergeCompletion(workspace: workspace, status: status)
                    } else if !status.errorMessage.isEmpty {
                        showAlert(title: "Merge Failed", message: status.errorMessage)
                    }
                    lastResultMessage = "\(workspace.displayName): \(status.statusMessage)"
                }
            }
            refreshMenu()
        }
    }

    // MARK: - Status

    func startStatusFromMenu(_ workspace: WorkspaceConfig) async {
        guard !isBusy(workspace) else { return }
        errorMessage = ""
        do {
            try await startStatusWorkspace(workspace, password: nil)
        } catch let bridgeError as BridgeError where bridgeError.isPassphraseRequired {
            guard let prompt = promptForPassphrase(for: workspace) else { return }
            if prompt.rememberInKeychain {
                try? await storeWorkspacePassphrase(workspace, passphrase: prompt.passphrase)
            }
            do {
                try await startStatusWorkspace(workspace, password: prompt.passphrase)
            } catch {
                showAlert(
                    title: "Status Failed",
                    message: userFacingMessage(for: error),
                )
            }
        } catch {
            showAlert(
                title: "Status Failed",
                message: userFacingMessage(for: error),
            )
        }
    }

    func startStatusWorkspace(_ workspace: WorkspaceConfig, password: String?) async throws {
        let runningStatus = StatusWorkspaceStatus(
            running: true,
            canCancel: true,
            completed: false,
            cancelled: false,
            statusMessage: "Scanning workspace...",
            detailedOutput: "",
            errorMessage: ""
        )
        statusStatusesByPath[workspace.normalizedLocalDirectory] = runningStatus
        refreshMenu()
        showStatusProgressWindow(for: workspace)
        do {
            try await Task.detached(priority: .userInitiated) {
                try Bridge.startStatusWorkspace(
                    localPath: workspace.normalizedLocalDirectory,
                    password: password,
                )
            }.value
        } catch {
            // The operation never started, so clear the optimistic "in progress"
            // state instead of leaving it stuck running.
            statusStatusesByPath[workspace.normalizedLocalDirectory] = StatusWorkspaceStatus(
                running: false,
                canCancel: false,
                completed: true,
                cancelled: false,
                statusMessage: "Status failed",
                detailedOutput: "",
                errorMessage: userFacingMessage(for: error)
            )
            refreshMenu()
            throw error
        }
        beginStatusPolling()
    }

    func cancelStatus(workspace: WorkspaceConfig) {
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try Bridge.cancelStatusWorkspace(localPath: workspace.normalizedLocalDirectory)
                }.value
                beginStatusPolling()
            } catch {
                showAlert(
                    title: "Cancel Status Failed",
                    message: userFacingMessage(for: error),
                )
            }
        }
    }

    func beginStatusPolling() {
        drivePoller(
            statusPoller,
            hasActive: { [weak self] in self?.hasActiveStatuses ?? false },
            poll: { [weak self] in await self?.pollStatusStatuses() }
        )
    }

    var hasActiveStatuses: Bool {
        statusStatusesByPath.values.contains(where: { $0.running })
    }

    func pollStatusStatuses() async {
        let workspaces = workspaceConfigs
        var statuses: [String: StatusWorkspaceStatus] = [:]
        for workspace in workspaces {
            let localPath = workspace.normalizedLocalDirectory
            guard !localPath.isEmpty else { continue }
            do {
                let status = try await Task.detached(priority: .userInitiated) {
                    try Bridge.getStatusWorkspaceStatus(localPath: localPath)
                }.value
                if status.running || status.completed || !status.statusMessage.isEmpty || !status.errorMessage.isEmpty {
                    statuses[localPath] = status
                }
            } catch {
                statuses[localPath] = StatusWorkspaceStatus(
                    running: false,
                    canCancel: false,
                    completed: true,
                    cancelled: false,
                    statusMessage: "Status failed",
                    detailedOutput: "",
                    errorMessage: userFacingMessage(for: error)
                )
            }
        }
        await MainActor.run {
            let previousStatuses = statusStatusesByPath
            statusStatusesByPath = statuses
            for workspace in workspaceConfigs {
                let localPath = workspace.normalizedLocalDirectory
                guard let status = statuses[localPath], status.completed else { continue }
                let previous = previousStatuses[localPath]
                if previous?.running == true || previous?.statusMessage != status.statusMessage {
                    if !status.errorMessage.isEmpty {
                        showAlert(title: "Status Failed", message: status.errorMessage)
                    }
                    lastResultMessage = "\(workspace.displayName): \(status.statusMessage)"
                }
            }
            refreshMenu()
        }
    }

    // MARK: - Sync Targets

    func syncTargets(for workspace: WorkspaceConfig) -> [SyncTargetInfo] {
        syncTargetsByPath[workspace.normalizedLocalDirectory] ?? []
    }

    func loadSyncTargets(for workspace: WorkspaceConfig) {
        let localPath = workspace.normalizedLocalDirectory
        guard !localPath.isEmpty else { return }
        Task {
            do {
                let targets = try await Task.detached(priority: .userInitiated) {
                    try Bridge.listSyncTargets(localPath: localPath)
                }.value
                syncTargetsByPath[localPath] = targets
            } catch {
                // The directory does not host a configured workspace yet.
                syncTargetsByPath.removeValue(forKey: localPath)
            }
            refreshMenu()
        }
    }

    func loadAllSyncTargets() {
        for workspace in workspaceConfigs {
            loadSyncTargets(for: workspace)
        }
    }

    // True once the workspace's local directory hosts a configured cling
    // workspace whose sync targets have been read.
    func isWorkspaceConfigured(_ workspace: WorkspaceConfig) -> Bool {
        syncTargetsByPath[workspace.normalizedLocalDirectory] != nil
    }

    func beginAddSyncTarget() {
        guard let workspace = selectedSavedWorkspace else { return }
        guard let input = promptForSyncTarget() else { return }
        Task { _ = await addSyncTarget(name: input.name, uri: input.uri, to: workspace) }
    }

    @discardableResult
    func addSyncTarget(name: String, uri: String, to workspace: WorkspaceConfig) async -> Bool {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedURI = uri.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, !trimmedURI.isEmpty else { return false }
        do {
            try await performAddSyncTarget(workspace, name: trimmedName, uri: trimmedURI, password: nil)
            loadSyncTargets(for: workspace)
            return true
        } catch let bridgeError as BridgeError where bridgeError.isPassphraseRequired {
            guard let prompt = promptForPassphrase(for: workspace) else { return false }
            if prompt.rememberInKeychain {
                try? await storeWorkspacePassphrase(workspace, passphrase: prompt.passphrase)
            }
            do {
                try await performAddSyncTarget(
                    workspace, name: trimmedName, uri: trimmedURI, password: prompt.passphrase)
                loadSyncTargets(for: workspace)
                return true
            } catch {
                showAlert(
                    title: "Add Sync Target Failed",
                    message: userFacingMessage(for: error))
                return false
            }
        } catch {
            showAlert(
                title: "Add Sync Target Failed",
                message: userFacingMessage(for: error))
            return false
        }
    }

    func performAddSyncTarget(_ workspace: WorkspaceConfig, name: String, uri: String, password: String?) async throws {
        try await Task.detached(priority: .userInitiated) {
            try Bridge.addSyncTarget(
                localPath: workspace.normalizedLocalDirectory, name: name, uri: uri, password: password)
        }.value
    }

    func removeSelectedSyncTarget() {
        guard let workspace = selectedSavedWorkspace, let name = selectedSyncTargetName else { return }
        guard let target = syncTargets(for: workspace).first(where: { $0.name == name }) else { return }
        removeSyncTarget(target, from: workspace)
    }

    func removeSyncTarget(_ target: SyncTargetInfo, from workspace: WorkspaceConfig) {
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try Bridge.deleteSyncTarget(localPath: workspace.normalizedLocalDirectory, name: target.name)
                }.value
                selectedSyncTargetName = nil
                loadSyncTargets(for: workspace)
            } catch {
                showAlert(
                    title: "Remove Sync Target Failed",
                    message: userFacingMessage(for: error))
            }
        }
    }

    func promptForSyncTarget() -> (name: String, uri: String)? {
        while true {
            let alert = NSAlert()
            alert.messageText = "Add Sync Target"
            alert.informativeText =
                "Enter a name and the repository to mirror to. The repository can be a local folder "
                + "path or an s3+http(s) URL that includes its encrypted credentials."
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 56))
            let stack = NSStackView(frame: container.bounds)
            stack.orientation = .vertical
            stack.spacing = 8
            stack.alignment = .leading
            stack.autoresizingMask = [.width, .height]
            let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            nameField.placeholderString = "Name (letters, digits, '-')"
            nameField.setAccessibilityIdentifier("syncTargetNameField")
            let repoField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            repoField.placeholderString = "Folder path or s3+https://... URL"
            repoField.setAccessibilityIdentifier("syncTargetRepositoryField")
            stack.addArrangedSubview(nameField)
            stack.addArrangedSubview(repoField)
            container.addSubview(stack)
            alert.accessoryView = container
            alert.addButton(withTitle: "Add")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            alert.window.initialFirstResponder = nameField
            DispatchQueue.main.async {
                alert.window.makeFirstResponder(nameField)
            }
            if alert.runModal() != .alertFirstButtonReturn {
                return nil
            }
            let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let uri = repoField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty && !uri.isEmpty {
                return (name: name, uri: uri)
            }
        }
    }

    // MARK: - Sync

    func syncStatus(for workspace: WorkspaceConfig) -> MergeWorkspaceStatus {
        syncStatusesByPath[workspace.normalizedLocalDirectory]
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

    func syncShowsDetails(for workspace: WorkspaceConfig) -> Bool {
        syncShowsDetailsByPath[workspace.normalizedLocalDirectory] ?? false
    }

    func setSyncShowsDetails(_ showsDetails: Bool, for workspace: WorkspaceConfig) {
        syncShowsDetailsByPath[workspace.normalizedLocalDirectory] = showsDetails
    }

    var hasActiveSyncs: Bool {
        syncStatusesByPath.values.contains(where: { $0.running })
    }

    func startSyncFromMenu(_ workspace: WorkspaceConfig) async {
        guard !isBusy(workspace) else { return }
        errorMessage = ""
        do {
            try await startSyncWorkspace(workspace, password: nil)
        } catch let bridgeError as BridgeError where bridgeError.isNoSyncTargets {
            showAlert(
                title: "No Sync Targets",
                message: "Add a sync target for \(workspace.displayName) in Settings before syncing.")
        } catch let bridgeError as BridgeError where bridgeError.isPassphraseRequired {
            guard let prompt = promptForPassphrase(for: workspace) else { return }
            if prompt.rememberInKeychain {
                try? await storeWorkspacePassphrase(workspace, passphrase: prompt.passphrase)
            }
            do {
                try await startSyncWorkspace(workspace, password: prompt.passphrase)
            } catch {
                showAlert(
                    title: "Sync Failed",
                    message: userFacingMessage(for: error))
            }
        } catch {
            showAlert(
                title: "Sync Failed",
                message: userFacingMessage(for: error))
        }
    }

    func startSyncWorkspace(_ workspace: WorkspaceConfig, password: String?) async throws {
        let workers = syncWorkers
        // Reflect "in progress" and open the window up front, before the bridge's
        // pre-flight repository open (an S3 round trip that can take seconds), so
        // the menu and dialog respond immediately rather than after it returns.
        lastResultMessage = ""
        let runningStatus = MergeWorkspaceStatus(
            running: true,
            canCancel: true,
            completed: false,
            cancelled: false,
            upToDate: false,
            statusMessage: "Preparing sync...",
            detailedOutput: "",
            revisionId: "",
            errorMessage: ""
        )
        syncStatusesByPath[workspace.normalizedLocalDirectory] = runningStatus
        refreshMenu()
        showSyncProgressWindow(for: workspace)
        do {
            try await Task.detached(priority: .userInitiated) {
                try Bridge.startSyncWorkspace(
                    localPath: workspace.normalizedLocalDirectory,
                    password: password,
                    workers: workers,
                )
            }.value
        } catch {
            // The operation never started, so clear the optimistic "in progress"
            // state instead of leaving it stuck running.
            syncStatusesByPath[workspace.normalizedLocalDirectory] = MergeWorkspaceStatus(
                running: false,
                canCancel: false,
                completed: true,
                cancelled: false,
                upToDate: false,
                statusMessage: "Sync failed",
                detailedOutput: "",
                revisionId: "",
                errorMessage: userFacingMessage(for: error)
            )
            refreshMenu()
            throw error
        }
        beginSyncPolling()
    }

    func cancelSync(workspace: WorkspaceConfig) {
        Task {
            do {
                try await Task.detached(priority: .userInitiated) {
                    try Bridge.cancelSyncWorkspace(localPath: workspace.normalizedLocalDirectory)
                }.value
                beginSyncPolling()
            } catch {
                showAlert(
                    title: "Abort Sync Failed",
                    message: userFacingMessage(for: error),
                )
            }
        }
    }

    func beginSyncPolling() {
        drivePoller(
            syncPoller,
            hasActive: { [weak self] in self?.hasActiveSyncs ?? false },
            poll: { [weak self] in await self?.pollSyncStatuses() }
        )
    }

    func pollSyncStatuses() async {
        let workspaces = workspaceConfigs
        var statuses: [String: MergeWorkspaceStatus] = [:]
        for workspace in workspaces {
            let localPath = workspace.normalizedLocalDirectory
            guard !localPath.isEmpty else { continue }
            do {
                let status = try await Task.detached(priority: .userInitiated) {
                    try Bridge.getSyncWorkspaceStatus(localPath: localPath)
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
                    statusMessage: "Sync failed",
                    detailedOutput: "",
                    revisionId: "",
                    errorMessage: userFacingMessage(for: error)
                )
            }
        }
        await MainActor.run {
            let previousStatuses = syncStatusesByPath
            syncStatusesByPath = statuses
            for workspace in workspaceConfigs {
                let localPath = workspace.normalizedLocalDirectory
                guard let status = statuses[localPath], status.completed else { continue }
                let previous = previousStatuses[localPath]
                if previous?.running == true || previous?.statusMessage != status.statusMessage {
                    if !status.errorMessage.isEmpty {
                        showAlert(title: "Sync Failed", message: status.errorMessage)
                    }
                    lastResultMessage = "\(workspace.displayName): \(status.statusMessage)"
                }
            }
            refreshMenu()
        }
    }

    func showSyncProgressWindow(for workspace: WorkspaceConfig) {
        syncProgressWorkspaceID = workspace.id
        if let window = syncProgressWindow,
            let hostingController = window.contentViewController as? NSHostingController<SyncProgressView>
        {
            hostingController.rootView = SyncProgressView(controller: self, workspace: workspace)
            window.title = workspace.displayName + " Sync"
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return
        }

        let hostingController = NSHostingController(rootView: SyncProgressView(controller: self, workspace: workspace))
        let window = NSWindow(contentViewController: hostingController)
        window.title = workspace.displayName + " Sync"
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 760, height: 420))
        window.minSize = NSSize(width: 640, height: 320)
        window.center()
        window.level = .floating
        window.isReleasedWhenClosed = false
        window.delegate = self
        syncProgressWindow = window
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func closeSyncProgressWindow() {
        if let id = syncProgressWorkspaceID, let workspace = workspace(for: id) {
            syncStatusesByPath.removeValue(forKey: workspace.normalizedLocalDirectory)
        }
        syncProgressWindow?.close()
        syncProgressWindow = nil
        syncProgressWorkspaceID = nil
    }

    func showActiveProgressWindow(for workspace: WorkspaceConfig) {
        if mergeStatus(for: workspace).running {
            showMergeProgressWindow(for: workspace)
        } else if syncStatus(for: workspace).running {
            showSyncProgressWindow(for: workspace)
        } else if statusStatus(for: workspace).running {
            showStatusProgressWindow(for: workspace)
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

    @objc func handleStatusWorkspace(_ sender: NSMenuItem) {
        guard let id = workspaceID(from: sender), let workspace = workspace(for: id) else { return }
        let status = statusStatus(for: workspace)
        if status.running || status.completed {
            showStatusProgressWindow(for: workspace)
        } else {
            Task { await startStatusFromMenu(workspace) }
        }
    }
    @objc func handleMergeWorkspace(_ sender: NSMenuItem) {
        guard let id = workspaceID(from: sender), let workspace = workspace(for: id) else { return }
        let status = mergeStatus(for: workspace)
        if status.running || (status.completed && !status.errorMessage.isEmpty) {
            showMergeProgressWindow(for: workspace)
        } else {
            Task { await startMergeFromMenu(workspace) }
        }
    }
    @objc func handleOpenMergeProgress(_ sender: NSMenuItem) {
        guard let id = workspaceID(from: sender), let workspace = workspace(for: id) else { return }
        showMergeProgressWindow(for: workspace)
    }
    @objc func handleOpenActiveProgress(_ sender: NSMenuItem) {
        guard let id = workspaceID(from: sender), let workspace = workspace(for: id) else { return }
        showActiveProgressWindow(for: workspace)
    }
    @objc func handleSyncWorkspace(_ sender: NSMenuItem) {
        guard let id = workspaceID(from: sender), let workspace = workspace(for: id) else { return }
        if syncStatus(for: workspace).running {
            showSyncProgressWindow(for: workspace)
        } else {
            Task { await startSyncFromMenu(workspace) }
        }
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
