import Foundation

struct BridgeError: Error {
    let message: String
    let code: String?

    var isPassphraseRequired: Bool {
        code == "passphrase_required"
    }

    var isS3CredentialsRequired: Bool {
        code == "s3_credentials_required"
    }
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
}

struct StatusWorkspaceStatus {
    let running: Bool
    let completed: Bool
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
    // Gives the Go bridge a writable directory for its S3 credentials map.
    // Must be called once per app launch before any S3-backed workspace access.
    static func initBridge(dataDir: String) throws {
        _ = try execute(command: "initBridge", params: ["dataDir": dataDir])
    }

    static func encryptAndStoreS3Credentials(
        hostUrl: String,
        passphrase: String,
        accessKeyId: String,
        accessKey: String
    ) throws {
        _ = try execute(
            command: "encryptAndStoreS3Credentials",
            params: [
                "hostUrl": hostUrl,
                "passphrase": passphrase,
                "accessKeyId": accessKeyId,
                "accessKey": accessKey,
            ])
    }

    static func clearStoredS3Credentials(hostUrl: String) throws {
        _ = try execute(command: "clearStoredS3Credentials", params: ["hostUrl": hostUrl])
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
        storePassword: Bool,
    ) throws {
        var params: [String: Any] = [
            "localPath": localPath,
            "author": author,
            "message": message,
            "storePassword": storePassword,
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
            errorMessage: result["errorMessage"] as? String ?? ""
        )
    }

    static func cancelMergeWorkspace(localPath: String) throws {
        _ = try execute(command: "cancelMergeWorkspace", params: ["localPath": localPath])
    }

    static func startStatusWorkspace(
        localPath: String,
        password: String?,
        storePassword: Bool,
    ) throws {
        var params: [String: Any] = [
            "localPath": localPath,
            "storePassword": storePassword,
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
            completed: result["completed"] as? Bool ?? false,
            statusMessage: result["statusMessage"] as? String ?? "",
            detailedOutput: result["detailedOutput"] as? String ?? "",
            errorMessage: result["errorMessage"] as? String ?? ""
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
