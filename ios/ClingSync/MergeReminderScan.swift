import Foundation

// Decides whether the source files contain anything worth a backup reminder.
// "Backed up" is answered by the bridge's checkFiles, which reads the persisted
// repository hash index, so this works without an open repository or passphrase.
struct MergeReminderScan {
    let source: SourceGateway

    // Daily: a file needs backing up unless its cached hash is already in the
    // repository. Files never hashed count as new. Reads no file content.
    func countUnsynced(_ files: [SourceFile]) throws -> Int {
        var cachedShas: [String] = []
        var unhashed = 0
        for file in files {
            if let sha = SHA256Cache.shared.peek(id: file.id) {
                cachedShas.append(sha)
            } else {
                unhashed += 1
            }
        }
        return try unhashed + countMissing(cachedShas)
    }

    // Weekly: hash every file (reusing the cache when size/mtime are unchanged) and
    // count those whose current content is not in the repository. A file that cannot
    // be hashed (e.g. an iCloud asset with no network in the background) is treated
    // as unsynced, erring toward nudging.
    func countUnsyncedOrChanged(_ files: [SourceFile]) async throws -> Int {
        var shas: [String] = []
        var unhashable = 0
        for file in files {
            if let sha = try? await source.sha256(for: file) {
                shas.append(sha)
            } else {
                unhashable += 1
            }
        }
        return try unhashable + countMissing(shas)
    }

    private func countMissing(_ sha256s: [String]) throws -> Int {
        if sha256s.isEmpty {
            return 0
        }
        return try Bridge.checkFiles(sha256s: sha256s).filter { !$0 }.count
    }
}
