import Foundation

struct BridgeError: Error {
    let message: String
    let code: String?

    var isPassphraseRequired: Bool {
        code == "passphrase_required"
    }

    var isNoSyncTargets: Bool {
        code == "no_sync_targets"
    }

    var isSyncAlreadyRunning: Bool {
        code == "sync_already_running"
    }

    var isLocalAccessDenied: Bool {
        code == "local_access_denied"
    }

    var isNetworkError: Bool {
        code == "network_unreachable"
    }
}

struct SyncTargetInfo: Identifiable, Equatable {
    var id: String { name }
    let name: String
    let uri: String
    let displayURI: String
}

struct MergeWorkspaceStatus {
    let running: Bool
    let canCancel: Bool
    let completed: Bool
    let cancelled: Bool
    let upToDate: Bool
    let statusMessage: String
    let detailedOutput: String
    let revisionId: String
    let errorMessage: String
    // Defaulted so the existing constructor call sites compile unchanged.
    var errorIsNetwork: Bool = false
}

struct StatusWorkspaceStatus {
    let running: Bool
    let canCancel: Bool
    let completed: Bool
    let cancelled: Bool
    let statusMessage: String
    let detailedOutput: String
    let errorMessage: String
}

struct WorkspaceInspection {
    let exists: Bool
    let hostURL: String
    let repoPathPrefix: String
    let hasStoredAccess: Bool
}

enum Bridge {
    // Encrypts the S3 credentials into the repository URI and returns it. The
    // bridge keeps no credential state; the caller stores the URI and re-sends it.
    static func encodeS3URI(
        hostUrl: String,
        passphrase: String,
        accessKeyId: String,
        accessKey: String
    ) throws -> String {
        let result = try execute(
            command: "encodeS3URI",
            params: [
                "hostUrl": hostUrl,
                "passphrase": passphrase,
                "accessKeyId": accessKeyId,
                "accessKey": accessKey,
            ])
        return result["uri"] as? String ?? ""
    }

    static func inspectWorkspace(localPath: String) throws -> WorkspaceInspection {
        let result = try execute(command: "inspectWorkspace", params: ["localPath": localPath])
        return WorkspaceInspection(
            exists: result["Exists"] as? Bool ?? result["exists"] as? Bool ?? false,
            hostURL: result["HostURL"] as? String ?? result["hostURL"] as? String ?? "",
            repoPathPrefix: result["RepoPathPrefix"] as? String ?? result["repoPathPrefix"] as? String ?? "",
            hasStoredAccess: result["HasStoredAccess"] as? Bool ?? result["hasStoredAccess"] as? Bool ?? false
        )
    }

    static func checkFileRepositoryExists(localPath: String) throws -> Bool {
        let result = try execute(command: "checkFileRepositoryExists", params: ["localPath": localPath])
        return result["exists"] as? Bool ?? false
    }

    static func initNewFileRepository(localPath: String, password: String) throws {
        _ = try execute(
            command: "initNewFileRepository",
            params: [
                "localPath": localPath,
                "password": password,
            ])
    }

    static func configureWorkspace(url: String, localPath: String, repoPathPrefix: String) throws {
        _ = try execute(
            command: "configureWorkspace",
            params: [
                "hostUrl": url,
                "localPath": localPath,
                "repoPathPrefix": repoPathPrefix,
            ])
    }

    static func storeWorkspacePassphrase(localPath: String, password: String) throws {
        _ = try execute(
            command: "storeWorkspacePassphrase",
            params: [
                "localPath": localPath,
                "password": password,
            ])
    }

    static func clearWorkspacePassphrase(hostURL: String) throws {
        _ = try execute(
            command: "clearWorkspacePassphrase",
            params: [
                "hostUrl": hostURL
            ])
    }

    static func testWorkspaceAccess(localPath: String, password: String?) throws {
        var params: [String: Any] = ["localPath": localPath]
        if let password {
            params["password"] = password
        }
        _ = try execute(command: "testWorkspaceAccess", params: params)
    }
    static func startMergeWorkspace(
        localPath: String,
        password: String?,
        author: String,
        message: String,
    ) throws {
        var params: [String: Any] = [
            "localPath": localPath,
            "author": author,
            "message": message,
        ]
        if let password {
            params["password"] = password
        }
        _ = try execute(command: "startMergeWorkspace", params: params)
    }

    static func getMergeWorkspaceStatus(localPath: String) throws -> MergeWorkspaceStatus {
        let result = try execute(command: "getMergeWorkspaceStatus", params: ["localPath": localPath])
        return MergeWorkspaceStatus(
            running: result["running"] as? Bool ?? false,
            canCancel: result["canCancel"] as? Bool ?? false,
            completed: result["completed"] as? Bool ?? false,
            cancelled: result["cancelled"] as? Bool ?? false,
            upToDate: result["upToDate"] as? Bool ?? false,
            statusMessage: result["statusMessage"] as? String ?? "",
            detailedOutput: result["detailedOutput"] as? String ?? "",
            revisionId: result["revisionId"] as? String ?? "",
            errorMessage: result["errorMessage"] as? String ?? "",
            errorIsNetwork: result["errorIsNetwork"] as? Bool ?? false
        )
    }

