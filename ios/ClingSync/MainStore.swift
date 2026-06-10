import Photos
import SwiftUI
import UIKit

// swiftlint:disable file_length

// Terminal banner after an upload finishes, shown in the bottom bar. The share screen
// returns to the main app once a succeeded/failed banner is dismissed (not aborted).
enum UploadOutcome: Equatable {
    case succeeded(fileCount: Int, bytes: Int64)
    case failed(message: String)
    case aborted
}

// swiftlint:disable type_body_length

// The one stateful, impure layer of the MVI loop: it holds the immutable AppState, runs events
// through the pure reducers, and executes the resulting effects (connect, load, scan, upload, persist)
// as async pipelines whose results fold back into the state. Heavy bridge work stays off the main actor.
@MainActor
final class MainStore: ObservableObject {
    @Published private(set) var state: AppState
    @Published private(set) var uploadOutcome: UploadOutcome?

    let passphraseController: PassphrasePromptController
    let s3Controller: S3CredentialsPromptController

    private let settings: SettingsGateway
    private var source: SourceGateway
    private let repository: RepositoryGateway
    private let connector: RepositoryConnector
    private var scanner: ScanService
    private var uploader: UploadCoordinator
    private let isUITestMode: Bool
    // Set by the share flow (which reuses MainStore over a fixed shared-files source):
    // the upload goes to this target directory instead of the settings prefix.
    var shareTarget: String?

    // A share handed to the app is staged, then presented as a modal share screen.
    // The staging buffer + coalescing live in ShareStaging.swift.
    @Published var pendingShare: PendingShare?
    var stagedShareFiles: [(file: SourceFile, url: URL)] = []
    var shareCoalesceTask: Task<Void, Never>?

    private var connectTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
    // Set when the background grace close dropped the repository, so the next
    // foreground re-authenticates (biometric for a Keychain passphrase, prompt
    // otherwise).
    private var reopenOnForeground = false
    private var closeGraceTask: Task<Void, Never>?
    private var closeBackgroundTask: UIBackgroundTaskIdentifier = .invalid
    // Set when the background allowance expired while an upload was still running:
    // close the moment the upload ends, while its own background task still keeps
    // the process alive, instead of leaving the repository open all suspension long.
    private var closeWhenUploadEnds = false
    // The share screen's store points back at the main store, which coordinates the
    // background close for both.
    weak var backgroundCloseDelegate: MainStore?
    // The settings sheet's connection test, tracked so the background close can
    // cancel it; an untracked test could finish its open after the close and leave
    // the repository silently open in the background.
    private var testConnectionTask: Task<Void, Error>?
    // A brief background grace window. An interrupted transfer resumes from already-transferred blocks next time.
    private var uploadBackgroundTask: UIBackgroundTaskIdentifier = .invalid

    init(
        settings: SettingsGateway = UserDefaultsSettingsGateway(),
        source: SourceGateway = PhotoLibrarySource(),
        repository: RepositoryGateway = RepositoryGateway(),
        passphraseController: PassphrasePromptController? = nil,
        s3Controller: S3CredentialsPromptController? = nil,
        isUITestMode: Bool = ProcessInfo.processInfo.arguments.contains("--ui-test-mode")
    ) {
        self.settings = settings
        self.source = source
        self.repository = repository
        self.connector = RepositoryConnector(repository: repository, settings: settings)
        self.scanner = ScanService(source: source)
        self.uploader = UploadCoordinator(source: source)
        self.passphraseController = passphraseController ?? PassphrasePromptController()
        self.s3Controller = s3Controller ?? S3CredentialsPromptController()
        self.isUITestMode = isUITestMode
        self.state = AppState.initial(configuration: settings.load())
    }

    func dispatch(_ event: MainEvent) {
        let reduction = MainReducer.reduce(state, event)
        state = reduction.state
        for effect in reduction.effects {
            run(effect)
        }
    }

    private func run(_ effect: Effect) {
        switch effect {
        case .loadFiles:
            loadFiles()
        case .connect:
            connect(promptIfNeeded: true)
        case .enqueueUpload(let ids, let author):
            startUpload(ids: ids, author: author)
        case .cancelUpload:
            uploadTask?.cancel()
        case .persistSettings(let configuration):
            settings.save(configuration)
        case .invalidateRepository(let repositoryID):
            settings.invalidateRepository(repositoryID: repositoryID)
        }
    }

