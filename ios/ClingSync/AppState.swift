import Foundation

// The top-level screen the app shows. Driven by the launch + connect
// orchestration in the store, separate from the in-list `isConnected` flag (the
// repository access banner). On iOS a failed connect lands here as a full screen
// (`.connectionFailed`), unlike scan/upload failures which surface as an overlay.
enum AppPhase: Equatable {
    case initializing
    case needsSettings
    case connectingToServer
    case connectionFailed(String)
    case ready
}

// The entire screen state as one immutable value. Per-file status and selection
// are keyed by the file's stable id (not the value type) so the whole state is
// `Equatable` and reducer tests can assert against it directly.
struct AppState: Equatable {
    var configuration: RepositoryConfiguration
    var phase: AppPhase = .initializing
    var isLoadingFiles: Bool = false
    var files: [SourceFile] = []
    var fileStatus: [String: FileStatus] = [:]
    var selectedIds: Set<String> = []
    var searchQuery: String = ""
    var showSearch: Bool = false
    var isConnecting: Bool = false
    var isConnected: Bool = false
    var isScanning: Bool = false
    var scanProgress: ScanProgress?
    var isUploading: Bool = false
    var isUploadInitiated: Bool = false
    var currentUploadId: UUID?
    var currentUploadIds: Set<String> = []
    var uploadInfo: UploadInfo?
    var uploadedBytes: Int64 = 0
    var showSettings: Bool = false
    var overlay: Overlay = .none

    // True while an upload is initiated or running; the toolbar and the
    // refresh/settings/search controls are disabled in this state.
    var isBusy: Bool { isUploading || isUploadInitiated }

    // The list after applying the search filter (matched by file name).
    var displayedFiles: [SourceFile] {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if query.isEmpty {
            return files
        }
        return files.filter { $0.name.lowercased().contains(query) }
    }

    // The ids "Select All" would select: visible and still uploadable.
    var selectAllTargets: Set<String> {
        Set(displayedFiles.map(\.id).filter { isSelectable(fileStatus[$0]) })
    }

    // The currently-selected files among those visible.
    var selectedFiles: [SourceFile] {
        displayedFiles.filter { selectedIds.contains($0.id) }
    }

    static func initial(configuration: RepositoryConfiguration) -> AppState {
        AppState(configuration: configuration, showSettings: !configuration.isConfigured)
    }
}
