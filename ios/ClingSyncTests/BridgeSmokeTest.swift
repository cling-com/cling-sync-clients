import Foundation
import Testing

@testable import ClingSync

// Exercises the full real-bridge loop in-process: open, check, upload, commit,
// re-check, and dedup.
extension BridgeSuite {
    @Test(.enabled(if: TestRepo.isAvailable))
    func openUploadCommitAndRescan() async throws {
        let repo = try await TestRepo.fresh()
        let encoded = try Bridge.encodeS3URI(
            hostUrl: repo.url,
            passphrase: repo.passphrase,
            accessKeyId: repo.s3KeyId,
            accessKey: repo.s3Key)

        _ = try Bridge.openRepository(url: encoded, password: repo.passphrase)
        #expect(try Bridge.checkRepositoryOpen(url: encoded).open)

        let file = try writeTempFile("hello smoke")
        let sha = sha256Hex(of: file)
        let repoPath = "smoke/\(file.lastPathComponent)"

        // Before upload: the file is new (empty repo path).
        #expect(try Bridge.checkFiles(sha256s: [sha]) == [""])

        let entry = try Bridge.uploadFile(localFilePath: file.path, repoFilePath: repoPath)
        let revisionEntry = try #require(entry, "a new file must produce a revision entry")
        let revision = try Bridge.commit(revisionEntries: [revisionEntry], author: "Tester", message: "smoke commit")
        #expect(!revision.isEmpty)

        // After commit: the same content is found at its repo path.
        #expect(try Bridge.checkFiles(sha256s: [sha]) == [repoPath])

        // Re-uploading the identical file is skipped by the real bridge.
        #expect(try Bridge.uploadFile(localFilePath: file.path, repoFilePath: repoPath) == nil)
    }
}