    // MARK: - Launch

    // Share startup: reuses the injected shared-files source (no stored photo/folder
    // selection) and connects eagerly so the shared files are scanned right away.
    // A cancelled prompt falls back to the connect banner for a retry.
    func onStartShare() {
        applyUITestConfiguration()
        state.configuration = settings.load()
        state.phase = .ready
        if state.configuration.isConfigured {
            connect(promptIfNeeded: true)
        } else {
            loadFiles()
        }
    }

    func onStart() {
        applyUITestConfiguration()
        applySource(settings.loadSourceSelection())
        let configuration = settings.load()
        state.configuration = configuration
        guard configuration.isConfigured else {
            state.phase = .needsSettings
            return
        }
        let stored = PassphraseStore.shared.hasStoredPassphrase(
            for: configuration.repositoryID, mode: settings.passphraseMode())
        if stored {
            state.phase = .connectingToServer
            connect(promptIfNeeded: false)
        } else {
            state.phase = .ready
            loadFiles()
        }
    }

    private func applyUITestConfiguration() {
        guard isUITestMode else { return }
        let env = ProcessInfo.processInfo.environment
        var configuration = settings.load()
        if configuration.hostURL.isEmpty, let host = env["CLING_SYNC_UI_TEST_HOST_URL"] {
            configuration = RepositoryConfiguration(
                hostURL: host, repoPathPrefix: configuration.repoPathPrefix, author: configuration.author)
        }
        if configuration.repoPathPrefix.isEmpty, let prefix = env["CLING_SYNC_UI_TEST_REPO_PATH_PREFIX"] {
            configuration = RepositoryConfiguration(
                hostURL: configuration.hostURL, repoPathPrefix: prefix, author: configuration.author)
        }
        if configuration.author.isEmpty, let author = env["CLING_SYNC_UI_TEST_AUTHOR"] {
            configuration = RepositoryConfiguration(
                hostURL: configuration.hostURL, repoPathPrefix: configuration.repoPathPrefix, author: author)
        }
        settings.save(configuration)
    }

    // MARK: - Background lifecycle

    // Close the repository only after this long in the background, so a quick app
    // switch costs no re-authentication. iOS grants roughly this much background
    // runtime; if it ends sooner, the task's expiration handler closes early.
    private static let backgroundCloseGraceSeconds: UInt64 = 30

    // The app left the foreground: drop the open repository after a grace period,
    // so the decrypted repository and its keys do not linger in memory. Armed
    // unconditionally: the repository can be open without any store flag showing
    // it (an abandoned repository after a settings switch, a share dismissed
    // mid-connect), and closing a closed repository is a no-op. The close waits
    // for a running upload (the main screen's or the share screen's) and runs as
    // soon as it finishes. A running scan survives the close: it answers from the
    // persisted hash index, which closeRepository keeps. Only the main store
    // receives scene-phase calls; it covers the share screen's store through
    // `pendingShare`.
    func enterBackground() {
        closeGraceTask?.cancel()
        closeWhenUploadEnds = false
        beginCloseBackgroundTask()
        closeGraceTask = Task {
            try? await Task.sleep(nanoseconds: Self.backgroundCloseGraceSeconds * NSEC_PER_SEC)
            while !Task.isCancelled, self.hasAnyActiveUpload {
                try? await Task.sleep(nanoseconds: NSEC_PER_SEC)
            }
            guard !Task.isCancelled else { return }
            self.closeForBackground()
        }
    }

    // Returning to the foreground. Within the grace period this just cancels the
    // pending close. After a close, re-open: when the share cover is up its store
    // reconnects (its prompt sheets present above the cover; the main store's
    // would be stuck beneath it) and the main store adopts the connection once
    // the share is dismissed. A Keychain passphrase unlocks via biometrics; a
    // session-only passphrase prompts.
    func enterForeground() {
        closeGraceTask?.cancel()
        closeGraceTask = nil
        closeWhenUploadEnds = false
        endCloseBackgroundTask()
        guard reopenOnForeground else { return }
        reopenOnForeground = false
        if let share = pendingShare?.store {
            share.connect(promptIfNeeded: true)
        } else {
            connect(promptIfNeeded: true)
        }
    }

