import Foundation

// A normalized upload signal. The store produces it from the upload mechanism's
// persisted progress/result, so the reducer never sees the transport types and
// never touches the filesystem.
enum WorkUpdate {
    case enqueued(id: UUID)
    case running(statuses: [String: FileStatus], uploadedBytes: Int64)
    case succeeded(finalStatuses: [String: FileStatus])
    case failed(error: String)
    case cancelled
}
