import Foundation
import Security

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
//
// Stored in the Keychain with kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly, not
// in UserDefaults: the encoded URI carries the passphrase-encrypted S3 secret, which
// is also an offline brute-force oracle for the passphrase. UserDefaults is captured
// by iCloud/iTunes backups; a ThisDeviceOnly Keychain item never is.
enum RepositoryURIStore {
    private static let service = (Bundle.main.bundleIdentifier ?? "com.cling.ClingSync") + ".repositoryURI"
    // Legacy location, migrated on first read then removed.
    private static let legacyKey = "repositoryURIs"

    static func get(for repository: String) -> String? {
        let account = normalize(repository)
        if let stored = keychainGet(account) {
            return stored
        }
        // One-time migration from the old UserDefaults dictionary.
        guard let legacy = legacyDictionary()[account] else { return nil }
        set(legacy, for: repository)
        removeLegacy(account)
        return legacy
    }

    static func set(_ uri: String, for repository: String) {
        let account = normalize(repository)
        let data = Data(uri.utf8)
        let base = baseQuery(account)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = base
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            attributes[kSecUseDataProtectionKeychain as String] = true
            SecItemAdd(attributes as CFDictionary, nil)
        }
    }

    static func clear(for repository: String) {
        let account = normalize(repository)
        SecItemDelete(baseQuery(account) as CFDictionary)
        removeLegacy(account)
    }

    // Removes every stored URI. Used by the app's `--reset` test entry point.
    static func resetAll() {
        SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ] as CFDictionary)
        UserDefaults.standard.removeObject(forKey: legacyKey)
    }

    private static func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }

    private static func keychainGet(_ account: String) -> String? {
        var query = baseQuery(account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data
        else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    private static func normalize(_ repository: String) -> String {
        repository.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    private static func legacyDictionary() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: legacyKey) as? [String: String] ?? [:]
    }

    private static func removeLegacy(_ account: String) {
        var dict = legacyDictionary()
        guard dict.removeValue(forKey: account) != nil else { return }
        if dict.isEmpty {
            UserDefaults.standard.removeObject(forKey: legacyKey)
        } else {
            UserDefaults.standard.set(dict, forKey: legacyKey)
        }
    }
}
