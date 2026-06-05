import Foundation

// The status vocabulary the upload mechanism writes to its progress/result files.
// Centralised here so the writer (the upload coordinator) and the reader (the
// store) share one schema. The raw value IS the on-disk wire string.
enum UploadStatus: String {
    case waiting
    case uploading
    case uploaded
    case skipped
    case committing

    var wire: String { rawValue }

    static func fromWire(_ wire: String) -> UploadStatus? { UploadStatus(rawValue: wire) }
}
