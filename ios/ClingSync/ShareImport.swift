import Foundation

// Stages files handed to the app through the share/open flow into a private copy
// under caches, so they survive the originating app's sandbox and can be uploaded.
// Each file is copied into its own subdirectory to keep equal names distinct and
// so a finished share's files can be removed without touching another share's.
enum ShareImport {
    static func stagingDirectory() -> URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("SharedUploads", isDirectory: true)
    }

    // Copies `url` into its own staging subdirectory, returning the staged file's
    // value model and local URL, or nil when the file can't be read.
    static func stage(_ url: URL) -> (file: SourceFile, url: URL)? {
        let manager = FileManager.default
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }

        let sourceModificationDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate

        let directory = stagingDirectory().appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = directory.appendingPathComponent(url.lastPathComponent)
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try manager.copyItem(at: url, to: destination)
        } catch {
            return nil
        }
        // Preserve the original modification time so the repository records it (and a
        // re-share dedups), not the copy time.
        if let sourceModificationDate {
            try? manager.setAttributes([.modificationDate: sourceModificationDate], ofItemAtPath: destination.path)
        }
        // The OS drops its own copy of each shared file in the document Inbox; it is
        // ours and now copied, so remove it rather than letting the Inbox accumulate.
        if url.path.hasPrefix(inboxDirectory().path) {
            try? manager.removeItem(at: url)
        }
        let attributes = try? manager.attributesOfItem(atPath: destination.path)
        let size = (attributes?[.size] as? NSNumber)?.int64Value ?? 0
        let modificationDate = attributes?[.modificationDate] as? Date ?? .distantPast
        let file = SourceFile(
            id: destination.path, name: destination.lastPathComponent, size: size, modificationDate: modificationDate)
        return (file, destination)
    }

    // Removes a finished share's staged copies (each lives in its own subdirectory).
    static func remove(_ staged: [(file: SourceFile, url: URL)]) {
        let manager = FileManager.default
        for entry in staged {
            try? manager.removeItem(at: entry.url.deletingLastPathComponent())
        }
    }

    private static func inboxDirectory() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Inbox", isDirectory: true)
    }
}
