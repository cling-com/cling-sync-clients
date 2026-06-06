import Photos
import SwiftUI
import UIKit

// Terminal banner after an upload finishes. A failed upload surfaces through `state.overlay` instead.
enum UploadOutcome: Equatable {
    case succeeded(fileCount: Int, bytes: Int64)
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
    private var scanner: ScanService
    private var uploader: UploadCoordinator
    private let isUITestMode: Bool

    private var connectTask: Task<Void, Never>?
    private var scanTask: Task<Void, Never>?
    private var uploadTask: Task<Void, Never>?
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
            try await runConnect(
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

    // The shared connect pipeline: opens the repository (a no-op if already open), prompting for the passphrase
    // and S3 credentials through the given controllers. Throws ConnectDeclined if no passphrase is available.
    private func runConnect(
        _ configuration: RepositoryConfiguration,
        promptIfNeeded: Bool,
        passphrase: PassphrasePromptController,
        s3 s3Controller: S3CredentialsPromptController
    ) async throws {
        if await repository.isAlreadyOpen(hostURL: configuration.hostURL).open {
            return
        }
        guard
            let access = try await requestPassphrase(
                configuration, promptIfNeeded: promptIfNeeded, controller: passphrase)
        else {
            throw ConnectDeclined()
        }
        try await Bridge.triggerNetworkPermissionIfNeeded(url: configuration.hostURL)
        _ = try await repository.open(
            hostURL: configuration.hostURL,
            passphrase: access.passphrase,
            askS3: { try await s3Controller.prompt(hostURL: configuration.hostURL) })
        if access.mode.savesInKeychain {
            try PassphraseStore.shared.save(
                passphrase: access.passphrase, for: configuration.repositoryID, mode: access.mode)
        }
        settings.save(passphraseMode: access.mode)
    }

    private func requestPassphrase(
        _ configuration: RepositoryConfiguration,
        promptIfNeeded: Bool,
        controller: PassphrasePromptController
    ) async throws -> (passphrase: String, mode: PassphraseStorageMode)? {
        let mode = settings.passphraseMode()
        if let stored = try PassphraseStore.shared.loadIfAvailable(
            for: configuration.repositoryID, mode: mode, prompt: "Unlock the repository passphrase.")
        {
            return (stored, mode)
        }
        guard promptIfNeeded else { return nil }
        let result = try await controller.prompt(
            PassphrasePromptRequest(
                title: "Repository Passphrase",
                message: "Enter the repository passphrase to connect.",
                allowsKeychainSave: true,
                suggestedMode: mode))
        return (result.passphrase, result.saveToKeychain ? .keychain : .session)
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
            } catch is CancellationError {
            } catch {
                self.dispatch(.scanFailed(message: error.localizedDescription, ids: ids))
            }
        }
    }

    // MARK: - Upload

    private func startUpload(ids: [String], author: String) {
        uploadOutcome = nil
        beginUploadBackgroundTask()
        let files = state.files.filter { ids.contains($0.id) }
        let prefix = state.configuration.repoPathPrefix
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
        case .failed:
            endUploadBackgroundTask()
        case .enqueued, .running:
            break
        }
    }

    private func beginUploadBackgroundTask() {
        endUploadBackgroundTask()
        uploadBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "ClingSyncUpload") { [weak self] in
            // Grace expired. Cancelling is safe: the bridge resumes from already-transferred blocks next time.
            MainActor.assumeIsolated {
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
        try await runConnect(configuration, promptIfNeeded: true, passphrase: passphrase, s3: s3Controller)
        state.configuration = configuration
        uploadOutcome = nil
        connectSucceeded()
    }
}

// A graceful decline, not a failure: no passphrase available and prompting was disabled.
private struct ConnectDeclined: Error {}

// swiftlint:enable type_body_length

// A file with no scan status yet, or reset to New, still needs checking.
private func isUnscanned(_ status: FileStatus?) -> Bool {
    switch status {
    case .none, .new:
        return true
    default:
        return false
    }
}
