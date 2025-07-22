import CommonCrypto
import Foundation
import Photos

class FileChecker {
    private static let maxBatchSize = 100
    private static let batchTimeLimit: TimeInterval = 1.0

    private let bridge = Bridge.self
    private let files: [File]
    private var fileStatusUpdate: ([String: String]) -> Void
    private var progressUpdate: (Int, Int) -> Void

    private var isCancelled = false

    init(
        files: [File],
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

        while fileIndex < files.count && !isCancelled {
            var batchFiles: [File] = []
            var batchSha256s: [String] = []
            let batchStartTime = Date()

            while fileIndex < files.count && batchFiles.count < Self.maxBatchSize
                && (batchFiles.isEmpty || Date().timeIntervalSince(batchStartTime) < Self.batchTimeLimit)
            {

                let file = files[fileIndex]
                fileIndex += 1

                do {
                    let sha256 = try await calculateSHA256(for: file.asset)
                    batchFiles.append(file)
                    batchSha256s.append(sha256)
                } catch {
                    print("Error calculating SHA256 for \(file.name): \(error)")
                    batchFiles.append(file)
                    batchSha256s.append("")
                }

                if isCancelled {
                    break
                }
            }

            if !batchSha256s.isEmpty {
                var fileStatuses: [String: String] = [:]

                do {
                    let results = try bridge.checkFiles(sha256s: batchSha256s)

                    for (index, file) in batchFiles.enumerated() {
                        let repoPath = index < results.count ? results[index] : ""
                        fileStatuses[file.name] = repoPath
                    }
                } catch {
                    print("Error checking files: \(error)")
                    for file in batchFiles {
                        fileStatuses[file.name] = ""
                    }
                }

                processedCount += batchFiles.count
                fileStatusUpdate(fileStatuses)
                progressUpdate(processedCount, totalFiles)
            }
        }
    }

    private func calculateSHA256(for asset: PHAsset) async throws -> String {
        return try await withCheckedThrowingContinuation { continuation in
            let options = PHImageRequestOptions()
            options.isNetworkAccessAllowed = true
            options.deliveryMode = .highQualityFormat
            options.isSynchronous = false

            PHImageManager.default().requestImageDataAndOrientation(
                for: asset,
                options: options
            ) { data, _, _, info in
                if let error = info?[PHImageErrorKey] as? Error {
                    continuation.resume(throwing: error)
                    return
                }

                guard let data = data else {
                    continuation.resume(throwing: FileCheckerError.noImageData)
                    return
                }

                let sha256 = self.calculateSHA256(data: data)
                continuation.resume(returning: sha256)
            }
        }
    }

    private func calculateSHA256(data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))

        data.withUnsafeBytes { bytes in
            _ = CC_SHA256(bytes.baseAddress, CC_LONG(data.count), &hash)
        }

        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

enum FileCheckerError: Error {
    case noImageData
}
