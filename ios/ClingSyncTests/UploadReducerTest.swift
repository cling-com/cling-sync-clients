import Foundation
import Testing

@testable import ClingSync

struct UploadReducerTest {
    private let config = RepositoryConfiguration(hostURL: "s3+http://h", repoPathPrefix: "", author: "Tester")

    private func file(_ id: String) -> SourceFile {
        SourceFile(id: id, name: "\(id).jpg", size: 10, modificationDate: .distantPast)
    }

    private func uploading(_ ids: [String], status: FileStatus = .waiting) -> AppState {
        var state = AppState(configuration: config)
        state.isUploading = true
        state.isUploadInitiated = true
        state.currentUploadId = UUID(uuidString: "00000000-0000-0000-0000-000000000001")
        state.currentUploadIds = Set(ids)
        state.files = ids.map { file($0) }
        state.fileStatus = Dictionary(uniqueKeysWithValues: ids.map { ($0, status) })
        return state
    }

    @Test func enqueuedRecordsTheWorkId() {
        let id = UUID(uuidString: "00000000-0000-0000-0000-0000000000aa")!
        let next = UploadReducer.reduce(AppState(configuration: config), .enqueued(id: id))
        #expect(next.currentUploadId == id)
    }

    @Test func runningMergesStatusesAndSetsUploading() {
        let state = uploading(["a", "b"])
        let next = UploadReducer.reduce(
            state, .running(statuses: ["a": .sending, "b": .waiting], uploadedBytes: 1234))

        #expect(next.isUploading)
        #expect(next.fileStatus["a"] == .sending)
        #expect(next.uploadedBytes == 1234)
        #expect(next.uploadInfo?.currentFile == "a.jpg")
        #expect(next.uploadInfo?.totalFiles == 2)
    }

    @Test func runningShowsCommittingWhenAnyFileIsCommitting() {
        let state = uploading(["a", "b"])
        let next = UploadReducer.reduce(
            state, .running(statuses: ["a": .committing, "b": .committing], uploadedBytes: 0))

        #expect(next.uploadInfo?.currentFile == "Committing changes...")
        #expect(next.uploadInfo?.currentIndex == 2)
    }

    @Test func reattachAfterProcessDeathThenRunningShowsProgress() {
        // Fresh process: no busy flags, no id. Reattach assigns the id, then a
        // Running must NOT be dropped (it has an id to attach to).
        let id = UUID(uuidString: "00000000-0000-0000-0000-0000000000bb")!
        var fresh = AppState(configuration: config)
        fresh.files = [file("a")]
        let reattached = UploadReducer.reduce(fresh, .enqueued(id: id))
        let running = UploadReducer.reduce(reattached, .running(statuses: ["a": .sending], uploadedBytes: 7))

        #expect(running.isUploading)
        #expect(running.fileStatus["a"] == .sending)
        #expect(running.uploadInfo?.currentFile == "a.jpg")
    }

    @Test func runningWithNoStatusesKeepsPreviousUploadInfo() {
        var previous = uploading(["a"])
        previous.uploadInfo = UploadInfo(currentFile: "a.jpg", currentIndex: 1, totalFiles: 3)
        let next = UploadReducer.reduce(previous, .running(statuses: [:], uploadedBytes: 0))
        #expect(next.isUploading)
        #expect(next.uploadInfo?.currentFile == "a.jpg")
    }

    @Test func staleRunningAfterUploadEndedIsIgnored() {
        // The abort race: a late progress signal must not revive a finished upload.
        var ended = AppState(configuration: config)
        ended.isUploading = false
        ended.isUploadInitiated = false
        ended.fileStatus = ["a": .aborted]

        let next = UploadReducer.reduce(ended, .running(statuses: ["a": .sending], uploadedBytes: 5))

        #expect(next == ended)
        #expect(next.fileStatus["a"] == .aborted)
    }

    @Test func succeededMarksFinalStatusesClearsSelectionAndResets() {
        var state = uploading(["a", "b"], status: .committing)
        state.selectedIds = ["x"]
        let next = UploadReducer.reduce(
            state, .succeeded(finalStatuses: ["a": .done, "b": .exists(repoPath: "")]))

        #expect(next.fileStatus["a"] == .done)
        #expect(next.fileStatus["b"] == .exists(repoPath: ""))
        #expect(!next.isUploading)
        #expect(!next.isUploadInitiated)
        #expect(next.currentUploadId == nil)
        #expect(next.currentUploadIds.isEmpty)
        #expect(next.uploadInfo == nil)
        #expect(next.selectedIds.isEmpty)
    }

    @Test func failedMarksInflightFailedAndShowsDialog() {
        let state = uploading(["a", "b"], status: .sending)
        let next = UploadReducer.reduce(state, .failed(error: "boom"))

        #expect(next.fileStatus["a"] == .failed(message: "Error"))
        #expect(next.fileStatus["b"] == .failed(message: "Error"))
        #expect(!next.isUploading)
        #expect(next.overlay == .error(title: "Upload Failed", message: "boom"))
    }

    @Test func cancelledMarksInflightAbortedButKeepsCompletedFiles() {
        var state = uploading(["a", "b", "c"], status: .sending)
        state.fileStatus = ["a": .sending, "b": .done, "c": .exists(repoPath: "")]

        let next = UploadReducer.reduce(state, .cancelled)

        #expect(next.fileStatus["a"] == .aborted)
        // Already-finished files (uploaded or already present) are preserved.
        #expect(next.fileStatus["b"] == .done)
        #expect(next.fileStatus["c"] == .exists(repoPath: ""))
        #expect(!next.isUploading)
        #expect(next.currentUploadIds.isEmpty)
    }

    @Test func failedDoesNotReplaceAnExistingOverlayButStillMarksTheFile() {
        var state = uploading(["a"], status: .sending)
        state.overlay = .error(title: "Connection Error", message: "earlier")
        let next = UploadReducer.reduce(state, .failed(error: "boom"))
        #expect(next.overlay == .error(title: "Connection Error", message: "earlier"))
        #expect(next.fileStatus["a"] == .failed(message: "Error"))
    }

    @Test func runningWithUploadingFileNotInListYieldsNilCurrentFile() {
        var state = uploading(["a"])
        state.files = []
        let next = UploadReducer.reduce(state, .running(statuses: ["a": .sending], uploadedBytes: 0))
        #expect(next.uploadInfo?.currentFile == nil)
        #expect(next.fileStatus["a"] == .sending)
    }
}
