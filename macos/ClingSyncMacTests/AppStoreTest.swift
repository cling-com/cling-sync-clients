import Foundation
import Testing

@testable import ClingSyncMac

// A scriptable WorkspaceGateway that records calls in order and throws queued
// errors, so store-orchestration logic (passphrase retry, Bug A ordering, the
// test flow) is testable without the real bridge.
final class FakeWorkspaceGateway: WorkspaceGateway {
    enum Call: Equatable {
        case inspect
        case checkExists
        case initRepo
        case configure
        case encode
        case testAccess
        case storePassphrase(password: String)
        case clearPassphrase
        case start(OperationKind, password: String?)
        case poll(OperationKind)
        case cancel(OperationKind)
        case listTargets
        case addTarget(password: String?)
        case deleteTarget
    }

    private(set) var calls: [Call] = []

    var startErrors: [Error] = []
    var testAccessErrors: [Error] = []
    var addTargetErrors: [Error] = []
    var pollQueue: [OperationProgress] = []
    var existsResult = true
    var lastMergeDateResult: Date?
    var inspectionResult = WorkspaceInspection(exists: false, hostURL: "", repoPathPrefix: "", hasStoredAccess: false)
    var encodeResult = "s3+https://creds@host"
    var syncTargets: [SyncTargetInfo] = []

    static let idleProgress = OperationProgress(
        running: false, canCancel: false, completed: false, cancelled: false, upToDate: false,
        statusMessage: "", detailedOutput: "", revisionId: "", errorMessage: "", errorIsNetwork: false)

    func storedPasswords() -> [String] {
        calls.compactMap {
            if case .storePassphrase(let password) = $0 { return password }
            return nil
        }
    }

    func inspect(localPath: String) async throws -> WorkspaceInspection {
        calls.append(.inspect)
        return inspectionResult
    }
    func lastMergeDate(localPath: String) async -> Date? { lastMergeDateResult }
    func checkFileRepositoryExists(localPath: String) async throws -> Bool {
        calls.append(.checkExists)
        return existsResult
    }
    func initNewFileRepository(localPath: String, password: String) async throws { calls.append(.initRepo) }
    func configureWorkspace(uri: String, localPath: String, repoPathPrefix: String) async throws {
        calls.append(.configure)
    }

    func encodeS3URI(hostURL: String, passphrase: String, accessKeyId: String, accessKey: String) async throws -> String
    {
        calls.append(.encode)
        return encodeResult
    }

    func testWorkspaceAccess(localPath: String, password: String?) async throws {
        calls.append(.testAccess)
        try throwNext(&testAccessErrors)
    }

    func storeWorkspacePassphrase(localPath: String, password: String) async throws {
        calls.append(.storePassphrase(password: password))
    }

    func clearWorkspacePassphrase(uri: String) async throws { calls.append(.clearPassphrase) }

    func startMerge(localPath: String, password: String?, author: String) async throws {
        calls.append(.start(.merge, password: password))
        try throwNext(&startErrors)
    }

    func startStatus(localPath: String, password: String?) async throws {
        calls.append(.start(.status, password: password))
        try throwNext(&startErrors)
    }

    func startSync(localPath: String, password: String?, workers: Int) async throws {
        calls.append(.start(.sync, password: password))
        try throwNext(&startErrors)
    }

    func poll(kind: OperationKind, localPath: String) async throws -> OperationProgress {
        calls.append(.poll(kind))
        return pollQueue.isEmpty ? Self.idleProgress : pollQueue.removeFirst()
    }

    func cancel(kind: OperationKind, localPath: String) async throws { calls.append(.cancel(kind)) }
    func listSyncTargets(localPath: String) async throws -> [SyncTargetInfo] {
        calls.append(.listTargets)
        return syncTargets
    }

    func addSyncTarget(localPath: String, name: String, uri: String, password: String?) async throws {
        calls.append(.addTarget(password: password))
        try throwNext(&addTargetErrors)
    }

    func deleteSyncTarget(localPath: String, name: String) async throws { calls.append(.deleteTarget) }

    private func throwNext(_ queue: inout [Error]) throws {
        if !queue.isEmpty { throw queue.removeFirst() }
    }
}

@MainActor
struct AppStoreTests {
    private static let now = Date(timeIntervalSince1970: 10_000_000)

    private func makeStore(gateway: FakeWorkspaceGateway, prompter: ScriptedPrompter) -> AppStore {
        let settings = UserDefaultsSettingsGateway(
            defaults: UserDefaults(suiteName: "test.store.\(UUID().uuidString)")!)
        return AppStore(
            gateway: gateway, settings: settings, prompter: prompter, notifier: SilentNotifier(),
            clock: { Self.now }, isTestMode: true)
    }

    private func load(_ store: AppStore, _ config: WorkspaceConfig) {
        store.dispatch(
            .stateLoaded(workspaces: [config], tracking: MergeTracking(), settings: AppSettings(), now: Self.now))
    }

