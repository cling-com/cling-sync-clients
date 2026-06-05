import Foundation

// Which source backs the file list: the photo library, or an arbitrary folder the
// user picked (identified by a security-scoped bookmark that survives relaunch).
enum SourceSelection: Equatable {
    case photoLibrary
    case folder(bookmark: Data)
}
