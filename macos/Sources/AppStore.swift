import AppKit

// The one stateful, impure layer. Holds the immutable AppState, runs the pure
// reducer on every event, then performs the emitted effects (bridge calls,
// prompts, timers, polling). The view layer observes `state` and dispatches
// events; it never touches the bridge or the reducer's internals.
@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var state = AppState()

    private let gateway: WorkspaceGateway
    private let settings: SettingsGateway
    private let prompter: Prompter
    private let notifier: Notifier
    private let clock: () -> Date
    private let isTestMode: Bool

    // Set by the AppDelegate; used to front already-open windows (a transient command
    // with no state to render). Weak: the coordinator outlives the store either way.
    weak var windowFronter: (any WindowFronting)?

    // A status poller's task plus a flag an operation sets when it registers while
    // the poller is winding down, so the poller does one more pass and never leaves
    // a freshly started operation unobserved.
    @MainActor
    private final class Poller {
        var task: Task<Void, Never>?
        var restartRequested = false
    }

    private let mergePoller = Poller()
    private let statusPoller = Poller()
    private let syncPoller = Poller()
    private var autoMergeTimer: Timer?
    private var staleCheckTimer: Timer?
    private var manualAutoMergeTimer: Timer?
    private var manualReminderTimer: Timer?

    // Security-scoped folder URLs held open for the app's lifetime, keyed by path.
    private var directoryAccessURLs: [String: URL] = [:]

    // prompter/notifier are @MainActor types, so they cannot be default-arg values
    // (default args evaluate in a nonisolated context); default them nil and build
    // them in this @MainActor init body.
    init(
        gateway: WorkspaceGateway = RealWorkspaceGateway(),
        settings: SettingsGateway = UserDefaultsSettingsGateway(),
        prompter: Prompter? = nil,
        notifier: Notifier? = nil,
        clock: @escaping () -> Date = { Date() },
        isTestMode: Bool = ProcessInfo.processInfo.environment["CLING_SYNC_TEST_MENU_HOST"] == "1"
    ) {
        self.gateway = gateway
        self.settings = settings
        self.prompter = prompter ?? AppKitPrompter()
        self.notifier = notifier ?? UserNotificationsNotifier()
        self.clock = clock
        self.isTestMode = isTestMode
    }

    func dispatch(_ event: AppEvent) {
        let reduction = AppReducer.reduce(state, event)
        state = reduction.state
        for effect in reduction.effects { run(effect) }
    }

    // Launch orchestration (not a reducer event): load persisted state, hold folder
    // access, then reattach any operation a prior session left running in the bridge.
    func onStart() {
        let configs = settings.loadWorkspaceConfigs()
        for config in configs { activateDirectoryAccess(for: config) }
        dispatch(
            .stateLoaded(
                workspaces: configs, tracking: settings.loadTracking(), settings: settings.loadAppSettings(),
                now: clock()))
        for kind in OperationKind.allCases { beginPolling(kind) }
        // With nothing configured, open Settings on a fresh starter workspace so the
        // editor is ready immediately (matching the old launch -> showPreferences).
        if state.workspaces.isEmpty { dispatch(.openPreferencesClicked) }
    }

    // swiftlint:disable:next cyclomatic_complexity
    private func run(_ effect: Effect) {
        switch effect {
        case .persistWorkspaces:
            settings.saveWorkspaceConfigs(state.workspaces.map(\.config))
        case .persistMergeTracking:
            settings.saveTracking(MergeTracking(from: state.workspaces))
        case .persistSetting(let key, let value):
            settings.saveSetting(key, value)
        case .startOperation(let id, let kind, let isAutoMerge):
            startOperation(id: id, kind: kind, isAutoMerge: isAutoMerge)
        case .cancelOperation(let id, let kind):
            cancelOperation(id: id, kind: kind)
        case .beginPolling(let kind):
            beginPolling(kind)
        case .runTestDraft(let config):
            runTestDraft(config)
        case .chooseLocalDirectory:
            chooseLocalDirectory()
        case .refreshMergeMtimes:
            refreshMergeMtimes()
        case .loadSyncTargets(let id):
            loadSyncTargets(id: id)
        case .promptAndAddSyncTarget(let id):
            promptAndAddSyncTarget(id: id)
        case .removeSyncTarget(let id, let name):
            removeSyncTarget(id: id, name: name)
        case .clearWorkspacePassphrase(let uri):
            Task { try? await gateway.clearWorkspacePassphrase(uri: uri) }
        case .activateDirectoryAccess(let config):
            activateDirectoryAccess(for: config)
        case .deactivateDirectoryAccess(let path):
            deactivateDirectoryAccess(forPath: path)
        case .rescheduleAutoMerge:
            rescheduleAutoMerge()
        case .rescheduleStaleCheck:
            rescheduleStaleCheck()
        case .focusPreferences:
            windowFronter?.focusPreferences()
        case .focusProgressWindow(let id, let kind):
            windowFronter?.focusProgressWindow(id: id, kind: kind)
        case .postNotification(let id, let title, let body):
            if !isTestMode { notifier.post(id: id, title: title, body: body) }
        case .showAlert(let title, let message):
            Task { await prompter.alert(title: title, message: message) }
        case .openLocalFolder(let path):
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        case .quit:
            NSApp.terminate(nil)
        }
    }

    // MARK: - Operations

    // The optimistic running state is already set by the reducer; here we run the
    // bridge start, prompt for a passphrase if required (manual only), and on a
    // successful retry store it in the keychain ONLY AFTER success (Bug A). A failed
    // start clears back to a terminal failure via the reducer; a cancelled prompt
    // returns to idle.
    private func startOperation(id: UUID, kind: OperationKind, isAutoMerge: Bool) {
        guard let workspace = state.workspace(id) else { return }
        let path = workspace.localPath
        let name = workspace.config.displayName
        let author = workspace.config.normalizedAuthor
        let workers = state.syncWorkers
        Task {
            do {
                try await callStart(kind, path: path, author: author, workers: workers, password: nil)
                beginPolling(kind)
            } catch let error as BridgeError where error.isNoSyncTargets {
                await prompter.alert(
                    title: "No Sync Targets",
                    message: "Add a sync target for \(name) in Settings before syncing.")
                dispatch(.operationStartCancelled(id: id, kind: kind))
            } catch let error as BridgeError where error.isPassphraseRequired && !isAutoMerge {
                guard let prompt = await prompter.passphrase(workspaceName: name) else {
                    dispatch(.operationStartCancelled(id: id, kind: kind))
                    return
                }
                do {
                    try await callStart(kind, path: path, author: author, workers: workers, password: prompt.passphrase)
                    // The save runs after the start proves the passphrase, so it cannot
                    // persist a wrong one. A save that fails still has to be reported:
                    // remembering nothing leaves every later auto-merge failing with
                    // "passphrase required" and no clue why, because an auto-merge has
                    // no prompt to fall back on.
                    if prompt.rememberInKeychain {
                        try await gateway.storeWorkspacePassphrase(localPath: path, password: prompt.passphrase)
                    }
                    beginPolling(kind)
                } catch {
                    dispatch(
                        .operationStartFailed(
                            id: id, kind: kind, message: userFacingMessage(for: error),
                            isNetwork: isNetwork(error), isAutoMerge: isAutoMerge))
                }
            } catch {
                dispatch(
                    .operationStartFailed(
                        id: id, kind: kind, message: userFacingMessage(for: error),
                        isNetwork: isNetwork(error), isAutoMerge: isAutoMerge))
            }
        }
    }

    private func callStart(_ kind: OperationKind, path: String, author: String, workers: Int, password: String?)
        async throws
    {
        switch kind {
        case .merge: try await gateway.startMerge(localPath: path, password: password, author: author)
        case .status: try await gateway.startStatus(localPath: path, password: password)
        case .sync: try await gateway.startSync(localPath: path, password: password, workers: workers)
        }
    }

    private func cancelOperation(id: UUID, kind: OperationKind) {
        guard let path = state.workspace(id)?.localPath else { return }
        Task {
            do {
                try await gateway.cancel(kind: kind, localPath: path)
                beginPolling(kind)
            } catch {
                await prompter.alert(title: kind.cancelFailureAlertTitle, message: userFacingMessage(for: error))
            }
        }
    }

    // MARK: - Polling

    private func beginPolling(_ kind: OperationKind) {
        drivePoller(
            poller(for: kind),
            hasActive: { [weak self] in self?.state.hasRunning(kind) ?? false },
            poll: { [weak self] in await self?.pollStatuses(kind) })
    }

    private func pollStatuses(_ kind: OperationKind) async {
        let targets = state.workspaces.map { (id: $0.id, path: $0.localPath) }
        for target in targets where !target.path.isEmpty {
            let update: WorkUpdate
            do {
                let progress = try await gateway.poll(kind: kind, localPath: target.path)
                update = progress.isEmptyRow ? .absent : .snapshot(OperationState.from(progress))
            } catch {
                update = .snapshot(
                    .finished(.failed(message: userFacingMessage(for: error), detail: "", isNetwork: isNetwork(error))))
            }
            dispatch(.workUpdated(id: target.id, kind: kind, update: update, now: clock()))
        }
    }

    // Clearing poller.task and re-checking restartRequested happen together on the
    // main actor (no await between), so an operation that registered while the task
    // was winding down restarts the poller instead of being stranded.
    private func drivePoller(_ poller: Poller, hasActive: @escaping () -> Bool, poll: @escaping () async -> Void) {
        if poller.task != nil {
            poller.restartRequested = true
            return
        }
        poller.task = Task { [weak self] in
            guard self != nil else { return }
            while true {
                await poll()
                if hasActive() {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    continue
                }
                if poller.restartRequested {
                    poller.restartRequested = false
                    continue
                }
                poller.task = nil
                return
            }
        }
    }

    private func poller(for kind: OperationKind) -> Poller {
        switch kind {
        case .merge: return mergePoller
        case .status: return statusPoller
        case .sync: return syncPoller
        }
    }

    // MARK: - Timers

    // A zero interval or test mode leaves the timer off. While a repository is
    // unreachable the interval drops so the merge resumes soon after recovery.
    private func rescheduleAutoMerge() {
        autoMergeTimer?.invalidate()
        autoMergeTimer = nil
        guard state.autoMergeIntervalHours > 0, !isTestMode else { return }
        notifier.requestAuthorization()
        let interval =
            state.autoMergeBackoffActive
            ? AutoMergePolicy.backoffInterval
            : TimeInterval(state.autoMergeIntervalHours) * 3600
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.fireAutoMerge() }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoMergeTimer = timer
    }

    private func rescheduleStaleCheck() {
        staleCheckTimer?.invalidate()
        staleCheckTimer = nil
        guard state.notifyStaleDays > 0, !isTestMode else { return }
        notifier.requestAuthorization()
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.dispatch(.staleCheckTimerFired(now: self?.clock() ?? Date())) }
        }
        RunLoop.main.add(timer, forMode: .common)
        staleCheckTimer = timer
        dispatch(.staleCheckTimerFired(now: clock()))
    }

    // Runs an auto-merge for every folder after a few seconds (the Options "try it"
    // button). Drives the same path the repeating timer does. A tick that lands while
    // every folder is busy is dropped, and this timer is the only thing that would
    // have delivered it, so it keeps re-firing until a folder is idle. Without that
    // the button silently does nothing at all and never reports why.
    func scheduleAutoMergeSoon() {
        notifier.requestAuthorization()
        manualAutoMergeTimer?.invalidate()
        let giveUpAt = clock().addingTimeInterval(AutoMergePolicy.manualRetryWindow)
        let timer = Timer(timeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if self.state.autoMergeTargets.isEmpty, self.clock() < giveUpAt { return }
                self.manualAutoMergeTimer?.invalidate()
                self.manualAutoMergeTimer = nil
                self.fireAutoMerge()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        manualAutoMergeTimer = timer
    }

    // Fires a forced reminder notification for every folder after a few seconds (the
    // Options "test reminder" button), to verify the notification path on demand.
    func scheduleReminderSoon() {
        notifier.requestAuthorization()
        manualReminderTimer?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.dispatch(.testReminderRequested) }
        }
        RunLoop.main.add(timer, forMode: .common)
        manualReminderTimer = timer
    }

    private func fireAutoMerge() {
        dispatch(.autoMergeTimerFired(now: clock()))
    }

    // MARK: - Test / save flow

    private func runTestDraft(_ config: WorkspaceConfig) {
        Task {
            do {
                let verified =
                    isFileRepositoryPath(config.normalizedHostURL)
                    ? try await testFileRepository(config)
                    : try await testS3Repository(config)
                if let verified {
                    dispatch(.testDraftSucceeded(verified: verified, now: clock()))
                } else {
                    dispatch(.testDraftCancelled)
                }
            } catch {
                dispatch(.testDraftFailed(message: userFacingMessage(for: error)))
            }
        }
    }

    private func testFileRepository(_ config: WorkspaceConfig) async throws -> WorkspaceConfig? {
        let exists = try await gateway.checkFileRepositoryExists(localPath: config.bridgeRepositoryURI)
        if !exists {
            guard await prompter.confirmCreateRepository(at: config.normalizedHostURL),
                let passphrase = await prompter.newRepositoryPassphrase(at: config.normalizedHostURL)
            else {
                return nil
            }
            try await gateway.initNewFileRepository(localPath: config.bridgeRepositoryURI, password: passphrase)
            try await configure(config)
            try await gateway.testWorkspaceAccess(localPath: config.normalizedLocalDirectory, password: passphrase)
            return config
        }
        try await configure(config)
        return try await testAccessPromptingIfNeeded(config)
    }

    private func testS3Repository(_ config: WorkspaceConfig) async throws -> WorkspaceConfig? {
        var config = config
        if WorkspaceConfig.s3URIHasEmbeddedCredentials(config.normalizedHostURL) {
            config.repositoryURI = config.normalizedHostURL
            config.hostURL = WorkspaceConfig.displayURL(forRepositoryURI: config.normalizedHostURL)
        }
        if config.needsS3Credentials {
            guard let prompt = await prompter.passphrase(workspaceName: config.displayName),
                let creds = await prompter.s3Credentials(hostURL: config.normalizedHostURL)
            else {
                return nil
            }
            config.repositoryURI = try await gateway.encodeS3URI(
                hostURL: config.normalizedHostURL, passphrase: prompt.passphrase,
                accessKeyId: creds.accessKeyId, accessKey: creds.accessKey)
            try await configure(config)
            try await gateway.testWorkspaceAccess(
                localPath: config.normalizedLocalDirectory, password: prompt.passphrase)
            if prompt.rememberInKeychain {
                try await gateway.storeWorkspacePassphrase(
                    localPath: config.normalizedLocalDirectory, password: prompt.passphrase)
            }
            return config
        }
        try await configure(config)
        return try await testAccessPromptingIfNeeded(config)
    }

    private func testAccessPromptingIfNeeded(_ config: WorkspaceConfig) async throws -> WorkspaceConfig? {
        do {
            try await gateway.testWorkspaceAccess(localPath: config.normalizedLocalDirectory, password: nil)
            return config
        } catch let error as BridgeError where error.isPassphraseRequired {
            guard let prompt = await prompter.passphrase(workspaceName: config.displayName) else { return nil }
            try await gateway.testWorkspaceAccess(
                localPath: config.normalizedLocalDirectory, password: prompt.passphrase)
            if prompt.rememberInKeychain {
                try await gateway.storeWorkspacePassphrase(
                    localPath: config.normalizedLocalDirectory, password: prompt.passphrase)
            }
            return config
        }
    }

    private func configure(_ config: WorkspaceConfig) async throws {
        try await gateway.configureWorkspace(
            uri: config.bridgeRepositoryURI, localPath: config.normalizedLocalDirectory,
            repoPathPrefix: config.normalizedRepoPathPrefix)
    }

    // MARK: - Sync targets

    private func loadSyncTargets(id: UUID) {
        guard let path = state.workspace(id)?.localPath, !path.isEmpty else { return }
        Task {
            let targets = try? await gateway.listSyncTargets(localPath: path)
            dispatch(.syncTargetsLoaded(id: id, targets: targets))
        }
    }

    private func refreshMergeMtimes() {
        let targets = state.workspaces.map { (id: $0.id, path: $0.localPath) }
        Task {
            var dates: [UUID: Date] = [:]
            for target in targets where !target.path.isEmpty {
                if let date = await gateway.lastMergeDate(localPath: target.path) { dates[target.id] = date }
            }
            dispatch(.mergeMtimesRefreshed(dates))
        }
    }

    private func promptAndAddSyncTarget(id: UUID) {
        guard let workspace = state.workspace(id) else { return }
        Task {
            guard let input = await prompter.syncTarget() else { return }
            let name = input.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let uri = input.uri.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !uri.isEmpty else { return }
            await performAddSyncTarget(workspace, name: name, uri: uri)
        }
    }

    private func performAddSyncTarget(_ workspace: WorkspaceState, name: String, uri: String) async {
        let path = workspace.localPath
        do {
            try await gateway.addSyncTarget(localPath: path, name: name, uri: uri, password: nil)
            dispatch(.syncTargetAdded(id: workspace.id))
        } catch let error as BridgeError where error.isPassphraseRequired {
            guard let prompt = await prompter.passphrase(workspaceName: workspace.config.displayName) else { return }
            do {
                try await gateway.addSyncTarget(localPath: path, name: name, uri: uri, password: prompt.passphrase)
                if prompt.rememberInKeychain {
                    try? await gateway.storeWorkspacePassphrase(localPath: path, password: prompt.passphrase)
                }
                dispatch(.syncTargetAdded(id: workspace.id))
            } catch {
                dispatch(
                    .syncTargetActionFailed(title: "Add Sync Target Failed", message: userFacingMessage(for: error)))
            }
        } catch {
            dispatch(.syncTargetActionFailed(title: "Add Sync Target Failed", message: userFacingMessage(for: error)))
        }
    }

    private func removeSyncTarget(id: UUID, name: String) {
        guard let path = state.workspace(id)?.localPath else { return }
        Task {
            do {
                try await gateway.deleteSyncTarget(localPath: path, name: name)
                dispatch(.syncTargetRemoved(id: id))
            } catch {
                dispatch(
                    .syncTargetActionFailed(title: "Remove Sync Target Failed", message: userFacingMessage(for: error)))
            }
        }
    }

    // MARK: - Local directory

    private func chooseLocalDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        if !state.draftConfig.localDirectory.isEmpty {
            panel.directoryURL = URL(fileURLWithPath: state.draftConfig.localDirectory)
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        var draft = state.draftConfig
        draft.localDirectory = url.path
        draft.localDirectoryBookmark = try? url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
        draft.verifiedAccessSignature = ""
        activateDirectoryAccess(for: draft)
        Task {
            var inspectionError: String?
            var foundRepository = false
            do {
                let inspection = try await gateway.inspect(localPath: url.path)
                if inspection.exists {
                    foundRepository = true
                    draft.repositoryURI = inspection.hostURL
                    draft.hostURL = WorkspaceConfig.displayURL(forRepositoryURI: inspection.hostURL)
                    draft.repoPathPrefix = inspection.repoPathPrefix
                    if inspection.hasStoredAccess { draft.verifiedAccessSignature = draft.accessSignature }
                }
            } catch {
                inspectionError = userFacingMessage(for: error)
            }
            dispatch(.chooseLocalDirectoryCompleted(draft: draft, inspectionError: inspectionError, now: clock()))
            if foundRepository { loadSyncTargets(id: draft.id) }
        }
    }

    // In the sandbox a user-selected folder is only reachable while its bookmark is
    // resolved and access is held open; we keep it open for the app's lifetime.
    private func activateDirectoryAccess(for config: WorkspaceConfig) {
        let path = config.normalizedLocalDirectory
        guard !path.isEmpty, directoryAccessURLs[path] == nil, let bookmark = config.localDirectoryBookmark else {
            return
        }
        var isStale = false
        guard
            let url = try? URL(
                resolvingBookmarkData: bookmark, options: .withSecurityScope,
                relativeTo: nil, bookmarkDataIsStale: &isStale),
            url.startAccessingSecurityScopedResource()
        else {
            return
        }
        directoryAccessURLs[path] = url
    }

    private func deactivateDirectoryAccess(forPath path: String) {
        guard let url = directoryAccessURLs.removeValue(forKey: path) else { return }
        url.stopAccessingSecurityScopedResource()
    }

    // MARK: - Error mapping

    // The sandbox drops a workspace folder's access once its security scope is gone,
    // so the bridge's local_access_denied code becomes guidance to re-pick the folder.
    private func userFacingMessage(for error: Error) -> String {
        if let bridgeError = error as? BridgeError, bridgeError.isLocalAccessDenied {
            return "macOS is blocking access to this workspace’s folder. "
                + "Open Settings and use “Browse...” under Local Folder to select the folder again and restore access."
        }
        return (error as? BridgeError)?.message ?? error.localizedDescription
    }

    private func isNetwork(_ error: Error) -> Bool {
        (error as? BridgeError)?.isNetworkError ?? false
    }

    private func isFileRepositoryPath(_ hostURL: String) -> Bool {
        let lower = hostURL.lowercased()
        return !lower.hasPrefix("http://") && !lower.hasPrefix("https://") && !lower.hasPrefix("s3+")
    }
}
