import Foundation
import Security

// Per-workspace storage for the directly-openable repository URI. For S3 that URI
// carries the passphrase-encrypted credentials, which is also an offline brute-force
// oracle for the passphrase, so it must not land in Time Machine. It is kept in the
// Keychain with kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly (device-bound,
// never backed up or migrated) rather than in UserDefaults, which Time Machine copies.
protocol CredentialStore {
    func get(_ account: String) -> String?
    func set(_ account: String, _ value: String)
    func remove(_ account: String)
}

final class KeychainCredentialStore: CredentialStore {
    private let service = (Bundle.main.bundleIdentifier ?? "com.cling.ClingSync") + ".repositoryURI"

    func get(_ account: String) -> String? {
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

    func set(_ account: String, _ value: String) {
        let data = Data(value.utf8)
        let base = baseQuery(account)
        let status = SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var attributes = base
            attributes[kSecValueData as String] = data
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemAdd(attributes as CFDictionary, nil)
        }
    }

    func remove(_ account: String) {
        SecItemDelete(baseQuery(account) as CFDictionary)
    }

    private func baseQuery(_ account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}

// Used in tests so persistence stays in-process and never touches the real Keychain.
final class InMemoryCredentialStore: CredentialStore {
    private var entries: [String: String] = [:]

    func get(_ account: String) -> String? { entries[account] }
    func set(_ account: String, _ value: String) { entries[account] = value }
    func remove(_ account: String) { entries.removeValue(forKey: account) }
}
