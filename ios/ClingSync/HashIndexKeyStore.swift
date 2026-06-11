import Foundation
import Security

// Provides a stable, per-install 32-byte secret the Go bridge uses to encrypt the
// repository hash index at rest. Stored in the Keychain with
// kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly and NO access-control flags, so a
// background task can read it without a prompt, while a ThisDeviceOnly item is never
// captured by iCloud/iTunes backups. A copy of the cache file off-device is useless
// without this key.
enum HashIndexKeyStore {
    private static let service = (Bundle.main.bundleIdentifier ?? "com.cling.ClingSync") + ".hashIndexKey"
    private static let account = "hashIndex"
    private static let keySize = 32

    // Returns the secret, creating it on first use. Returns nil only when the Keychain
    // is unavailable, in which case the bridge writes the index in the clear.
    static func getOrCreate() -> Data? {
        if let existing = load() { return existing }
        guard let key = randomKey() else { return nil }
        // On a concurrent create the add is a duplicate; re-read the stored one.
        return store(key) ? key : load()
    }

    private static func load() -> Data? {
        var query = baseQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
            let data = result as? Data, data.count == keySize
        else {
            return nil
        }
        return data
    }

    private static func store(_ key: Data) -> Bool {
        var attributes = baseQuery()
        attributes[kSecValueData as String] = key
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        return SecItemAdd(attributes as CFDictionary, nil) == errSecSuccess
    }

    private static func randomKey() -> Data? {
        var bytes = [UInt8](repeating: 0, count: keySize)
        guard SecRandomCopyBytes(kSecRandomDefault, keySize, &bytes) == errSecSuccess else { return nil }
        return Data(bytes)
    }

    private static func baseQuery() -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecUseDataProtectionKeychain as String: true,
        ]
    }
}
