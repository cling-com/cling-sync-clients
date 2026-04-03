import Photos
import UIKit

enum UploaderState {
    case preparing
    case sending
    case committing
    case done
    case aborted
    case error
}

final class Uploader: ObservableObject {
    @Published var currentlySending: MediaFile?
    @Published var uploadedBytes: Int64 = 0
    @Published var errorMessage = ""
    @Published var state: UploaderState = .preparing

    let files: [MediaFile]

    private let configuration: RepositoryConfiguration
    private let headRevisionId: String
    private var task: Task<Void, Never>?

    init(files: [MediaFile], configuration: RepositoryConfiguration, headRevisionId: String) {
        self.files = files
        self.configuration = configuration
        self.headRevisionId = headRevisionId
    }

    var finished: Bool {
        state == .done || state == .aborted || state == .error
    }

    var totalBytes: Int64 {
        files.reduce(0) { $0 + $1.size }
    }

    func start() {
        guard !files.isEmpty else { return }
        for file in files {
            file.uploadState = .waiting
        }
        let files = files
        let configuration = configuration
        let headRevisionId = headRevisionId
        task = Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            await self.executeUploadTask(files: files, configuration: configuration, headRevisionId: headRevisionId)
        }
    }

    func abort() {
        task?.cancel()
    }

    private func executeUploadTask(
        files: [MediaFile],
        configuration: RepositoryConfiguration,
        headRevisionId: String
    ) async {
        do {
            let result = try await transfer(
                files: files, configuration: configuration, headRevisionID: headRevisionId)
            SyncIndexStore.shared.add(
                result.records, repositoryID: configuration.repositoryID, headRevisionID: result.headRevisionID)
            await MainActor.run {
                self.currentlySending = nil
                self.state = .done
                self.task = nil
            }
        } catch is CancellationError {
            await handleCancellation()
        } catch let error as BridgeError {
            await failUpload(message: error.message)
        } catch {
            await failUpload(message: error.localizedDescription)
        }
    }

    private func transfer(
        files: [MediaFile],
        configuration: RepositoryConfiguration,
        headRevisionID: String
    ) async throws -> (records: [SyncedFileRecord], headRevisionID: String) {
        var syncedRecords: [SyncedFileRecord] = []
        var revisionEntries: [String] = []
        var currentHeadRevisionID = headRevisionID

        for file in files {
            try Task.checkCancellation()
            await MainActor.run {
                self.state = .sending
                self.currentlySending = file
                file.uploadState = .sending
            }

            if let revisionEntry = try await upload(file) {
                revisionEntries.append(revisionEntry)
                await MainActor.run {
                    file.revisionEntry = revisionEntry
                    file.uploadState = .sentWaitingCommit
                    self.uploadedBytes += file.size
                }
            } else {
                await MainActor.run {
                    file.uploadState = .done
                    self.uploadedBytes += file.size
                }
            }
            syncedRecords.append(file.syncedRecord)
        }

        await MainActor.run {
            self.currentlySending = nil
            self.state = .committing
        }
        if !revisionEntries.isEmpty {
            let author = configuration.author.isEmpty ? UIDevice.current.name : configuration.author
            currentHeadRevisionID = try Bridge.commit(
                revisionEntries: revisionEntries,
                author: author,
                message: "Backup \(files.count) file\(files.count == 1 ? "" : "s") from \(UIDevice.current.name)"
            )
        }

        await MainActor.run {
            for file in files {
                file.uploadState = .done
            }
        }
        return (syncedRecords, currentHeadRevisionID)
    }

    private func handleCancellation() async {
        await MainActor.run {
            self.currentlySending = nil
            for file in self.files {
                file.uploadState = .none
            }
            self.state = .aborted
            self.task = nil
        }
    }

    private func failUpload(message: String) async {
        await MainActor.run {
            self.currentlySending = nil
            for file in self.files {
                file.uploadState = .none
            }
            self.errorMessage = message
            self.state = .error
            self.task = nil
        }
    }

    private func repoFilePath(for file: MediaFile) -> String {
        let prefix = configuration.repoPathPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if prefix.isEmpty {
            return file.name
        }
        return "\(prefix)/\(file.name)"
    }

    private func upload(_ file: MediaFile) async throws -> String? {
        let repoPath = repoFilePath(for: file)
        if let localFileURL = file.localFileURL {
            return try Bridge.uploadFile(localFilePath: localFileURL.path, repoFilePath: repoPath)
        }

        guard let resource = file.resource else {
            throw BridgeError(message: "Missing file source")
        }
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                file.id.replacingOccurrences(of: "/", with: "_")
                    .replacingOccurrences(of: ":", with: "_"),
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        let tempURL = tempDirectory.appendingPathComponent(file.name)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: tempURL, options: options) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        defer {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        return try Bridge.uploadFile(localFilePath: tempURL.path, repoFilePath: repoPath)
    }
}
