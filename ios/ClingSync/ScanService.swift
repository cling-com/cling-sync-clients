import Foundation

// Scans source files against the repository: hashes each (via the source gateway)
// and asks the bridge whether the content is already present, in batches, honoring
// Task cancellation. CheckFiles is now the sole, definitive membership test, so
// there is no local index: a file is `.exists` if present, else `.new`.
struct ScanService {
    private static let maxBatchSize = 100
    private static let batchTimeLimit: TimeInterval = 1.0

    let source: SourceGateway

    // Calls `onBatch` after each batch with the cumulative processed count and that
    // batch's statuses. Throws if the bridge check fails or the task is cancelled.
    func scan(_ files: [SourceFile], onBatch: (Int, [String: FileStatus]) async -> Void) async throws {
        // Persist computed hashes even if the scan is cancelled or throws partway.
        defer { SHA256Cache.shared.save() }
        var index = 0
        var processed = 0
        while index < files.count {
            try Task.checkCancellation()
            let batch = await nextBatch(files, from: &index)
            processed += batch.count
            if batch.isEmpty { continue }

            var statuses: [String: FileStatus] = [:]
            let hashed = batch.compactMap { item in item.sha.map { (id: item.file.id, sha: $0) } }
            for item in batch where item.sha == nil {
                statuses[item.file.id] = .new
            }
            if !hashed.isEmpty {
                let present = try Bridge.checkFiles(sha256s: hashed.map(\.sha))
                for (offset, item) in hashed.enumerated() {
                    statuses[item.id] = (offset < present.count && present[offset]) ? .exists(repoPath: "") : .new
                }
            }
            await onBatch(processed, statuses)
        }
    }

    private func nextBatch(
        _ files: [SourceFile],
        from index: inout Int
    ) async -> [(file: SourceFile, sha: String?)] {
        var batch: [(file: SourceFile, sha: String?)] = []
        let start = Date()
        while index < files.count,
            batch.count < Self.maxBatchSize,
            batch.isEmpty || Date().timeIntervalSince(start) < Self.batchTimeLimit,
            !Task.isCancelled
        {
            let file = files[index]
            index += 1
            batch.append((file, try? await source.sha256(for: file)))
        }
        return batch
    }
}
