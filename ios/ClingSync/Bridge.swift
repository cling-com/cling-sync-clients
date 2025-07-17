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
}
