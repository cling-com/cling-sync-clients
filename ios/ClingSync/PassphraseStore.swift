import Foundation
import LocalAuthentication
import Security

struct PassphraseStoreError: LocalizedError {
    let message: String
    let missingPassphrase: Bool
    let cancelled: Bool

    var errorDescription: String? { message }

    init(message: String, missingPassphrase: Bool = false, cancelled: Bool = false) {
        self.message = message
        self.missingPassphrase = missingPassphrase
        self.cancelled = cancelled
    }
}

final class PassphraseStore {
    static let shared = PassphraseStore()

    private let service = Bundle.main.bundleIdentifier ?? "com.cling.ClingSync"

    private init() {}

    func hasStoredPassphrase(for repositoryID: String, mode: PassphraseStorageMode) -> Bool {
        guard mode.savesInKeychain else { return false }
        var query = baseQuery(for: repositoryID)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        // Prevent the biometric prompt, since we only want to check existence.
        let context = LAContext()
        context.interactionNotAllowed = true
        query[kSecUseAuthenticationContext as String] = context
        let status = SecItemCopyMatching(query as CFDictionary, nil)
        return status == errSecSuccess || status == errSecInteractionNotAllowed
    }

    func save(passphrase: String, for repositoryID: String, mode: PassphraseStorageMode) throws {
        guard mode.savesInKeychain else {
            try deleteKeychainPassphrase(for: repositoryID)
            return
        }

        try deleteKeychainPassphrase(for: repositoryID)

        var attributes = baseQuery(for: repositoryID)
        attributes[kSecValueData as String] = Data(passphrase.utf8)
        attributes[kSecUseDataProtectionKeychain as String] = true

        // Use biometric protection if available, otherwise fall back to device unlock.
        let context = LAContext()
        var biometricError: NSError?
        if context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &biometricError) {
            var cfError: Unmanaged<CFError>?
            guard
                let accessControl = SecAccessControlCreateWithFlags(
                    nil,
                    kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                    .biometryCurrentSet,
                    &cfError
                )
            else {
                throw PassphraseStoreError(
                    message: cfError?.takeRetainedValue().localizedDescription
                        ?? "Failed to enable biometric protection."
                )
            }
            attributes[kSecAttrAccessControl as String] = accessControl
        } else {
            attributes[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        }

        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw PassphraseStoreError(message: "Failed to store passphrase in iPhone Keychain.")
        }
    }

    func load(for repositoryID: String, mode: PassphraseStorageMode, prompt: String) throws -> String {
        guard let passphrase = try loadIfAvailable(for: repositoryID, mode: mode, prompt: prompt) else {
            throw PassphraseStoreError(
                message: "Passphrase not available. Open Settings and enter it again.",
                missingPassphrase: true
            )
        }
        return passphrase
    }

    func loadIfAvailable(for repositoryID: String, mode: PassphraseStorageMode, prompt: String) throws -> String? {
        guard mode.savesInKeychain else {
            return nil
        }

        var query = baseQuery(for: repositoryID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        query[kSecUseDataProtectionKeychain as String] = true
        let context = LAContext()
        context.localizedCancelTitle = "Cancel"
        context.localizedReason = prompt
        query[kSecUseAuthenticationContext as String] = context

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let passphrase = String(data: data, encoding: .utf8) else {
                throw PassphraseStoreError(message: "Failed to read passphrase from iPhone Keychain.")
            }
            return passphrase
        case errSecUserCanceled, errSecAuthFailed:
            throw PassphraseStoreError(message: "Authentication was cancelled.", cancelled: true)
        case errSecItemNotFound:
            return nil
        default:
            throw PassphraseStoreError(message: "Failed to read passphrase from iPhone Keychain.")
        }
    }

    func clear(for repositoryID: String) throws {
        try deleteKeychainPassphrase(for: repositoryID)
    }

    func resetAll() {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        SecItemDelete(query as CFDictionary)
    }

    private func deleteKeychainPassphrase(for repositoryID: String) throws {
        let status = SecItemDelete(baseQuery(for: repositoryID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw PassphraseStoreError(message: "Failed to remove passphrase from iPhone Keychain.")
        }
    }

    private func baseQuery(for repositoryID: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: repositoryID,
        ]
    }
}