    // After the share cover is gone, the main screen takes the connection back:
    // the share flow usually left the repository open (adopted silently, the
    // connector short-circuits), or the grace close dropped it while the cover
    // was up. Then a stored passphrase reopens via biometrics; without one the
    // screen stays disconnected, like a declined launch connect.
    func reconnectAfterShareDismissed() {
        guard !state.isConnected, !state.isConnecting else { return }
        connect(promptIfNeeded: false)
    }

    private var anyConnectionActive: Bool {
        let share = pendingShare?.store
        return state.isConnected || state.isConnecting
            || share?.state.isConnected == true || share?.state.isConnecting == true
    }

    private var hasAnyActiveUpload: Bool {
        state.isBusy || pendingShare?.store.state.isBusy == true
    }

    private func closeForBackground() {
        defer { endCloseBackgroundTask() }
        // The close must never land after the user is already back: a wait tick or
        // the expiration handler can race the foreground transition.
        guard UIApplication.shared.applicationState == .background else { return }
        guard !hasAnyActiveUpload else { return }
        // Reopen on return only when a screen showed a connection; the close also
        // drops repositories no flag tracks (after a settings switch or a test),
        // and those must not summon a prompt out of nowhere.
        let reopen = anyConnectionActive
        // Cancel in-flight connects first so no new open is issued; the close is
        // serialized behind a bridge open already in flight and so drops it too.
        noteRepositoryClosed()
        pendingShare?.store.noteRepositoryClosed()
        testConnectionTask?.cancel()
        try? Bridge.closeRepository()
        if reopen {
            reopenOnForeground = true
        }
    }

    // On the main store: the grace close defers to a running upload (of either
    // store); when the background allowance expired mid-upload, close the moment
    // the upload ends, while its background task still keeps the process alive.
    func uploadEnded() {
        guard closeWhenUploadEnds else { return }
        closeWhenUploadEnds = false
        closeForBackground()
    }

    // Folds the background close into this store's state: an in-flight connect is
    // cancelled (its success would record a connection the bridge no longer has)
    // and the connection flags drop without surfacing an error.
    private func noteRepositoryClosed() {
        connectTask?.cancel()
        passphraseController.cancel()
        s3Controller.cancel()
        state.isConnecting = false
        state.isConnected = false
    }

