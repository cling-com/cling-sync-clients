import CryptoKit
import ImageIO
import UIKit

// Backs the share screen with the files the user handed to the app through the
// system share/open flow, each already staged as a local copy under caches. The
// set is fixed at construction (unlike the photo-library/folder sources, which
// reload), so the id->URL map is immutable and needs no lock.
final class SharedFilesSource: SourceGateway {
    private let files: [SourceFile]
    private let urls: [String: URL]

    init(staged: [(file: SourceFile, url: URL)]) {
        self.files = staged.map(\.file)
        self.urls = Dictionary(uniqueKeysWithValues: staged.map { ($0.file.id, $0.url) })
    }

    func loadFiles() async -> [SourceFile] {
        files
    }

    func sha256(for file: SourceFile) async throws -> String {
        let cache = SHA256Cache.shared
        if let cached = cache.lookup(id: file.id, size: file.size, modificationDate: file.modificationDate) {
            return cached
        }
        guard let url = urls[file.id] else { throw SourceFileUnavailable() }
        let hash = SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
        cache.store(id: file.id, size: file.size, modificationDate: file.modificationDate, sha256: hash)
        return hash
    }

    func thumbnail(for file: SourceFile) async -> UIImage? {
        guard let url = urls[file.id],
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
        guard let url = urls[file.id] else { throw SourceFileUnavailable() }
        return try await body(url)
    }
}
