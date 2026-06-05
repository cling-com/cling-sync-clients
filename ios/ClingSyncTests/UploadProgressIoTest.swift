import Foundation
import Testing

@testable import ClingSync

struct UploadProgressIoTest {
    private func tempFile() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("progress-\(UUID().uuidString).json")
    }

    @Test func progressMapsEveryStatus() throws {
        let file = tempFile()
        try UploadProgressIo.write(
            [
                "a": .waiting,
                "b": .uploading,
                "c": .uploaded,
                "d": .skipped,
                "e": .committing,
            ], to: file)

        let progress = try UploadProgressIo.readProgress(from: file)

        #expect(progress["a"] == .waiting)
        #expect(progress["b"] == .sending)
        #expect(progress["c"] == .sentWaitingCommit)
        #expect(progress["d"] == .exists(repoPath: ""))
        #expect(progress["e"] == .committing)
    }

    @Test func resultKeepsTerminalStatusesAndDropsInProgressOnes() throws {
        let file = tempFile()
        try UploadProgressIo.write(
            [
                "committed": .committing,
                "uploaded": .uploaded,
                "skipped": .skipped,
                "waiting": .waiting,
                "uploading": .uploading,
            ], to: file)

        let result = try UploadProgressIo.readResult(from: file)

        #expect(result["committed"] == .done)
        #expect(result["uploaded"] == .done)
        #expect(result["skipped"] == .exists(repoPath: ""))
        // Non-terminal states must not overwrite existing UI state on completion.
        #expect(result["waiting"] == nil)
        #expect(result["uploading"] == nil)
        #expect(result.count == 3)
    }

    @Test func unknownWireStringIsTreatedAsNewAndNonTerminal() throws {
        let file = tempFile()
        try Data(#"{"x":"some-future-status"}"#.utf8).write(to: file)

        #expect(try UploadProgressIo.readProgress(from: file)["x"] == .new)
        #expect(try UploadProgressIo.readResult(from: file)["x"] == nil)
    }
}
