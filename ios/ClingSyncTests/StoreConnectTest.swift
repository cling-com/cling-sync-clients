import Foundation
import Testing

@testable import ClingSync

// Polls a main-actor condition until it holds or the timeout elapses.
@MainActor
func waitUntil(timeout: TimeInterval = 15, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > deadline { throw BridgeTestError("timed out waiting for condition") }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
}

// Drives the whole MainStore connect pipeline against a fresh repository: stored
// passphrase prompt, cleartext-S3 credential prompt, connection, then the load +
// scan that follows a successful connect.
extension BridgeSuite {
    @MainActor
    @Test(.enabled(if: TestRepo.isAvailable))
    func storeConnectsThenLoadsAndScans() async throws {
        let repo = try await TestRepo.fresh()
        let defaults = UserDefaults(suiteName: "store-connect-test")!
        defaults.removePersistentDomain(forName: "store-connect-test")
        let settings = UserDefaultsSettingsGateway(defaults: defaults)
        settings.save(RepositoryConfiguration(hostURL: repo.url, repoPathPrefix: "phone", author: "Tester"))
        let store = MainStore(
            settings: settings, source: PhotoLibrarySource(isUITestMode: true), isUITestMode: true)

        store.dispatch(.connectClicked)

        try await waitUntil { store.passphraseController.request != nil }
        store.passphraseController.submit(passphrase: repo.passphrase, saveToKeychain: false)

        try await waitUntil { store.s3Controller.request != nil }
        store.s3Controller.submit(accessKeyId: repo.s3KeyId, accessKey: repo.s3Key)

        try await waitUntil { store.state.isConnected }
        #expect(store.state.phase == .ready)

        try await waitUntil {
            store.state.files.count == 2 && !store.state.isScanning
                && store.state.fileStatus.count == store.state.files.count
        }
        #expect(store.state.fileStatus.values.allSatisfy { $0 == .new })
    }
}
