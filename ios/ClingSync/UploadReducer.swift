import Foundation

// Pure transition table for the upload state machine, operating on plain data so
// it is exhaustively unit-testable without the upload mechanism or any IO. Ports
// Android's UploadReducer, including the guards that keep already-finished rows
// from being reverted on abort/failure.
enum UploadReducer {
    static func reduce(_ state: AppState, _ update: WorkUpdate) -> AppState {
        switch update {
        case .enqueued(let id):
            var next = state
            next.currentUploadId = id
            return next
        case .running(let statuses, let uploadedBytes):
            return running(state, statuses: statuses, uploadedBytes: uploadedBytes)
        case .succeeded(let finalStatuses):
            return succeeded(state, finalStatuses: finalStatuses)
        case .failed(let error):
            return failed(state, error: error)
        case .cancelled:
            return cancelled(state)
        }
    }

    private static func running(
        _ state: AppState,
        statuses: [String: FileStatus],
        uploadedBytes: Int64
    ) -> AppState {
        // Ignore a progress signal with nothing to attach it to: a stale "running"
        // after the upload ended (the abort race). A reattached upload after
        // process death has currentUploadId set (idle() nulls it on end), so it is
        // correctly NOT dropped here.
        if !state.isUploading, !state.isUploadInitiated, state.currentUploadId == nil {
            return state
        }

        // A transient unreadable status file yields no statuses; flag uploading but
        // keep the previous uploadInfo rather than resetting it to 0/0.
        if statuses.isEmpty {
            var next = state
            next.isUploading = true
            return next
        }

        let uploadingId = statuses.first { $0.value == .sending }?.key
        let currentFileName = uploadingId.flatMap { id in state.files.first { $0.id == id }?.name }
        let total = statuses.count
        let completed = statuses.values.filter { isCompleted($0) }.count
        let anyCommitting = statuses.values.contains { $0 == .committing }
        let info: UploadInfo
        if anyCommitting {
            info = UploadInfo(currentFile: "Committing changes...", currentIndex: completed, totalFiles: total)
        } else {
            info = UploadInfo(currentFile: currentFileName, currentIndex: completed, totalFiles: total)
        }

        var next = state
        next.isUploading = true
        next.fileStatus.merge(statuses) { _, new in new }
        next.uploadInfo = info
        next.uploadedBytes = uploadedBytes
        return next
    }

    private static func succeeded(_ state: AppState, finalStatuses: [String: FileStatus]) -> AppState {
        var next = idle(state)
        next.fileStatus.merge(finalStatuses) { _, new in new }
        next.selectedIds = []
        return next
    }

    private static func failed(_ state: AppState, error: String) -> AppState {
        var next = idle(state)
        next.fileStatus = markUnfinished(state, status: .failed(message: "Error"))
        if state.overlay == .none {
            next.overlay = .error(title: "Upload Failed", message: error)
        }
        return next
    }

    private static func cancelled(_ state: AppState) -> AppState {
        var next = idle(state)
        next.fileStatus = markUnfinished(state, status: .aborted)
        return next
    }

    private static func isCompleted(_ status: FileStatus) -> Bool {
        switch status {
        case .sentWaitingCommit, .committing:
            return true
        case .exists:
            return true
        default:
            return false
        }
    }

    // A file whose terminal status must survive an abort/failure: already uploaded
    // (and committed elsewhere in the batch) or already present in the repo.
    private static func keepsTerminalStatus(_ status: FileStatus?) -> Bool {
        switch status {
        case .done, .exists:
            return true
        default:
            return false
        }
    }

    // Mark every in-flight file (not already Done/Exists) with the given status.
    private static func markUnfinished(_ state: AppState, status: FileStatus) -> [String: FileStatus] {
        var result = state.fileStatus
        for id in state.currentUploadIds where !keepsTerminalStatus(state.fileStatus[id]) {
            result[id] = status
        }
        return result
    }

    // Reset every per-upload field back to the not-uploading baseline.
    private static func idle(_ state: AppState) -> AppState {
        var next = state
        next.isUploading = false
        next.isUploadInitiated = false
        next.currentUploadId = nil
        next.currentUploadIds = []
        next.uploadInfo = nil
        next.uploadedBytes = 0
        return next
    }
}
