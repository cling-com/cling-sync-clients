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

// Persists the encrypted S3 repository URI per repository, so the credentials
// (encrypted with the passphrase) are entered once and re-sent thereafter. Keyed
// by the repository id (the host URL with surrounding slashes trimmed), matching
// PassphraseStore, so invalidating a repository clears both by the same key.
enum RepositoryURIStore {
    private static let key = "repositoryURIs"

    static func get(for repository: String) -> String? {
        dictionary()[normalize(repository)]
    }

    static func set(_ uri: String, for repository: String) {
        var dict = dictionary()
        dict[normalize(repository)] = uri
        UserDefaults.standard.set(dict, forKey: key)
    }

    static func clear(for repository: String) {
        var dict = dictionary()
        dict.removeValue(forKey: normalize(repository))
        UserDefaults.standard.set(dict, forKey: key)
    }

    private static func normalize(_ repository: String) -> String {
        repository.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func dictionary() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }
}
