import Foundation

struct UploadProgressIoError: Error {
    let message: String
}

// Typed read/write of the upload mechanism's status/result JSON (keyed by the
// file's stable id). The coordinator writes [UploadStatus]; the store reads
// [FileStatus] with either in-progress or terminal semantics. One schema, two
// readers, so a still-running upload and a finished one map differently.
enum UploadProgressIo {
    static func write(_ statuses: [String: UploadStatus], to url: URL) throws {
        let wire = statuses.mapValues(\.wire)
        let data = try JSONSerialization.data(withJSONObject: wire)
        try data.write(to: url)
    }

    // In-progress semantics: how a still-running upload's statuses map to the list.
    static func readProgress(from url: URL) throws -> [String: FileStatus] {
        try read(from: url) { status in
            switch status {
            case .waiting: return .waiting
            case .uploading: return .sending
            case .uploaded: return .sentWaitingCommit
            case .skipped: return .exists(repoPath: "")
            case .committing: return .committing
            case nil: return .new
            }
        }
    }

    // Terminal semantics: how the final result maps to the list. Entries with no
    // terminal meaning are dropped so they don't overwrite existing state.
    static func readResult(from url: URL) throws -> [String: FileStatus] {
        try read(from: url) { status in
            switch status {
            case .uploaded, .committing: return .done
            case .skipped: return .exists(repoPath: "")
            default: return nil
            }
        }
    }

    private static func read(
        from url: URL,
        _ map: (UploadStatus?) -> FileStatus?
    ) throws -> [String: FileStatus] {
        let data = try Data(contentsOf: url)
        guard let wire = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw UploadProgressIoError(message: "Upload progress file is not a string map.")
        }
        var result: [String: FileStatus] = [:]
        for (id, value) in wire {
            if let status = map(UploadStatus.fromWire(value)) {
                result[id] = status
            }
        }
        return result
    }
}
