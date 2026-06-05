import Foundation
import Testing

@testable import ClingSync

// Real-bridge coverage of the new scan + upload collaborators end to end against a
// fresh repository, using the photo-library source's fixture path.
extension BridgeSuite {
    private func openFreshRepo() async throws -> (source: PhotoLibrarySource, files: [SourceFile]) {
        let repo = try await TestRepo.fresh()
        let encoded = try Bridge.encodeS3URI(
            hostUrl: repo.url, passphrase: repo.passphrase, accessKeyId: repo.s3KeyId, accessKey: repo.s3Key)
        _ = try Bridge.openRepository(url: encoded, password: repo.passphrase)
        let source = PhotoLibrarySource(isUITestMode: true)
        return (source, await source.loadFiles())
    }

    @Test(.enabled(if: TestRepo.isAvailable))
    func scanReportsNewBeforeUploadAndExistsAfter() async throws {
        let (source, files) = try await openFreshRepo()
        let scan = ScanService(source: source)

        var statuses: [String: FileStatus] = [:]
        try await scan.scan(files) { _, batch in statuses.merge(batch) { _, new in new } }
        #expect(files.allSatisfy { statuses[$0.id] == .new })

        let target = try #require(files.first)
        let entry = try await source.withLocalCopy(of: target) { url in
            try Bridge.uploadFile(localFilePath: url.path, repoFilePath: "phone/\(target.name)")
        }
        _ = try Bridge.commit(revisionEntries: [try #require(entry)], author: "Tester", message: "one")

        statuses = [:]
        try await scan.scan(files) { _, batch in statuses.merge(batch) { _, new in new } }
        #expect(statuses[target.id] == .exists(repoPath: ""))
        let other = try #require(files.first { $0.id != target.id })
        #expect(statuses[other.id] == .new)
    }

    @Test(.enabled(if: TestRepo.isAvailable))
    func uploadCommitsEveryFileThenDedupsOnReupload() async throws {
        let (source, files) = try await openFreshRepo()
        let coordinator = UploadCoordinator(source: source)

        let first = await collectUpdates(coordinator, files, source)
        let firstFinal = try #require(terminalStatuses(first))
        #expect(files.allSatisfy { firstFinal[$0.id] == .done })
        #expect(first.first.map(isEnqueued) == true)

        var shas: [String] = []
        for file in files { shas.append(try await source.sha256(for: file)) }
        #expect(try Bridge.checkFiles(sha256s: shas) == files.map { _ in true })

        // Re-uploading identical content is deduplicated: every file reports Exists.
        let second = await collectUpdates(coordinator, files, source)
        let secondFinal = try #require(terminalStatuses(second))
        #expect(files.allSatisfy { secondFinal[$0.id] == .exists(repoPath: "") })
    }

    private func collectUpdates(
        _ coordinator: UploadCoordinator,
        _ files: [SourceFile],
        _ source: PhotoLibrarySource
    ) async -> [WorkUpdate] {
        var updates: [WorkUpdate] = []
        await coordinator.upload(
            files, repoPathPrefix: "phone", author: "Tester", deviceName: "TestDevice"
        ) { update in updates.append(update) }
        return updates
    }

    private func terminalStatuses(_ updates: [WorkUpdate]) -> [String: FileStatus]? {
        guard case .succeeded(let finalStatuses) = updates.last else { return nil }
        return finalStatuses
    }

    private func isEnqueued(_ update: WorkUpdate) -> Bool {
        if case .enqueued = update { return true }
        return false
    }
}
