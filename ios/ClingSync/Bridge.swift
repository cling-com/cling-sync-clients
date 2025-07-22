import Foundation

struct BridgeError: Error {
    let message: String
}

class Bridge {
    static func ensureOpen(url: String, password: String) throws(BridgeError) {
        let params: [String: Any] = [
            "hostUrl": url,
            "password": password,
        ]

        guard let paramsData = try? JSONSerialization.data(withJSONObject: params),
            let paramsString = String(data: paramsData, encoding: .utf8)
        else {
            throw BridgeError(message: "Failed to serialize parameters")
        }

        let commandCString = strdup("ensureOpen")
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

        guard let resultData = resultString.data(using: .utf8),
            let result = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any]
        else {
            throw BridgeError(message: "Failed to parse response")
        }

        if let error = result["error"] as? [String: Any],
            let errorMessage = error["message"] as? String
        {
            throw BridgeError(message: errorMessage)
        }
    }

    static func uploadFile(filePath: String, repoPathPrefix: String) throws(BridgeError) -> String {
        let params: [String: Any] = [
            "filePath": filePath,
            "repoPathPrefix": repoPathPrefix,
        ]

        guard let paramsData = try? JSONSerialization.data(withJSONObject: params),
            let paramsString = String(data: paramsData, encoding: .utf8)
        else {
            throw BridgeError(message: "Failed to serialize parameters")
        }

        let commandCString = strdup("uploadFile")
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

        guard let resultData = resultString.data(using: .utf8),
            let result = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any]
        else {
            throw BridgeError(message: "Failed to parse response")
        }

        if let error = result["error"] as? [String: Any],
            let errorMessage = error["message"] as? String
        {
            throw BridgeError(message: errorMessage)
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
        let params: [String: Any] = [
            "revisionEntries": revisionEntries,
            "author": author,
            "message": message,
        ]

        guard let paramsData = try? JSONSerialization.data(withJSONObject: params),
            let paramsString = String(data: paramsData, encoding: .utf8)
        else {
            throw BridgeError(message: "Failed to serialize parameters")
        }

        let commandCString = strdup("commit")
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

        guard let resultData = resultString.data(using: .utf8),
            let result = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any]
        else {
            throw BridgeError(message: "Failed to parse response")
        }

        if let error = result["error"] as? [String: Any],
            let errorMessage = error["message"] as? String
        {
            throw BridgeError(message: errorMessage)
        }

        guard let revisionId = result["revisionId"] as? String else {
            throw BridgeError(message: "Missing revisionId in response")
        }

        return revisionId
    }

    static func checkFiles(sha256s: [String]) throws(BridgeError) -> [String] {
        let params: [String: Any] = [
            "sha256s": sha256s
        ]

        guard let paramsData = try? JSONSerialization.data(withJSONObject: params),
            let paramsString = String(data: paramsData, encoding: .utf8)
        else {
            throw BridgeError(message: "Failed to serialize parameters")
        }

        let commandCString = strdup("checkFiles")
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

        guard let resultData = resultString.data(using: .utf8),
            let result = try? JSONSerialization.jsonObject(with: resultData) as? [String: Any]
        else {
            throw BridgeError(message: "Failed to parse response")
        }

        if let error = result["error"] as? [String: Any],
            let errorMessage = error["message"] as? String
        {
            throw BridgeError(message: errorMessage)
        }

        guard let results = result["results"] as? [String] else {
            throw BridgeError(message: "Missing results in response")
        }

        return results
    }

    // First, make a HEAD request to trigger network permission dialog if needed.
    // Then, connect to the server using `ensureOpen`.
    static func connectToServer(url: String, password: String) async throws {
        try await triggerNetworkPermissionIfNeeded(url: url)
        try ensureOpen(url: url, password: password)
    }

    private static func triggerNetworkPermissionIfNeeded(url urlString: String) async throws {
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
}
