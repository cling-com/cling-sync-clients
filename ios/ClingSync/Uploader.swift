import Photos
import SwiftUI
import UIKit

enum UploaderState {
    case preparing
    case sending
    case committing
    case done
    case aborted
    case error
}

class Uploader: ObservableObject {
    @AppStorage("hostURL") private var hostURL = ""
    @AppStorage("passphrase") private var passphrase = ""
    @AppStorage("repoPathPrefix") private var repoPathPrefix = ""
    @AppStorage("author") private var author = "iOS User"
    @Published var currentlySending: File?
    @Published var uploadedBytes: Int64 = 0
    @Published var errorMessage: String = ""
    @Published var state: UploaderState = .preparing

    var finished: Bool {
        return state == .done || state == .aborted || state == .error
    }

    var totalBytes: Int64 {
        files.reduce(0) { $0 + $1.size }
    }

    let files: [File]
    private var task: Task<Void, Never>?

    init(files: [File]) {
        self.files = files
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    public func start() {
        if files.isEmpty {
            return
        }
        for file in files {
            file.uploadState = .waiting
        }
        task = Task {
            do {
                try Bridge.ensureOpen(url: hostURL, password: passphrase, repoPathPrefix: repoPathPrefix)
                var revisionEntries: [String] = []

                // Upload each file sequentially.
                for file in files {
                    guard !Task.isCancelled else { break }
                    await MainActor.run {
                        state = .sending
                        file.uploadState = .sending
                        currentlySending = file
                    }
                    let revisionEntry = try await uploadFile(file)
                    revisionEntries.append(revisionEntry)

                    await MainActor.run {
                        file.uploadState = .sentWaitingCommit
                        file.revisionEntry = revisionEntry
                        uploadedBytes += file.size
                    }
                }
                guard !Task.isCancelled else {
                    throw CancellationError()
                }

                await MainActor.run {
                    state = .committing
                    currentlySending = nil
                }

                // Commit all uploaded files
                let deviceModel = await UIDevice.current.model
                let deviceName = await UIDevice.current.name
                _ = try Bridge.commit(
                    revisionEntries: revisionEntries,
                    author: author,
                    message: "Backup \(files.count) file\(files.count == 1 ? "" : "s") from \(deviceName)"
                )

                // Mark all committed files as uploaded
                await MainActor.run {
                    for file in files {
                        file.uploadState = .done
                    }
                    state = .done
                    task = nil
                }

            } catch is CancellationError {
                await MainActor.run {
                    // Reset files to none state if cancelled.
                    for file in files {
                        file.uploadState = .none
                    }
                    task = nil
                }
            } catch {
                await MainActor.run {
                    // Reset files to none state on error.
                    for file in files {
                        file.uploadState = .none
                    }
                    if let bridgeError = error as? BridgeError {
                        errorMessage = bridgeError.message
                    } else {
                        errorMessage = error.localizedDescription
                    }
                    state = .error
                }
            }
        }
    }

    public func abort() {
        task?.cancel()
        state = .aborted
        for file in files {
            file.uploadState = .none
        }
    }

    // Upload the file by first writing it to temporary file.
    private func uploadFile(_ file: File) async throws -> String {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        let resources = PHAssetResource.assetResources(for: file.asset)

        // Typically, the first resource is the original.
        // todo: perhaps we should (optionally) upload all resources? If a PHAsset has multiple
        //       resources, we should display them all and let the user decide.
        guard let resource = resources.first else {
            throw BridgeError(message: "No resource found for asset")
        }
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(file.name)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(
                for: resource, toFile: tempURL, options: options
            ) { error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
        let revisionEntry = try Bridge.uploadFile(
            filePath: tempURL.path)
        try? FileManager.default.removeItem(at: tempURL)
        return revisionEntry
    }
}
