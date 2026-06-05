import CryptoKit
import Photos
import UIKit

struct SourceFileUnavailable: Error {}

// A source of files to back up: the photo library today, arbitrary folders later.
// Produces value-type SourceFiles for the state and keeps the heavy PHAsset/URL
// descriptors here, so the state stays a plain value and content hashing (for the
// repository scan), thumbnails, and upload all resolve through the gateway.
protocol SourceGateway {
    func loadFiles() async -> [SourceFile]
    func sha256(for file: SourceFile) async throws -> String
    func thumbnail(for file: SourceFile) async -> UIImage?
    // Provides a local file URL for the file's contents (writing a temp copy for
    // photo-library assets) for the duration of `body`, then cleans it up.
    func withLocalCopy<T>(of file: SourceFile, _ body: (URL) async throws -> T) async throws -> T
}

final class PhotoLibrarySource: SourceGateway {
    private enum Descriptor {
        case asset(PHAsset, PHAssetResource)
        case local(URL)
    }

    private let isUITestMode: Bool
    // Reads happen from concurrent scan/upload/thumbnail tasks off the main actor
    // while `loadFiles` reassigns the map, so descriptor access is serialized. The
    // lock only guards the dictionary; the heavy work runs on a snapshot outside it.
    private let lock = NSLock()
    private var descriptors: [String: Descriptor] = [:]

    init(isUITestMode: Bool = ProcessInfo.processInfo.arguments.contains("--ui-test-mode")) {
        self.isUITestMode = isUITestMode
    }

    private func descriptor(for id: String) -> Descriptor? {
        lock.lock()
        defer { lock.unlock() }
        return descriptors[id]
    }

    private func setDescriptors(_ new: [String: Descriptor]) {
        lock.lock()
        defer { lock.unlock() }
        descriptors = new
    }

    func loadFiles() async -> [SourceFile] {
        if isUITestMode {
            let loaded = Self.fixtures()
            setDescriptors(loaded.descriptors)
            return loaded.files
        }
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            setDescriptors([:])
            return []
        }
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(with: options)
        let loaded = await Task.detached(priority: .userInitiated) { Self.assets(from: assets) }.value
        setDescriptors(loaded.descriptors)
        return loaded.files
    }

    func sha256(for file: SourceFile) async throws -> String {
        let cache = SHA256Cache.shared
        if let cached = cache.lookup(id: file.id, size: file.size, modificationDate: file.modificationDate) {
            return cached
        }
        guard let descriptor = descriptor(for: file.id) else { throw SourceFileUnavailable() }
        let hash: String
        switch descriptor {
        case .local(let url):
            hash = Self.hex(SHA256.hash(data: try Data(contentsOf: url)))
        case .asset(_, let resource):
            hash = try await Self.hash(resource)
        }
        cache.store(id: file.id, size: file.size, modificationDate: file.modificationDate, sha256: hash)
        return hash
    }

    func thumbnail(for file: SourceFile) async -> UIImage? {
        guard case .asset(let asset, _) = descriptor(for: file.id) else { return nil }
        return await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.resizeMode = .fast
            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 120, height: 120),
                contentMode: .aspectFill,
                options: options
            ) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    func withLocalCopy<T>(of file: SourceFile, _ body: (URL) async throws -> T) async throws -> T {
        guard let descriptor = descriptor(for: file.id) else { throw SourceFileUnavailable() }
        switch descriptor {
        case .local(let url):
            return try await body(url)
        case .asset(_, let resource):
            let directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("upload-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: directory) }
            let tempURL = directory.appendingPathComponent(file.name)
            try await Self.write(resource, to: tempURL)
            return try await body(tempURL)
        }
    }

    private static func write(_ resource: PHAssetResource, to url: URL) async throws {
        let options = PHAssetResourceRequestOptions()
        options.isNetworkAccessAllowed = true
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHAssetResourceManager.default().writeData(for: resource, toFile: url, options: options) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    private static func assets(from assets: PHFetchResult<PHAsset>) -> (
        files: [SourceFile], descriptors: [String: Descriptor]
    ) {
        var files: [SourceFile] = []
        var descriptors: [String: Descriptor] = [:]
        assets.enumerateObjects { asset, _, _ in
            guard let resource = primaryResource(for: asset) else { return }
            let id = asset.localIdentifier + ":" + resource.originalFilename
            files.append(
                SourceFile(
                    id: id,
                    name: resource.originalFilename,
                    size: fileSize(for: resource),
                    modificationDate: asset.modificationDate ?? asset.creationDate ?? .distantPast))
            descriptors[id] = .asset(asset, resource)
        }
        return (files, descriptors)
    }

    private static func fixtures() -> (files: [SourceFile], descriptors: [String: Descriptor]) {
        var files: [SourceFile] = []
        var descriptors: [String: Descriptor] = [:]
        for fixture in loadUITestFiles() {
            files.append(fixture.file)
            descriptors[fixture.file.id] = .local(fixture.url)
        }
        return (files, descriptors)
    }

    private static func hash(_ resource: PHAssetResource) async throws -> String {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            var hasher = SHA256()
            PHAssetResourceManager.default().requestData(for: resource, options: options) { data in
                hasher.update(data: data)
            } completionHandler: { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: hex(hasher.finalize()))
                }
            }
        }
    }

    private static func hex(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