    private func beginCloseBackgroundTask() {
        endCloseBackgroundTask()
        closeBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ClingSyncClose") { [weak self] in
            // Called on the main thread when iOS is about to suspend the app before
            // the grace ran out. Run synchronously: an async hop might never execute
            // before the process freezes, and the allowance is about as long as the
            // grace, so this is the close that usually fires. With an upload still
            // running (it holds its own background task), close as soon as it ends.
            MainActor.assumeIsolated {
                guard let self else { return }
                self.closeGraceTask?.cancel()
                self.closeGraceTask = nil
                if self.hasAnyActiveUpload {
                    self.closeWhenUploadEnds = true
                    self.endCloseBackgroundTask()
                } else {
                    self.closeForBackground()
                }
            }
        }
    }

    private func endCloseBackgroundTask() {
        guard closeBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(closeBackgroundTask)
        closeBackgroundTask = .invalid
    }

    // MARK: - Connect

    private func connect(promptIfNeeded: Bool) {
        connectTask?.cancel()
        // Resume any prompt the superseded connect was awaiting, so its task can't leak.
        passphraseController.cancel()
        s3Controller.cancel()
        connectTask = Task { await self.connectFlow(promptIfNeeded: promptIfNeeded) }
    }

    private func connectFlow(promptIfNeeded: Bool) async {
        let configuration = state.configuration
        guard configuration.isConfigured else {
            state.phase = .needsSettings
            return
        }
        dispatch(.connectStarted)
        do {
            try await connector.connect(
                configuration, promptIfNeeded: promptIfNeeded,
                passphrase: passphraseController, s3: s3Controller)
            connectSucceeded()
        } catch is ConnectDeclined {
            declineConnect()
        } catch let error as PassphraseStoreError where error.cancelled {
            declineConnect()
        } catch is CancellationError {
            declineConnect()
        } catch let error as BridgeError {
            failConnect(error.message)
        } catch let error as PassphraseStoreError {
            failConnect(error.message)
        } catch {
            failConnect(error.localizedDescription)
        }
    }

    // Bridge calls don't observe cancellation, so a superseded connect must guard here against folding stale state in.
    private func failConnect(_ message: String) {
        guard !Task.isCancelled else { return }
        dispatch(.connectFailed(message))
    }

    // A declined prompt is not a failure: return to ready, disconnected, not the connection-failed state.
    private func declineConnect() {
        guard !Task.isCancelled else { return }
        state.isConnecting = false
        state.phase = .ready
        loadFiles()
    }

    private func connectSucceeded() {
        guard !Task.isCancelled else { return }
        dispatch(.connectSucceeded)
        if state.files.isEmpty {
            loadFiles()
        } else {
            startScan(state.files)
        }
    }

    // MARK: - Files & scanning

    private func loadFiles() {
        // A reload cancels the in-flight scan, or it writes the old repo's membership into the new list.
        scanTask?.cancel()
        dispatch(.loadingStarted)
        Task {
            let files = await self.source.loadFiles()
            self.dispatch(.filesLoaded(files))
            // An empty folder source usually means the bookmark was revoked or moved, so surface it.
            if files.isEmpty, case .folder = self.settings.loadSourceSelection(), self.state.overlay == .none {
                self.state.overlay = .error(
                    title: "No Files Found",
                    message: "No files were found in the selected folder, or access to it was lost. "
                        + "Choose the folder again in Settings.")
            }
            if self.state.isConnected {
                self.startScan(files)
            }
        }
    }

    private func startScan(_ files: [SourceFile]) {
        let unscanned = files.filter { isUnscanned(state.fileStatus[$0.id]) }
        guard !unscanned.isEmpty else { return }
        let ids = unscanned.map(\.id)
        dispatch(.scanStarted(ids: ids))
        scanTask?.cancel()
        scanTask = Task {
            do {
                try await self.scanner.scan(unscanned) { processed, statuses in
                    await self.dispatch(.scanProgress(processed: processed, total: ids.count, statuses: statuses))
                }
                self.dispatch(.scanCompleted(statuses: [:]))
                // On the share screen, pre-select every not-already-uploaded file so
                // the user can upload straight away (the main screen selects nothing).
                if self.shareTarget != nil {
                    self.dispatch(.selectAllClicked)
                }
            } catch is CancellationError {
            } catch {
                self.dispatch(.scanFailed(message: error.localizedDescription, ids: ids))
            }
        }
    }

    // MARK: - Upload

    private func startUpload(ids: [String], author: String) {
        // A live scan shares the unsynchronized bridge globals and would clobber upload statuses, so stop it.
        scanTask?.cancel()
        uploadOutcome = nil
        beginUploadBackgroundTask()
        let files = state.files.filter { ids.contains($0.id) }
        let prefix = shareTarget ?? state.configuration.repoPathPrefix
        let deviceName = UIDevice.current.name
        uploadTask = Task {
            await self.uploader.upload(
                files, repoPathPrefix: prefix, author: author, deviceName: deviceName
            ) { update in
                await self.applyWorkUpdate(update)
            }
        }
    }

    private func applyWorkUpdate(_ update: WorkUpdate) {
        let priorCount = state.currentUploadIds.count
        let priorBytes = state.uploadedBytes
        state = UploadReducer.reduce(state, update)
        switch update {
        case .succeeded:
            uploadOutcome = .succeeded(fileCount: priorCount, bytes: priorBytes)
            endUploadBackgroundTask()
        case .cancelled:
            uploadOutcome = .aborted
            endUploadBackgroundTask()
        case .failed(let error):
            uploadOutcome = .failed(message: error)
            endUploadBackgroundTask()
        case .enqueued, .running:
            return
        }
        (backgroundCloseDelegate ?? self).uploadEnded()
    }

    private func beginUploadBackgroundTask() {
        endUploadBackgroundTask()
        uploadBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ClingSyncUpload") { [weak self] in
            // Grace expired. UIKit may call this off the main thread, so hop. Cancelling is safe and resumes later.
            Task { @MainActor in
                self?.uploadTask?.cancel()
                self?.endUploadBackgroundTask()
            }
        }
    }

    private func endUploadBackgroundTask() {
        guard uploadBackgroundTask != .invalid else { return }
        UIApplication.shared.endBackgroundTask(uploadBackgroundTask)
        uploadBackgroundTask = .invalid
    }

    func dismissUploadOutcome() {
        uploadOutcome = nil
    }

    func thumbnail(for file: SourceFile) async -> UIImage? {
        await source.thumbnail(for: file)
    }

    // MARK: - Source selection

    var sourceSelection: SourceSelection { settings.loadSourceSelection() }

    func selectSource(_ selection: SourceSelection) {
        // Never swap the source out from under an in-flight upload, whose task captured the old coordinator.
        guard !state.isBusy else { return }
        settings.save(sourceSelection: selection)
        applySource(selection)
        state.fileStatus = [:]
        state.selectedIds = []
        loadFiles()
    }

    private func applySource(_ selection: SourceSelection) {
        source = makeSource(selection)
        scanner = ScanService(source: source)
        uploader = UploadCoordinator(source: source)
    }

    private func makeSource(_ selection: SourceSelection) -> SourceGateway {
        switch selection {
        case .photoLibrary:
            return PhotoLibrarySource(isUITestMode: isUITestMode)
        case .folder(let bookmark):
            return FolderSource(bookmark: bookmark)
        }
    }

    // Applies saved settings through the reducer. Moving to a different repository clears any stale upload result.
    func handleSettingsSaved(_ configuration: RepositoryConfiguration) {
        if state.configuration.repositoryID != configuration.repositoryID {
            uploadOutcome = nil
            // The new repository must not inherit an in-flight connect: its late
            // success would mark the app connected while the bridge still holds
            // the old repository, and uploads would land there.
            connectTask?.cancel()
            passphraseController.cancel()
            s3Controller.cancel()
        }
        dispatch(.settingsSaved(configuration))
    }

    // Runs the connect pipeline with prompting always on, then folds a successful connection into state.
    // It throws on failure rather than moving to an error phase, so the outcome reaches the caller.
    func testConnection(
        _ configuration: RepositoryConfiguration,
        passphrase: PassphrasePromptController,
        s3 s3Controller: S3CredentialsPromptController
    ) async throws {
        let task = Task {
            try await connector.connect(configuration, promptIfNeeded: true, passphrase: passphrase, s3: s3Controller)
        }
        testConnectionTask = task
        defer { testConnectionTask = nil }
        do {
            try await task.value
        } catch {
            await resyncAfterFailedTest()
            throw error
        }
        // Testing a different repository IS a switch (the bridge holds a single
        // repository), so the old repository's scan results must not survive it,
        // or its already-backed-up marks would suppress uploads to the new one.
        if state.configuration.repositoryID != configuration.repositoryID {
            state.fileStatus = [:]
            state.selectedIds = []
        }
        state.configuration = configuration
        uploadOutcome = nil
        connectSucceeded()
    }

    // A test that touched a different repository closed the live one (checking a
    // mismatched host closes it in the bridge). Put the screen back into an honest
    // state and try to reopen the previous repository without prompting.
    private func resyncAfterFailedTest() async {
        guard state.isConnected else { return }
        if await repository.isAlreadyOpen(hostURL: state.configuration.hostURL).open {
            return
        }
        state.isConnected = false
        connect(promptIfNeeded: false)
    }
}

// swiftlint:enable type_body_length

// MainStore is the single owner of the active upload, so the share screen consults
// it to honor the "abort the running upload first" rule.
extension MainStore: ActiveUploadGuard {
    var hasActiveUpload: Bool { state.isBusy }

    func abortActiveUpload() async {
        dispatch(.abortClicked)
        await uploadTask?.value
    }
}

// A file with no scan status yet, or reset to New, still needs checking. A stale
// `.checking` (its scan was cancelled mid-flight) is rechecked the same way, or it
// would be stranded unscannable for the rest of the session.
private func isUnscanned(_ status: FileStatus?) -> Bool {
    switch status {
    case .none, .new, .checking:
        return true
    default:
        return false
    }
}
