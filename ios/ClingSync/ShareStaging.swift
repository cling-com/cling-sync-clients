import Foundation

// A share staged and waiting to be presented as the share screen.
struct PendingShare: Identifiable {
    let id = UUID()
    let staged: [(file: SourceFile, url: URL)]
}

// The app-wide single active upload, consulted by the share screen so a share
// upload never runs alongside the main screen's background upload.
@MainActor
protocol ActiveUploadGuard: AnyObject {
    var hasActiveUpload: Bool { get }
    func abortActiveUpload() async
}

// The share-staging lifecycle, kept out of MainStore to stay under the file-length
// limit: stage incoming files, coalesce a multi-file share into one screen, and
// clean up a dismissed share's staged copies.
extension MainStore {
    // Stages files handed to the app through the share/open flow off the main actor,
    // then presents the share screen.
    func receiveSharedURLs(_ urls: [URL]) {
        Task { [weak self] in
            let staged = await Task.detached { urls.compactMap { ShareImport.stage($0) } }.value
            guard let self, !staged.isEmpty else { return }
            self.stagedShareFiles.append(contentsOf: staged)
            self.scheduleSharePresentation()
        }
    }

    // The OS delivers a multi-file share one URL at a time, so a brief quiet period
    // coalesces the arrivals. A new share never replaces one already on screen; its
    // files wait in the buffer and are presented when the current share is dismissed.
    private func scheduleSharePresentation() {
        guard pendingShare == nil else { return }
        shareCoalesceTask?.cancel()
        shareCoalesceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard let self, !Task.isCancelled, self.pendingShare == nil, !self.stagedShareFiles.isEmpty else { return }
            self.pendingShare = PendingShare(staged: self.stagedShareFiles)
            self.stagedShareFiles = []
        }
    }

    func dismissShare() {
        if let staged = pendingShare?.staged {
            ShareImport.remove(staged)
        }
        pendingShare = nil
        shareCoalesceTask?.cancel()
        if !stagedShareFiles.isEmpty {
            scheduleSharePresentation()
        }
    }
}
