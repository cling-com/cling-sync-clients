import Foundation
import Testing

@testable import ClingSync

// Drives MergeReminderScan against the REAL bridge: "backed up" means the file's
// content hash is in a freshly provisioned repository (seeded by uploading +
// committing), as answered by the bridge's checkFiles. Mirrors Android's
// MergeReminderScanTest.
extension BridgeSuite {
    @Test(.enabled(if: TestRepo.isAvailable))
    func reminderDailyCountsHashedFilesNotInRepo() async throws {
        let env = try await ReminderEnv.fresh()
        env.write("backed.jpg", "alpha")
        env.write("pending.jpg", "beta")
        let files = await env.source.loadFiles()
        for file in files { _ = try await env.source.sha256(for: file) }
        try env.backUp("backed.jpg")

        #expect(try env.scan.countUnsynced(files) == 1)
    }

    @Test(.enabled(if: TestRepo.isAvailable))
    func reminderDailyCountsUnhashedFilesAsNew() async throws {
        let env = try await ReminderEnv.fresh()
        env.write("a.jpg", "a")
        env.write("b.jpg", "b")
        let files = await env.source.loadFiles()

        // Never hashed -> no cached hash -> treated as new without a repo lookup.
        #expect(try env.scan.countUnsynced(files) == 2)
    }

    @Test(.enabled(if: TestRepo.isAvailable))
    func reminderDailyIsZeroWhenEverythingBackedUp() async throws {
        let env = try await ReminderEnv.fresh()
        env.write("a.jpg", "alpha")
        let files = await env.source.loadFiles()
        _ = try await env.source.sha256(for: files[0])
        try env.backUp("a.jpg")

        #expect(try env.scan.countUnsynced(files) == 0)
    }

    @Test(.enabled(if: TestRepo.isAvailable))
    func reminderWeeklyDetectsNewAndChanged() async throws {
        let env = try await ReminderEnv.fresh()
        env.write("unchanged.jpg", "keep-me")
        env.write("changed.jpg", "before")
        env.write("fresh.jpg", "brand-new")
        let initial = await env.source.loadFiles()
        for file in initial where file.name != "fresh.jpg" {
            _ = try await env.source.sha256(for: file)
        }
        try env.backUp("unchanged.jpg")
        try env.backUp("changed.jpg")
        // Edit `changed` so its current content is no longer the committed one.
        env.write("changed.jpg", "after-the-edit-with-different-bytes")

        let files = await env.source.loadFiles()
        #expect(try await env.scan.countUnsyncedOrChanged(files) == 2)
    }

    @Test(.enabled(if: TestRepo.isAvailable))
    func reminderWeeklyIgnoresTouchThatPreservesContent() async throws {
        let env = try await ReminderEnv.fresh()
        env.write("a.jpg", "stable")
        let initial = await env.source.loadFiles()
        _ = try await env.source.sha256(for: initial[0])
        try env.backUp("a.jpg")
        env.touch("a.jpg")

        let files = await env.source.loadFiles()
        #expect(try await env.scan.countUnsyncedOrChanged(files) == 0)
    }

    // MergeReminderService.evaluate is the notify-or-not decision the background task
    // and the test buttons run: source -> scan -> daily/weekly -> due/skip + count.

    @Test(.enabled(if: TestRepo.isAvailable))
    func reminderEvaluateIsDueForPendingFiles() async throws {
        let env = try await ReminderEnv.fresh()
        env.write("backed.jpg", "alpha")
        env.write("pending.jpg", "beta")
        let files = await env.source.loadFiles()
        for file in files { _ = try await env.source.sha256(for: file) }
        try env.backUp("backed.jpg")

        #expect(await MergeReminderService.evaluate(mode: .daily, source: env.source) == .due(count: 1, weekly: false))
    }

    @Test(.enabled(if: TestRepo.isAvailable))
    func reminderEvaluateIsSkippedWhenAllBackedUp() async throws {
        let env = try await ReminderEnv.fresh()
        env.write("a.jpg", "alpha")
        let files = await env.source.loadFiles()
        _ = try await env.source.sha256(for: files[0])
        try env.backUp("a.jpg")

        #expect(await MergeReminderService.evaluate(mode: .daily, source: env.source) == .skipped)
    }

    @Test(.enabled(if: TestRepo.isAvailable))
    func reminderEvaluateWeeklyFlagsChangedFiles() async throws {
        let env = try await ReminderEnv.fresh()
        env.write("changed.jpg", "before")
        let files = await env.source.loadFiles()
        _ = try await env.source.sha256(for: files[0])
        try env.backUp("changed.jpg")
        env.write("changed.jpg", "after-the-edit-with-different-bytes")

        #expect(await MergeReminderService.evaluate(mode: .weekly, source: env.source) == .due(count: 1, weekly: true))
    }

    @Test(.enabled(if: TestRepo.isAvailable))
    func reminderEvaluateIsSkippedForEmptySource() async throws {
        let env = try await ReminderEnv.fresh()
        #expect(await MergeReminderService.evaluate(mode: .daily, source: env.source) == .skipped)
    }
}

// Provisions a fresh repo and a folder source over a temp directory for the
// reminder scan tests, mirroring Android's MergeReminderScanTest harness.
private struct ReminderEnv {
    let dir: URL
    let source: FolderSource

    var scan: MergeReminderScan { MergeReminderScan(source: source) }

    static func fresh() async throws -> ReminderEnv {
        let repo = try await TestRepo.fresh()
        let encoded = try Bridge.encodeS3URI(
            hostUrl: repo.url, passphrase: repo.passphrase, accessKeyId: repo.s3KeyId, accessKey: repo.s3Key)
        _ = try Bridge.openRepository(url: encoded, password: repo.passphrase)
        SHA256Cache.shared.resetForTesting()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reminder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return ReminderEnv(dir: dir, source: FolderSource(bookmark: try dir.bookmarkData()))
    }

    func write(_ name: String, _ contents: String) {
        try? Data(contents.utf8).write(to: dir.appendingPathComponent(name))
    }

    func touch(_ name: String) {
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: dir.appendingPathComponent(name).path)
    }

    // Uploads + commits a file so its content is genuinely in the repository.
    func backUp(_ name: String) throws {
        let url = dir.appendingPathComponent(name)
        guard let entry = try Bridge.uploadFile(localFilePath: url.path, repoFilePath: name) else {
            throw BridgeTestError("upload produced no revision entry for \(name)")
        }
        _ = try Bridge.commit(revisionEntries: [entry], author: "Tester", message: "seed")
    }
}
