import Foundation

enum RepositoryURI {
    static func isCleartextS3(_ url: String) -> Bool {
        let lower = url.lowercased()
        let isS3 = lower.hasPrefix("s3+http://") || lower.hasPrefix("s3+https://")
        return isS3 && !hasEmbeddedCredentials(url)
    }

    static func hasEmbeddedCredentials(_ url: String) -> Bool {
        guard let schemeEnd = url.range(of: "://") else { return false }
        return url[schemeEnd.upperBound...].prefix(while: { $0 != "/" }).contains("@")
    }
}

// Persists the encrypted S3 repository URI per cleartext URL, so the credentials
// (encrypted with the passphrase) are entered once and re-sent thereafter.
enum RepositoryURIStore {
    private static let key = "repositoryURIs"

    static func get(for hostURL: String) -> String? {
        dictionary()[hostURL]
    }

    static func set(_ uri: String, for hostURL: String) {
        var dict = dictionary()
        dict[hostURL] = uri
        UserDefaults.standard.set(dict, forKey: key)
    }

    static func clear(for hostURL: String) {
        var dict = dictionary()
        dict.removeValue(forKey: hostURL)
        UserDefaults.standard.set(dict, forKey: key)
    }

    private static func dictionary() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }
}
