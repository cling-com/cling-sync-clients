import Foundation

// Uploads source files to the repository and commits them, emitting normalized
// WorkUpdates the store folds into the upload reducer. Replaces the old Uploader.
// The bridge calls are synchronous, so the store runs this on a detached task and
// hops each emitted update back to the main actor; `emit` is awaited so updates
// arrive in order.
struct UploadCoordinator {
    let source: SourceGateway

    func upload(
        _ files: [SourceFile],
        repoPathPrefix: String,
        author: String,
        deviceName: String,
        emit: (WorkUpdate) async -> Void
    ) async {
        await emit(.enqueued(id: UUID()))
        var statuses = Dictionary(uniqueKeysWithValues: files.map { ($0.id, FileStatus.waiting) })
        var uploadedBytes: Int64 = 0
        var revisionEntries: [String] = []
        await emit(.running(statuses: statuses, uploadedBytes: uploadedBytes))

        do {
            for file in files {
                try Task.checkCancellation()
                statuses[file.id] = .sending
                await emit(.running(statuses: statuses, uploadedBytes: uploadedBytes))

                let repoPath = Self.repoPath(prefix: repoPathPrefix, name: file.name)
                let entry = try await source.withLocalCopy(of: file) { url in
                    try Bridge.uploadFile(localFilePath: url.path, repoFilePath: repoPath)
                }
                uploadedBytes += file.size
                if let entry {
                    revisionEntries.append(entry)
                    statuses[file.id] = .sentWaitingCommit
                } else {
                    statuses[file.id] = .exists(repoPath: "")
                }
                await emit(.running(statuses: statuses, uploadedBytes: uploadedBytes))
            }

            if !revisionEntries.isEmpty {
                for (id, status) in statuses where status == .sentWaitingCommit {
                    statuses[id] = .committing
                }
                await emit(.running(statuses: statuses, uploadedBytes: uploadedBytes))
                let message = "Backup \(files.count) file\(files.count == 1 ? "" : "s") from \(deviceName)"
                _ = try Bridge.commit(
                    revisionEntries: revisionEntries,
                    author: author.isEmpty ? deviceName : author,
                    message: message)
            }
            await emit(.succeeded(finalStatuses: Self.finalStatuses(statuses)))
        } catch is CancellationError {
            await emit(.cancelled)
        } catch let error as BridgeError {
            await emit(.failed(error: error.message))
        } catch {
            await emit(.failed(error: error.localizedDescription))
        }
    }

    // Uploaded (and committed) files are Done; deduplicated ones stay Exists.
    private static func finalStatuses(_ statuses: [String: FileStatus]) -> [String: FileStatus] {
        statuses.mapValues { status in
            if case .exists = status { return status }
            return .done
        }
    }

    private static func repoPath(prefix: String, name: String) -> String {
        let trimmed = prefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.isEmpty ? name : "\(trimmed)/\(name)"
    }
}
