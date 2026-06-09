import Foundation
import Testing

@testable import ClingSync

// The share flow reuses MainStore over a shared-files source: it scans the shared
// files, uploads the new ones to the chosen target, and recognizes already-present
// content as Exists so re-sharing the same file does not create a new commit.
extension BridgeSuite {
    @MainActor
    @Test(.enabled(if: TestRepo.isAvailable))
    func shareUploadsNewFilesThenDedupsAReshare() async throws {
        let repo = try await TestRepo.fresh()
        let defaults = UserDefaults(suiteName: "share-flow-test")!
        defaults.removePersistentDomain(forName: "share-flow-test")
        let settings = UserDefaultsSettingsGateway(defaults: defaults)
        settings.save(RepositoryConfiguration(hostURL: repo.url, repoPathPrefix: "preset", author: "Sharer"))

        let original = try writeTempFile("shared payload\n", ext: "txt")
        let staged = try #require(ShareImport.stage(original))
        let store = MainStore(settings: settings, source: SharedFilesSource(staged: [staged]))
        store.shareTarget = "shared/inbox"
        store.onStartShare()

        try await waitUntil { store.passphraseController.request != nil }
        store.passphraseController.submit(passphrase: repo.passphrase, saveToKeychain: false)
        try await waitUntil { store.s3Controller.request != nil }
        store.s3Controller.submit(accessKeyId: repo.s3KeyId, accessKey: repo.s3Key)

        // The shared file is scanned and, being new, offered for upload.
        let file = staged.file
        try await waitUntil {
            store.state.isConnected && store.state.fileStatus[file.id] == .new
        }

        store.dispatch(.fileSelectionChanged(id: file.id, selected: true))
        store.dispatch(.uploadClicked)
        try await waitUntil(timeout: 40) { store.uploadOutcome != nil }
        #expect(store.uploadOutcome == .succeeded(fileCount: 1, bytes: file.size))
        #expect(try Bridge.checkFiles(sha256s: [sha256Hex(of: original)]) == [true])

        // Re-sharing the same content is recognized as already present, so it is
        // marked Exists and is not selectable (no new commit).
        let restaged = try #require(ShareImport.stage(original))
        let reshare = MainStore(settings: settings, source: SharedFilesSource(staged: [restaged]))
        reshare.shareTarget = "shared/inbox"
        reshare.onStartShare()
        try await waitUntil(timeout: 20) {
            reshare.state.isConnected && reshare.state.fileStatus[restaged.file.id] == .exists(repoPath: "")
        }
        #expect(!isSelectable(reshare.state.fileStatus[restaged.file.id]))
    }
}
