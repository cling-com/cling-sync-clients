import Foundation

// Pure transition table for user intents and internal completions. Returns the
// next state plus the side effects the store should perform. No IO, no Photos,
// no bridge, no clock: every rule is one assertable function.
enum MainReducer {
    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func reduce(_ state: AppState, _ event: MainEvent) -> Reduction {
        switch event {
        case .fileSelectionChanged(let id, let selected):
            var next = state
            if selected {
                next.selectedIds.insert(id)
            } else {
                next.selectedIds.remove(id)
            }
            return .only(next)

        case .selectAllClicked:
            var next = state
            next.selectedIds = state.selectAllTargets
            return .only(next)

        case .deselectAllClicked:
            var next = state
            next.selectedIds = []
            return .only(next)

        case .searchQueryChanged(let query):
            var next = state
            next.searchQuery = query
            next.selectedIds = []
            return .only(next)

        case .searchToggled:
            let opening = !state.showSearch
            var next = state
            next.showSearch = opening
            next.searchQuery = opening ? state.searchQuery : ""
            next.selectedIds = opening ? [] : state.selectedIds
            return .only(next)

        case .searchCleared:
            var next = state
            next.searchQuery = ""
            return .only(next)

        case .refreshClicked:
            return Reduction(state: state, effects: [.loadFiles])

        case .uploadClicked:
            return upload(state)

        case .abortClicked:
            var next = state
            next.isUploadInitiated = false
            return Reduction(state: next, effects: [.cancelUpload])

        case .loadingStarted:
            var next = state
            next.isLoadingFiles = true
            return .only(next)

        case .filesLoaded(let files):
            var next = state
            next.isLoadingFiles = false
            next.files = files
            return .only(next)

        case .scanStarted(let ids):
            var next = state
            next.isScanning = true
            next.scanProgress = ScanProgress(processed: 0, total: ids.count)
            for id in ids {
                next.fileStatus[id] = .checking
            }
            return .only(next)

        case .scanProgress(let processed, let total, let statuses):
            var next = state
            next.fileStatus.merge(statuses) { _, new in new }
            next.scanProgress = ScanProgress(processed: processed, total: total)
            return .only(next)

        case .scanCompleted(let statuses):
            var next = state
            next.fileStatus.merge(statuses) { _, new in new }
            next.scanProgress = nil
            next.isScanning = false
            return .only(next)

        case .scanFailed(let message, let ids):
            return scanFailed(state, message: message, ids: ids)

        case .settingsClicked:
            var next = state
            next.showSettings = true
            return .only(next)

        case .settingsDismissed:
            var next = state
            next.showSettings = false
            return .only(next)

        case .settingsSaved(let configuration):
            return settingsSaved(state, configuration: configuration)

        case .connectClicked:
            return Reduction(state: state, effects: [.connect])

        case .connectStarted:
            var next = state
            next.isConnecting = true
            return .only(next)

        case .connectSucceeded:
            var next = state
            next.isConnecting = false
            next.isConnected = true
            next.phase = .ready
            return .only(next)

        case .connectFailed(let message):
            var next = state
            next.isConnecting = false
            next.isConnected = false
            next.phase = .connectionFailed(message)
            return .only(next)

        case .errorDismissed:
            var next = state
            next.overlay = .none
            return .only(next)
        }
    }

    private static func upload(_ state: AppState) -> Reduction {
        let ids = state.selectedFiles.map(\.id)
        if ids.isEmpty {
            return .only(state)
        }
        var next = state
        next.isUploadInitiated = true
        next.scanProgress = nil
        next.uploadInfo = UploadInfo(currentFile: nil, currentIndex: 0, totalFiles: ids.count)
        next.currentUploadIds = Set(ids)
        for id in ids {
            next.fileStatus[id] = .waiting
        }
        next.selectedIds = []
        return Reduction(state: next, effects: [.enqueueUpload(ids: ids, author: state.configuration.author)])
    }

    private static func scanFailed(_ state: AppState, message: String, ids: [String]) -> Reduction {
        var next = state
        for id in ids where state.fileStatus[id] == .checking {
            next.fileStatus[id] = .new
        }
        next.scanProgress = nil
        next.isScanning = false
        if state.overlay == .none {
            next.overlay = .error(
                title: "File Scanning Error",
                message: "Some files could not be scanned: \(message)")
        }
        return .only(next)
    }

    private static func settingsSaved(_ state: AppState, configuration: RepositoryConfiguration) -> Reduction {
        if let urlError = validateHostURL(configuration.hostURL) {
            var next = state
            next.overlay = .error(title: "Invalid Host URL", message: urlError)
            return .only(next)
        }
        let oldId = state.configuration.repositoryID
        let repositoryChanged = oldId != configuration.repositoryID
        var base = state
        base.configuration = configuration
        base.showSettings = false
        // First-run: only a successful connect sets `.ready` otherwise, so saving
        // valid settings from the Welcome screen must move on by itself.
        if configuration.isConfigured, base.phase == .needsSettings {
            base.phase = .ready
        }
        let persist = Effect.persistSettings(configuration)
        if repositoryChanged {
            base.fileStatus = [:]
            base.isConnected = false
            base.selectedIds = []
            return Reduction(
                state: base,
                effects: [persist, .invalidateRepository(repositoryID: oldId), .loadFiles])
        }
        return Reduction(state: base, effects: [persist])
    }
}
