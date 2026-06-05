import CryptoKit
import ImageIO
import UIKit

// Backs the file list with an arbitrary user-picked folder, resolved from a
// security-scoped bookmark. Files are identified by their path relative to the
// folder root (a stable id), uploaded by their real local path. Like
// PhotoLibrarySource, the heavy work runs off the main actor, so the id->URL map
// is lock-guarded.
final class FolderSource: SourceGateway {
    private let bookmark: Data
    private let lock = NSLock()
    private var root: URL?
    private var urls: [String: URL] = [:]

    init(bookmark: Data) {
        self.bookmark = bookmark
    }

    deinit {
        root?.stopAccessingSecurityScopedResource()
    }

    func loadFiles() async -> [SourceFile] {
        guard let root = resolveRoot() else {
            setURLs([:])
            return []
        }
        let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
            setURLs([:])
            return []
        }
        var files: [SourceFile] = []
        var found: [String: URL] = [:]
        let prefix = root.path.hasSuffix("/") ? root.path : root.path + "/"
        for case let url as URL in enumerator {
            let values = try? url.resourceValues(forKeys: Set(keys))
            guard values?.isRegularFile == true else { continue }
            let id = url.path.hasPrefix(prefix) ? String(url.path.dropFirst(prefix.count)) : url.lastPathComponent
            files.append(
                SourceFile(
                    id: id,
                    name: url.lastPathComponent,
                    size: Int64(values?.fileSize ?? 0),
                    modificationDate: values?.contentModificationDate ?? .distantPast))
            found[id] = url
        }
        setURLs(found)
        return files.sorted { $0.modificationDate > $1.modificationDate }
    }

    func sha256(for file: SourceFile) async throws -> String {
        let cache = SHA256Cache.shared
        if let cached = cache.lookup(id: file.id, size: file.size, modificationDate: file.modificationDate) {
            return cached
        }
        guard let url = url(for: file.id) else { throw SourceFileUnavailable() }
        let hash = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        cache.store(id: file.id, size: file.size, modificationDate: file.modificationDate, sha256: hash)
        return hash
    }

    func thumbnail(for file: SourceFile) async -> UIImage? {
        guard let url = url(for: file.id),
            let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 240,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: image)
    }

    func withLocalCopy<T>(of file: SourceFile, _ body: (URL) async throws -> T) async throws -> T {
        guard let url = url(for: file.id) else { throw SourceFileUnavailable() }
        return try await body(url)
    }

    private func resolveRoot() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        if let root { return root }
        var stale = false
        guard let resolved = try? URL(resolvingBookmarkData: bookmark, bookmarkDataIsStale: &stale) else {
            return nil
        }
        _ = resolved.startAccessingSecurityScopedResource()
        root = resolved
        return resolved
    }

    private func url(for id: String) -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return urls[id]
    }

    private func setURLs(_ new: [String: URL]) {
        lock.lock()
        defer { lock.unlock() }
        urls = new
    }
}
