import Foundation

struct BridgeError: Error {
    let message: String
    let code: String

    init(message: String, code: String = "") {
        self.message = message
        self.code = code
    }
}

struct RepositoryConnectionInfo {
    let headRevisionId: String
}

struct RepositoryStatus {
    let open: Bool
    let headRevisionId: String
}

class Bridge {
    // Points the bridge at an app-writable directory for its caches. Call once at
    // startup before any other bridge call.
    static func initialize(cacheDir: String) throws(BridgeError) {
        _ = try execute(command: "init", params: ["cacheDir": cacheDir])
    }

    // Closes the open repository, freeing the decrypted repository and its in-memory
    // snapshot. The persisted file-hash index is kept so background reminder scans
    // (checkFiles) keep working. The app calls this when it is sent to the background.
    static func closeRepository() throws(BridgeError) {
        _ = try execute(command: "closeRepository", params: [:])
    }

    // Encrypts the S3 credentials into the repository URI and returns it. The
    // bridge keeps no credential state. The caller stores the URI and re-sends it.
    static func encodeS3URI(
        hostUrl: String,
        passphrase: String,
        accessKeyId: String,
        accessKey: String
    ) throws(BridgeError) -> String {
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

    static func checkRepositoryOpen(url: String) throws(BridgeError) -> RepositoryStatus {
        let result = try execute(
            command: "checkRepositoryOpen",
            params: ["hostUrl": url])
        return RepositoryStatus(
            open: result["open"] as? Bool ?? false,
            headRevisionId: result["headRevisionId"] as? String ?? ""
        )
    }

    static func openRepository(url: String, password: String) throws(BridgeError)
        -> RepositoryConnectionInfo
    {
        let result = try execute(
            command: "openRepository",
            params: [
                "hostUrl": url,
                "password": password,
            ])
        return RepositoryConnectionInfo(headRevisionId: result["headRevisionId"] as? String ?? "")
    }

    static func uploadFile(localFilePath: String, repoFilePath: String) throws(BridgeError) -> String? {
        let result = try execute(
            command: "uploadFile",
            params: ["localFilePath": localFilePath, "repoFilePath": repoFilePath])

        if let skipped = result["skipped"] as? Bool, skipped {
            return nil
        }

        guard let revisionEntry = result["revisionEntry"] as? String else {
            throw BridgeError(message: "Missing revisionEntry in response")
        }

        return revisionEntry
    }

    static func commit(revisionEntries: [String], author: String, message: String)
        throws(BridgeError)
        -> String
    {
        let result = try execute(
            command: "commit",
            params: [
                "revisionEntries": revisionEntries,
                "author": author,
                "message": message,
            ])

        guard let revisionId = result["revisionId"] as? String else {
            throw BridgeError(message: "Missing revisionId in response")
        }

        return revisionId
    }

    static func checkFiles(sha256s: [String]) throws(BridgeError) -> [Bool] {
        let result = try execute(command: "checkFiles", params: ["sha256s": sha256s])

        guard let results = result["results"] as? [Bool] else {
            throw BridgeError(message: "Missing results in response")
        }

        return results
    }

    // Refreshes the persisted hash index if it was built for a different revision than
    // the open repository's current HEAD. Interactive callers (scan/share) run this
    // before checkFiles so membership is checked against the current HEAD; the merge
    // reminder skips it (it can't open the repository).
    static func ensureFileHashesAtHead() throws(BridgeError) {
        _ = try execute(command: "ensureFileHashesAtHead", params: [:])
    }

    static func triggerNetworkPermissionIfNeeded(url urlString: String) async throws {
        guard let url = URL(string: urlString) else {
            throw BridgeError(message: "Invalid URL")
        }
        // Configure URLSession to wait for connectivity (including permission dialog).
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForResource = 30.0
        configuration.timeoutIntervalForRequest = 10.0

        let session = URLSession(configuration: configuration)
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 10.0

        do {
            _ = try await session.data(for: request)
        } catch {
            // Check if it's a network error (can't connect) vs HTTP error (connected but got error
            // response).
            if let urlError = error as? URLError {
                switch urlError.code {
                case .notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .networkConnectionLost, .timedOut:
                    // These are actual connection failures.
                    throw BridgeError(
                        message: "Unable to connect to server. Please check your network connection and server URL.")
                default:
                    // Other errors (like HTTP errors) mean we connected successfully.
                    return
                }
            }
            // For any other error type, assume we connected.
        }
    }

    // The bridge keeps one global open repository, so concurrent calls (e.g. the
    // share screen scanning while the main screen uploads) must be serialized.
    private static let executeLock = NSLock()

    private static func execute(command: String, params: [String: Any]) throws(BridgeError) -> [String: Any] {
        guard let paramsData = try? JSONSerialization.data(withJSONObject: params),
            let paramsString = String(data: paramsData, encoding: .utf8)
        else {
            throw BridgeError(message: "Failed to serialize parameters")
        }

        let commandCString = strdup(command)
        let paramsCString = strdup(paramsString)
        defer {
            free(commandCString)
            free(paramsCString)
        }

        let resultString: String
        do {
            executeLock.lock()
            defer { executeLock.unlock() }
            guard let resultCString = GoBridge(commandCString, paramsCString) else {
                throw BridgeError(message: "Bridge returned nil")
            }
            resultString = String(cString: resultCString)
            free(resultCString)
        }

        guard let resultData = resultString.data(using: String.Encoding.utf8),
            let result = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any]
        else {
            throw BridgeError(message: "Failed to parse response")
        }

        if let error = result["error"] as? [String: Any],
            let errorMessage = error["message"] as? String
        {
            let code = error["code"] as? String ?? ""
            throw BridgeError(message: errorMessage, code: code)
        }

        return result
    }
}
