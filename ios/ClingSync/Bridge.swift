import Foundation

struct BridgeError: Error {
    let message: String
}

struct RepositoryConnectionInfo {
    let headRevisionId: String
}

struct RepositoryStatus {
    let open: Bool
    let headRevisionId: String
}

class Bridge {
    static func checkRepositoryOpen(url: String, repoPathPrefix: String) throws(BridgeError) -> RepositoryStatus {
        let result = try execute(
            command: "checkRepositoryOpen",
            params: ["hostUrl": url, "repoPathPrefix": repoPathPrefix])
        return RepositoryStatus(
            open: result["open"] as? Bool ?? false,
            headRevisionId: result["headRevisionId"] as? String ?? ""
        )
    }

    static func openRepository(url: String, password: String, repoPathPrefix: String) throws(BridgeError)
        -> RepositoryConnectionInfo
    {
        let result = try execute(
            command: "openRepository",
            params: [
                "hostUrl": url,
                "password": password,
                "repoPathPrefix": repoPathPrefix,
            ])
        return RepositoryConnectionInfo(headRevisionId: result["headRevisionId"] as? String ?? "")
    }

    static func uploadFile(filePath: String) throws(BridgeError) -> String? {
        let result = try execute(command: "uploadFile", params: ["filePath": filePath])

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

    static func checkFiles(sha256s: [String]) throws(BridgeError) -> [String] {
        let result = try execute(command: "checkFiles", params: ["sha256s": sha256s])

        guard let results = result["results"] as? [String] else {
            throw BridgeError(message: "Missing results in response")
        }

        return results
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

        guard let resultCString = GoBridge(commandCString, paramsCString) else {
            throw BridgeError(message: "Bridge returned nil")
        }

        let resultString = String(cString: resultCString)
        free(resultCString)

        guard let resultData = resultString.data(using: String.Encoding.utf8),
            let result = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any]
        else {
            throw BridgeError(message: "Failed to parse response")
        }

        if let error = result["error"] as? [String: Any],
            let errorMessage = error["message"] as? String
        {
            throw BridgeError(message: errorMessage)
        }

        return result
    }
}
