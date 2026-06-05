import Foundation

// Persists computed SHA-256 hashes keyed by file id, invalidated when a file's
// size or modification date changes, so re-scans don't re-hash unchanged files.
final class SHA256Cache {
    static let shared = SHA256Cache()

    private struct Entry: Codable {
        let size: Int64
        let modificationDate: Date
        let sha256: String
    }

    private var entries: [String: Entry]
    private let fileURL: URL
    // The cache is read/written from concurrent scan/upload tasks off the main
    // actor, so every access to `entries` is serialized.
    private let lock = NSLock()

    private init() {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        fileURL = cacheDir.appendingPathComponent("sha256cache.json")
        if let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        {
            entries = decoded
        } else {
            entries = [:]
        }
    }

    func lookup(id: String, size: Int64, modificationDate: Date) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let entry = entries[id] else { return nil }
        guard entry.size == size, entry.modificationDate == modificationDate else {
            entries.removeValue(forKey: id)
            return nil
        }
        return entry.sha256
    }

    func store(id: String, size: Int64, modificationDate: Date, sha256: String) {
        lock.lock()
        defer { lock.unlock() }
        entries[id] = Entry(size: size, modificationDate: modificationDate, sha256: sha256)
    }

    func save() {
        lock.lock()
        let snapshot = entries
        lock.unlock()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