    private func waitUntil(timeout: TimeInterval = 2, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    private func passphraseRequired() -> BridgeError {
        BridgeError(message: "passphrase needed", code: "passphrase_required")
    }

    @Test func passphraseStoredOnlyAfterSuccessfulRetry() async {
        let fake = FakeWorkspaceGateway()
        fake.startErrors = [passphraseRequired()]  // first start throws; second (queue empty) succeeds
        let prompter = ScriptedPrompter()
        prompter.passphraseResults = [PassphrasePromptResult(passphrase: "secret", rememberInKeychain: true)]
        let store = makeStore(gateway: fake, prompter: prompter)
        let config = WorkspaceConfig(hostURL: "s3+https://h", localDirectory: "/p", author: "me")
        load(store, config)

        store.dispatch(.operationClicked(id: config.id, kind: .merge))
        await waitUntil { fake.storedPasswords() == ["secret"] }

        let startIndex = fake.calls.firstIndex(of: .start(.merge, password: "secret"))
        let storeIndex = fake.calls.firstIndex(of: .storePassphrase(password: "secret"))
        #expect(startIndex != nil)
        #expect(storeIndex != nil)
        #expect((startIndex ?? 0) < (storeIndex ?? 0))  // Bug A: stored only AFTER the successful start
        #expect(prompter.passphraseRequestCount == 1)
    }

    @Test func passphraseNotStoredWhenRetryFails() async {
        let fake = FakeWorkspaceGateway()
        fake.startErrors = [passphraseRequired(), BridgeError(message: "wrong passphrase", code: nil)]
        let prompter = ScriptedPrompter()
        prompter.passphraseResults = [PassphrasePromptResult(passphrase: "wrong", rememberInKeychain: true)]
        let store = makeStore(gateway: fake, prompter: prompter)
        let config = WorkspaceConfig(hostURL: "s3+https://h", localDirectory: "/p", author: "me")
        load(store, config)

        store.dispatch(.operationClicked(id: config.id, kind: .merge))
        await waitUntil { store.state.workspace(config.id)?.merge.isTerminalFailure == true }
        #expect(store.state.workspace(config.id)?.merge.errorMessage == "wrong passphrase")
        #expect(fake.storedPasswords().isEmpty)
    }

    @Test func cancellingPassphrasePromptReturnsToIdle() async {
        let fake = FakeWorkspaceGateway()
        fake.startErrors = [passphraseRequired()]
        let prompter = ScriptedPrompter()  // no canned passphrase -> prompt returns nil (cancelled)
        let store = makeStore(gateway: fake, prompter: prompter)
        let config = WorkspaceConfig(hostURL: "s3+https://h", localDirectory: "/p", author: "me")
        load(store, config)

        store.dispatch(.operationClicked(id: config.id, kind: .merge))
        await waitUntil { store.state.workspace(config.id)?.merge == .idle }
        #expect(store.state.workspace(config.id)?.merge == .idle)
        #expect(fake.storedPasswords().isEmpty)
    }

    @Test func startSuccessPollsThroughToCompletion() async {
        let fake = FakeWorkspaceGateway()
        fake.pollQueue = [
            OperationProgress(
                running: true, canCancel: true, completed: false, cancelled: false, upToDate: false,
                statusMessage: "Merging...", detailedOutput: "", revisionId: "", errorMessage: "", errorIsNetwork: false
            ),
            OperationProgress(
                running: false, canCancel: false, completed: true, cancelled: false, upToDate: false,
                statusMessage: "merged", detailedOutput: "", revisionId: "r1", errorMessage: "", errorIsNetwork: false),
        ]
        let store = makeStore(gateway: fake, prompter: ScriptedPrompter())
        let config = WorkspaceConfig(hostURL: "s3+https://h", localDirectory: "/p", author: "me")
        load(store, config)

        store.dispatch(.operationClicked(id: config.id, kind: .merge))
        await waitUntil { store.state.workspace(config.id)?.merge.ranSuccessfully == true }
        #expect(store.state.workspace(config.id)?.lastSuccessfulMerge == Self.now)
    }

    @Test func testDraftVerifiesExistingFileRepositoryWithoutPrompt() async {
        let fake = FakeWorkspaceGateway()
        fake.existsResult = true  // file repo exists; testWorkspaceAccess succeeds (no error queued)
        let store = makeStore(gateway: fake, prompter: ScriptedPrompter())
        let config = WorkspaceConfig(hostURL: "/local/repo", localDirectory: "/p", author: "me")
        load(store, config)

        store.dispatch(.testDraftClicked)
        await waitUntil { store.state.draftConfig.isAccessVerified }
        #expect(store.state.draftConfig.isAccessVerified)
        #expect(store.state.lastResultMessage.hasPrefix("Tested"))
    }
}
