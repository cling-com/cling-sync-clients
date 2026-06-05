import Foundation

// A file offered by a source (the photo library today, arbitrary folders later),
// as a value the state can hold and compare. The heavy upload descriptors
// (PHAsset/PHAssetResource/local URL) are resolved by the gateway from `id` at
// upload time, so the state stays a plain value type.
struct SourceFile: Equatable, Identifiable {
    let id: String
    let name: String
    let size: Int64
    let modificationDate: Date
}

// Progress shown in the top bar while an upload runs.
struct UploadInfo: Equatable {
    var currentFile: String?
    var currentIndex: Int = 0
    var totalFiles: Int = 0
}

// Scan progress: how many files have been checked against the repository.
struct ScanProgress: Equatable {
    var processed: Int
    var total: Int
}

// A file can be (de)selected only in a not-yet-uploaded state. Used by both the
// row (whether a tap toggles it) and Select All, so they stay consistent. A file
// with no status yet (nil) is unscanned and therefore selectable.
func isSelectable(_ status: FileStatus?) -> Bool {
    guard let status else { return true }
    switch status {
    case .none, .new, .failed, .aborted:
        return true
    default:
        return false
    }
}
