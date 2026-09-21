import Foundation

// In-memory passphrase of the currently open repository, mirroring the
// "session" storage mode. It lets the browse screen open its own repository
// session right after connecting, even when the user declined to store the
// passphrase in the keychain. It lives exactly as long as the open
// repository: every successful connect sets it, every close clears it.
enum SessionPassphrase {
    private static let lock = NSLock()
    private static var entry: (repositoryID: String, passphrase: String)?

    static func set(repositoryID: String, passphrase: String) {
        lock.lock()
        defer { lock.unlock() }
        entry = (repositoryID, passphrase)
    }

    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        entry = nil
    }

    static func get(repositoryID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry, entry.repositoryID == repositoryID else { return nil }
        return entry.passphrase
    }
}