    static func cancelMergeWorkspace(localPath: String) throws {
        _ = try execute(command: "cancelMergeWorkspace", params: ["localPath": localPath])
    }

    static func startStatusWorkspace(
        localPath: String,
        password: String?,
    ) throws {
        var params: [String: Any] = [
            "localPath": localPath
        ]
        if let password {
            params["password"] = password
        }
        _ = try execute(command: "startStatusWorkspace", params: params)
    }

    static func getStatusWorkspaceStatus(localPath: String) throws -> StatusWorkspaceStatus {
        let result = try execute(command: "getStatusWorkspaceStatus", params: ["localPath": localPath])
        return StatusWorkspaceStatus(
            running: result["running"] as? Bool ?? false,
            canCancel: result["canCancel"] as? Bool ?? false,
            completed: result["completed"] as? Bool ?? false,
            cancelled: result["cancelled"] as? Bool ?? false,
            statusMessage: result["statusMessage"] as? String ?? "",
            detailedOutput: result["detailedOutput"] as? String ?? "",
            errorMessage: result["errorMessage"] as? String ?? ""
        )
    }

    static func cancelStatusWorkspace(localPath: String) throws {
        _ = try execute(command: "cancelStatusWorkspace", params: ["localPath": localPath])
    }

    static func listSyncTargets(localPath: String) throws -> [SyncTargetInfo] {
        let result = try execute(command: "listSyncTargets", params: ["localPath": localPath])
        let raw = result["targets"] as? [[String: Any]] ?? []
        return raw.map { entry in
            let uri = entry["uri"] as? String ?? ""
            return SyncTargetInfo(
                name: entry["name"] as? String ?? "",
                uri: uri,
                displayURI: entry["displayUri"] as? String ?? uri
            )
        }
    }

    static func addSyncTarget(localPath: String, name: String, uri: String, password: String?) throws {
        var params: [String: Any] = [
            "localPath": localPath,
            "name": name,
            "uri": uri,
        ]
        if let password {
            params["password"] = password
        }
        _ = try execute(command: "addSyncTarget", params: params)
    }

    static func deleteSyncTarget(localPath: String, name: String) throws {
        _ = try execute(command: "deleteSyncTarget", params: ["localPath": localPath, "name": name])
    }

    static func startSyncWorkspace(localPath: String, password: String?, workers: Int) throws {
        var params: [String: Any] = [
            "localPath": localPath,
            "workers": workers,
        ]
        if let password {
            params["password"] = password
        }
        _ = try execute(command: "startSyncWorkspace", params: params)
    }

    static func cancelSyncWorkspace(localPath: String) throws {
        _ = try execute(command: "cancelSyncWorkspace", params: ["localPath": localPath])
    }

    static func getSyncWorkspaceStatus(localPath: String) throws -> MergeWorkspaceStatus {
        let result = try execute(command: "getSyncWorkspaceStatus", params: ["localPath": localPath])
        return MergeWorkspaceStatus(
            running: result["running"] as? Bool ?? false,
            canCancel: result["canCancel"] as? Bool ?? false,
            completed: result["completed"] as? Bool ?? false,
            cancelled: result["cancelled"] as? Bool ?? false,
            upToDate: result["upToDate"] as? Bool ?? false,
            statusMessage: result["statusMessage"] as? String ?? "",
            detailedOutput: result["detailedOutput"] as? String ?? "",
            revisionId: result["revisionId"] as? String ?? "",
            errorMessage: result["errorMessage"] as? String ?? "",
            errorIsNetwork: result["errorIsNetwork"] as? Bool ?? false
        )
    }

    private static func execute(command: String, params: [String: Any]) throws -> [String: Any] {
        let paramsData = try JSONSerialization.data(withJSONObject: params)
        guard let paramsString = String(data: paramsData, encoding: .utf8) else {
            throw BridgeError(message: "Failed to serialize parameters", code: nil)
        }
        let commandCString = strdup(command)
        let paramsCString = strdup(paramsString)
        defer {
            free(commandCString)
            free(paramsCString)
        }
        guard let resultCString = GoBridge(commandCString, paramsCString) else {
            throw BridgeError(message: "Bridge returned nil", code: nil)
        }
        defer { free(resultCString) }
        let resultString = String(cString: resultCString)
        guard let resultData = resultString.data(using: String.Encoding.utf8),
            let result = try JSONSerialization.jsonObject(with: resultData) as? [String: Any]
        else {
            throw BridgeError(message: "Failed to parse response", code: nil)
        }
        if let error = result["error"] as? [String: Any] {
            throw BridgeError(
                message: error["message"] as? String ?? "Unknown bridge error",
                code: error["code"] as? String,
            )
        }
        return result
    }
}
