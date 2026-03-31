import CryptoKit
import Foundation
import Photos

final class SHA256Cache {
    static let shared = SHA256Cache()

    private struct Entry: Codable {
        let size: Int64
        let modificationDate: Date
        let sha256: String
    }

    private var entries: [String: Entry]
    private let fileURL: URL

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
        guard let entry = entries[id] else { return nil }
        guard entry.size == size, entry.modificationDate == modificationDate else {
            entries.removeValue(forKey: id)
            return nil
        }
        return entry.sha256
    }

    func store(id: String, size: Int64, modificationDate: Date, sha256: String) {
        entries[id] = Entry(size: size, modificationDate: modificationDate, sha256: sha256)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}

final class FileChecker {
    private static let maxBatchSize = 100
    private static let batchTimeLimit: TimeInterval = 1.0

    private let files: [MediaFile]
    private let fileStatusUpdate: ([String: String]) -> Void
    private let progressUpdate: (Int, Int) -> Void

    private var isCancelled = false

    init(
        files: [MediaFile],
        fileStatusUpdate: @escaping ([String: String]) -> Void,
        progressUpdate: @escaping (Int, Int) -> Void
    ) {
        self.files = files
        self.fileStatusUpdate = fileStatusUpdate
        self.progressUpdate = progressUpdate
    }

    func cancel() {
        isCancelled = true
    }

    func checkFiles() async throws {
        var processedCount = 0
        var fileIndex = 0
        let totalFiles = files.count

        progressUpdate(0, totalFiles)
        while fileIndex < totalFiles && !isCancelled {
            let batch = try await nextBatch(startingAt: &fileIndex)
            if batch.isEmpty {
                continue
            }

            var fileStatuses: [String: String] = [:]
            do {
                let results = try Bridge.checkFiles(sha256s: batch.map { $0.sha256 })
                for (index, file) in batch.enumerated() {
                    fileStatuses[file.file.id] = index < results.count ? results[index] : ""
                }
            } catch {
                for file in batch {
                    fileStatuses[file.file.id] = ""
                }
            }

            processedCount += batch.count
            fileStatusUpdate(fileStatuses)
            progressUpdate(processedCount, totalFiles)
        }
        SHA256Cache.shared.save()
    }

    private func nextBatch(startingAt fileIndex: inout Int) async throws -> [(file: MediaFile, sha256: String)] {
        var batch: [(file: MediaFile, sha256: String)] = []
        let batchStartTime = Date()

        while fileIndex < files.count,
            batch.count < Self.maxBatchSize,
            batch.isEmpty || Date().timeIntervalSince(batchStartTime) < Self.batchTimeLimit,
            !isCancelled
        {
            let file = files[fileIndex]
            fileIndex += 1
            do {
                batch.append((file, try await calculateSHA256(for: file)))
            } catch {
                batch.append((file, ""))
            }
        }
        return batch
    }

    private func calculateSHA256(for file: MediaFile) async throws -> String {
        let cache = SHA256Cache.shared
        if let cached = cache.lookup(id: file.id, size: file.size, modificationDate: file.modificationDate) {
            return cached
        }
        let hash: String
        if let localFileURL = file.localFileURL {
            let data = try Data(contentsOf: localFileURL)
            hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        } else {
            guard let resource = file.resource else {
                throw CocoaError(.fileReadUnknown)
            }
            hash = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
                let options = PHAssetResourceRequestOptions()
                options.isNetworkAccessAllowed = true

                var hasher = SHA256()
                PHAssetResourceManager.default().requestData(for: resource, options: options) { data in
                    hasher.update(data: data)
                } completionHandler: { error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    let digest = hasher.finalize()
                    continuation.resume(returning: digest.map { String(format: "%02x", $0) }.joined())
                }
            }
        }
        cache.store(id: file.id, size: file.size, modificationDate: file.modificationDate, sha256: hash)
        return hash
    }
}
