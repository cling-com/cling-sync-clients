import Foundation

// A unified poll snapshot across the three operations. Mirrors the bridge
// flag-structs and adds isEmptyRow (the old "filtered-out" row, which the store
// turns into WorkUpdate.absent so a terminal state stays sticky, Bug B).
struct OperationProgress: Equatable {
    let running: Bool
    let canCancel: Bool
    let completed: Bool
    let cancelled: Bool
    let upToDate: Bool
    let statusMessage: String
    let detailedOutput: String
    let revisionId: String
    let errorMessage: String
    let errorIsNetwork: Bool

    var isEmptyRow: Bool { !running && !completed && statusMessage.isEmpty && errorMessage.isEmpty }
}

extension OperationProgress {
    init(merge status: MergeWorkspaceStatus) {
        self.init(
            running: status.running, canCancel: status.canCancel, completed: status.completed,
            cancelled: status.cancelled, upToDate: status.upToDate, statusMessage: status.statusMessage,
            detailedOutput: status.detailedOutput, revisionId: status.revisionId,
            errorMessage: status.errorMessage, errorIsNetwork: status.errorIsNetwork)
    }

    init(status: StatusWorkspaceStatus) {
        self.init(
            running: status.running, canCancel: status.canCancel, completed: status.completed,
            cancelled: status.cancelled, upToDate: false, statusMessage: status.statusMessage,
            detailedOutput: status.detailedOutput, revisionId: "",
            errorMessage: status.errorMessage, errorIsNetwork: false)
    }
}

// The store's seam onto the synchronous Go bridge: thin async wrappers, each
// running the bridge call off the main actor. Injected so tests can substitute a
// fake (pure store tests) or the real bridge (real-bridge store tests).
protocol WorkspaceGateway {
    func inspect(localPath: String) async throws -> WorkspaceInspection
    func lastMergeDate(localPath: String) async -> Date?
    func checkFileRepositoryExists(localPath: String) async throws -> Bool
    func initNewFileRepository(localPath: String, password: String) async throws
    func configureWorkspace(uri: String, localPath: String, repoPathPrefix: String) async throws
    func encodeS3URI(hostURL: String, passphrase: String, accessKeyId: String, accessKey: String) async throws -> String
    func testWorkspaceAccess(localPath: String, password: String?) async throws
    func storeWorkspacePassphrase(localPath: String, password: String) async throws
    func clearWorkspacePassphrase(uri: String) async throws
    func startMerge(localPath: String, password: String?, author: String) async throws
    func startStatus(localPath: String, password: String?) async throws
    func startSync(localPath: String, password: String?, workers: Int) async throws
    func poll(kind: OperationKind, localPath: String) async throws -> OperationProgress
    func cancel(kind: OperationKind, localPath: String) async throws
    func listSyncTargets(localPath: String) async throws -> [SyncTargetInfo]
    func addSyncTarget(localPath: String, name: String, uri: String, password: String?) async throws
    func deleteSyncTarget(localPath: String, name: String) async throws
}

struct RealWorkspaceGateway: WorkspaceGateway {
    func inspect(localPath: String) async throws -> WorkspaceInspection {
        try await detached { try Bridge.inspectWorkspace(localPath: localPath) }
    }

    // The "Last Merge" time: the mtime of the workspace's refs/head, which a merge
    // rewrites. nil when the file is absent or still the root revision (all-zero hex,
    // written at config), i.e. never merged. refs are plaintext, so no passphrase.
    func lastMergeDate(localPath: String) async -> Date? {
        await Task.detached(priority: .utility) {
            let path = (localPath as NSString).appendingPathComponent(".cling/workspace/refs/head")
            guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
            let revision = content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard revision.contains(where: { $0 != "0" }) else { return nil }
            return (try? FileManager.default.attributesOfItem(atPath: path))?[.modificationDate] as? Date
        }.value
    }

    func checkFileRepositoryExists(localPath: String) async throws -> Bool {
        try await detached { try Bridge.checkFileRepositoryExists(localPath: localPath) }
    }

    func initNewFileRepository(localPath: String, password: String) async throws {
        try await detached { try Bridge.initNewFileRepository(localPath: localPath, password: password) }
    }

    func configureWorkspace(uri: String, localPath: String, repoPathPrefix: String) async throws {
        try await detached {
            try Bridge.configureWorkspace(url: uri, localPath: localPath, repoPathPrefix: repoPathPrefix)
        }
    }

    func encodeS3URI(hostURL: String, passphrase: String, accessKeyId: String, accessKey: String) async throws -> String
    {
        try await detached {
            try Bridge.encodeS3URI(
                hostUrl: hostURL, passphrase: passphrase, accessKeyId: accessKeyId, accessKey: accessKey)
        }
    }

    func testWorkspaceAccess(localPath: String, password: String?) async throws {
        try await detached { try Bridge.testWorkspaceAccess(localPath: localPath, password: password) }
    }

    func storeWorkspacePassphrase(localPath: String, password: String) async throws {
        try await detached { try Bridge.storeWorkspacePassphrase(localPath: localPath, password: password) }
    }

    func clearWorkspacePassphrase(uri: String) async throws {
        try await detached { try Bridge.clearWorkspacePassphrase(hostURL: uri) }
    }

    func startMerge(localPath: String, password: String?, author: String) async throws {
        try await detached {
            try Bridge.startMergeWorkspace(
                localPath: localPath, password: password, author: author, message: "Merge from macOS menu bar")
        }
    }

    func startStatus(localPath: String, password: String?) async throws {
        try await detached { try Bridge.startStatusWorkspace(localPath: localPath, password: password) }
    }

    func startSync(localPath: String, password: String?, workers: Int) async throws {
        try await detached { try Bridge.startSyncWorkspace(localPath: localPath, password: password, workers: workers) }
    }

    func poll(kind: OperationKind, localPath: String) async throws -> OperationProgress {
        try await detached {
            switch kind {
            case .merge: return OperationProgress(merge: try Bridge.getMergeWorkspaceStatus(localPath: localPath))
            case .sync: return OperationProgress(merge: try Bridge.getSyncWorkspaceStatus(localPath: localPath))
            case .status: return OperationProgress(status: try Bridge.getStatusWorkspaceStatus(localPath: localPath))
            }
        }
    }

    func cancel(kind: OperationKind, localPath: String) async throws {
        try await detached {
            switch kind {
            case .merge: try Bridge.cancelMergeWorkspace(localPath: localPath)
            case .sync: try Bridge.cancelSyncWorkspace(localPath: localPath)
            case .status: try Bridge.cancelStatusWorkspace(localPath: localPath)
            }
        }
    }

    func listSyncTargets(localPath: String) async throws -> [SyncTargetInfo] {
        try await detached { try Bridge.listSyncTargets(localPath: localPath) }
    }

    func addSyncTarget(localPath: String, name: String, uri: String, password: String?) async throws {
        try await detached { try Bridge.addSyncTarget(localPath: localPath, name: name, uri: uri, password: password) }
    }

    func deleteSyncTarget(localPath: String, name: String) async throws {
        try await detached { try Bridge.deleteSyncTarget(localPath: localPath, name: name) }
    }

    private func detached<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: work).value
    }
}
