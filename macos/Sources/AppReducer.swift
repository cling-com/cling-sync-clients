import Foundation

// The pure transition table: reduce(state, event) -> (state, effects). No IO, no
// AppKit, no clock (the store threads `now` through events that record time).
// Identical effects are de-duplicated so the persist/reschedule helpers can be
// called freely and tests assert clean effect lists.
enum AppReducer {
    // One exhaustive switch over every event keeps the whole transition table in
    // one readable place rather than fragmenting it across helpers.
    // swiftlint:disable:next cyclomatic_complexity
    static func reduce(_ state: AppState, _ event: AppEvent) -> Reduction {
        var state = state
        var effects: [Effect] = []

        switch event {
        case .stateLoaded(let configs, let tracking, let settings, let now):
            state.syncWorkers = settings.syncWorkers
            state.autoMergeIntervalHours = settings.autoMergeIntervalHours
            state.notifyStaleDays = settings.notifyStaleDays
            state.workspaces = configs.map { config in
                var workspace = WorkspaceState(config: config)
                let path = config.normalizedLocalDirectory
                workspace.lastSuccessfulMerge = tracking.lastSuccessfulMerge[path]
                workspace.firstTracked = tracking.firstTracked[path]
                workspace.lastStaleNotified = tracking.lastStaleNotified[path]
                return workspace
            }
            ensureMergeTracking(&state, &effects, now: now)
            selectInitialWorkspace(&state)
            updateDraftFromSelection(&state)
            for workspace in state.workspaces { effects.append(.loadSyncTargets(id: workspace.id)) }
            effects.append(.rescheduleAutoMerge)
            effects.append(.rescheduleStaleCheck)
            effects.append(.refreshMergeMtimes)
            if state.workspaces.isEmpty { state.preferencesOpen = true }

        case .openPreferencesClicked:
            if state.workspaces.isEmpty {
                let config = WorkspaceConfig()
                state.workspaces.append(WorkspaceState(config: config))
                state.selectedWorkspaceID = config.id
                state.draftConfig = config
                effects.append(.persistWorkspaces)
            } else {
                updateDraftFromSelection(&state)
            }
            state.preferencesOpen = true
            effects.append(.focusPreferences)
            if let id = state.selectedWorkspaceID, state.workspace(id) != nil {
                effects.append(.loadSyncTargets(id: id))
            }

        case .closePreferencesClicked:
            updateDraftFromSelection(&state)
            state.preferencesOpen = false

        case .openLocalFolderClicked(let id):
            guard let workspace = state.workspace(id) else { break }
            effects.append(.openLocalFolder(path: workspace.localPath))

        case .settingsTabSelected(let tab):
            state.selectedSettingsTab = tab

        case .addWorkspaceClicked:
            state.errorMessage = ""
            let config = WorkspaceConfig()
            state.workspaces.append(WorkspaceState(config: config))
            state.selectedWorkspaceID = config.id
            state.draftConfig = config
            state.preferencesOpen = true
            effects.append(.persistWorkspaces)

        case .workspaceSelected(let id):
            state.selectedWorkspaceID = id
            state.selectedSyncTargetName = nil
            updateDraftFromSelection(&state)
            state.errorMessage = ""
            if let id, state.workspace(id) != nil { effects.append(.loadSyncTargets(id: id)) }

        case .removeWorkspaceClicked(let id):
            guard let index = state.index(id) else { break }
            let removed = state.workspaces[index]
            let wasBackoffActive = state.autoMergeBackoffActive
            effects.append(.clearWorkspacePassphrase(uri: removed.config.bridgeRepositoryURI))
            effects.append(.deactivateDirectoryAccess(path: removed.localPath))
            state.openWindows = state.openWindows.filter { $0.workspaceID != id }
            state.workspaces.remove(at: index)
            effects.append(.persistMergeTracking)
            if state.autoMergeBackoffActive != wasBackoffActive { effects.append(.rescheduleAutoMerge) }
            if state.selectedWorkspaceID == id {
                selectInitialWorkspace(&state)
                updateDraftFromSelection(&state)
            }
            state.lastResultMessage = "Folder removed"
            effects.append(.persistWorkspaces)
            if state.workspaces.isEmpty { state.preferencesOpen = true }

        case .draftAccessEdited(let draft, let now):
            state.draftConfig = draft
            if draft.verifiedAccessSignature != draft.accessSignature {
                state.draftConfig.verifiedAccessSignature = ""
            }
            updateDraftInList(&state, &effects, now: now)

        case .draftMetadataEdited(let draft, let now):
            state.draftConfig = draft
            state.draftConfig.verifiedAccessSignature = ""
            updateDraftInList(&state, &effects, now: now)

        case .chooseLocalDirectoryClicked:
            effects.append(.chooseLocalDirectory)

        case .chooseLocalDirectoryCompleted(let draft, let inspectionError, let now):
            state.draftConfig = draft
            state.errorMessage = inspectionError ?? ""
            updateDraftInList(&state, &effects, now: now)

        case .syncTargetSelected(let name):
            state.selectedSyncTargetName = name

        case .testDraftClicked:
            guard state.canTestDraft else { break }
            state.errorMessage = ""
            let config = normalizedDraftConfig(state.draftConfig)
            if let urlError = validateHostURL(config.normalizedHostURL) {
                state.errorMessage = urlError
                break
            }
            state.isTesting = true
            effects.append(.runTestDraft(config))

        case .testDraftSucceeded(let verified, let now):
            var verified = verified
            verified.verifiedAccessSignature = verified.accessSignature
            upsert(&state, &effects, config: verified, now: now)
            state.draftConfig = verified
            state.isTesting = false
            state.lastResultMessage = "Tested \(verified.displayName)"
            effects.append(.loadSyncTargets(id: verified.id))

        case .testDraftCancelled:
            state.isTesting = false

        case .testDraftFailed(let message):
            state.isTesting = false
            state.errorMessage = message

        case .saveDraftClicked(let now):
            state.errorMessage = ""
            let config = normalizedDraftConfig(state.draftConfig)
            if let urlError = validateHostURL(config.normalizedHostURL) {
                state.errorMessage = urlError
                break
            }
            upsert(&state, &effects, config: config, now: now)
            state.lastResultMessage = "Saved \(config.displayName)"
            state.preferencesOpen = false

        case .operationClicked(let id, let kind):
            guard let workspace = state.workspace(id) else { break }
            let operation = workspace.operation(kind)
            let shouldOpen: Bool
            switch kind {
            case .merge: shouldOpen = operation.isRunning || operation.isTerminalFailure
            case .status: shouldOpen = operation.isRunning || operation.isFinished
            case .sync: shouldOpen = operation.isRunning
            }
            if shouldOpen {
                state.openWindows.insert(WindowKey(workspaceID: id, kind: kind))
                effects.append(.focusProgressWindow(id: id, kind: kind))
            } else {
                beginOperation(&state, &effects, id: id, kind: kind, presentWindow: true, isAutoMerge: false)
            }

        case .operationStartRequested(let id, let kind, let presentWindow, let isAutoMerge):
            beginOperation(&state, &effects, id: id, kind: kind, presentWindow: presentWindow, isAutoMerge: isAutoMerge)

        case .operationStartFailed(let id, let kind, let message, let isNetwork, let isAutoMerge):
            guard let index = state.index(id) else { break }
            state.workspaces[index].setOperation(
                kind, .finished(.failed(message: message, detail: "", isNetwork: isNetwork)))
            if isAutoMerge {
                state.workspaces[index].isAutoMerge = false
                setNetworkBackoff(&state, &effects, id: id, active: isNetwork)
                if !isNetwork {
                    effects.append(.postNotification(id: id, title: "Automatic merge failed", body: message))
                }
            } else {
                effects.append(.showAlert(title: kind.failureAlertTitle, message: message))
            }

        case .operationStartCancelled(let id, let kind):
            // Cancelling a passphrase prompt (or a no-sync-targets start) returns the op
            // to idle and closes the optimistically-opened window so it does not linger
            // empty (no alert, no terminal-failed state).
            guard let index = state.index(id) else { break }
            state.workspaces[index].setOperation(kind, .idle)
            state.openWindows.remove(WindowKey(workspaceID: id, kind: kind))

        case .cancelClicked(let id, let kind):
            effects.append(.cancelOperation(id: id, kind: kind))

        case .workUpdated(let id, let kind, let update, let now):
            let reduction = OperationReducer.fold(state, id: id, kind: kind, update: update, now: now)
            state = reduction.state
            effects = reduction.effects

        case .detailsToggled(let id, let kind, let show):
            guard let index = state.index(id) else { break }
            state.workspaces[index].setShowsDetails(kind, show)

        case .openProgressWindowRequested(let id, let kind):
            guard state.workspace(id) != nil else { break }
            state.openWindows.insert(WindowKey(workspaceID: id, kind: kind))
            effects.append(.focusProgressWindow(id: id, kind: kind))

        case .progressWindowClosed(let id, let kind):
            state.openWindows.remove(WindowKey(workspaceID: id, kind: kind))
            guard let index = state.index(id) else { break }
            // Bug C: never reset a RUNNING op (the poller must keep observing it).
            // A finished status/sync resets to idle so the menu item is re-runnable
            // (old close behavior); merge keeps its terminal state (old behavior).
            if kind != .merge, state.workspaces[index].operation(kind).isFinished {
                state.workspaces[index].setOperation(kind, .idle)
            }

        case .syncTargetsLoaded(let id, let targets):
            guard let index = state.index(id) else { break }
            state.workspaces[index].syncTargets = targets

        case .addSyncTargetClicked:
            guard let workspace = state.selectedSavedWorkspace else { break }
            effects.append(.promptAndAddSyncTarget(id: workspace.id))

        case .syncTargetAdded(let id):
            effects.append(.loadSyncTargets(id: id))

        case .removeSyncTargetClicked:
            guard let workspace = state.selectedSavedWorkspace, let name = state.selectedSyncTargetName,
                workspace.syncTargets?.contains(where: { $0.name == name }) == true
            else { break }
            effects.append(.removeSyncTarget(id: workspace.id, name: name))

        case .syncTargetRemoved(let id):
            state.selectedSyncTargetName = nil
            effects.append(.loadSyncTargets(id: id))

        case .syncTargetActionFailed(let title, let message):
            effects.append(.showAlert(title: title, message: message))

        case .syncWorkersChanged(let value):
            state.syncWorkers = value
            effects.append(.persistSetting(.syncWorkers, value))

        case .autoMergeIntervalChanged(let value):
            guard value != state.autoMergeIntervalHours else { break }
            state.autoMergeIntervalHours = value
            for index in state.workspaces.indices { state.workspaces[index].inNetworkBackoff = false }
            effects.append(.persistSetting(.autoMergeIntervalHours, value))
            effects.append(.rescheduleAutoMerge)

        case .notifyStaleDaysChanged(let value):
            guard value != state.notifyStaleDays else { break }
            state.notifyStaleDays = value
            effects.append(.persistSetting(.notifyStaleDays, value))
            effects.append(.rescheduleStaleCheck)

        case .autoMergeTimerFired:
            for workspace in state.workspaces where workspace.config.isComplete && !workspace.isBusy {
                beginOperation(
                    &state, &effects, id: workspace.id, kind: .merge, presentWindow: false, isAutoMerge: true)
            }

        case .staleCheckTimerFired(let now):
            guard state.notifyStaleDays > 0 else { break }
            var notified = false
            for index in state.workspaces.indices {
                let workspace = state.workspaces[index]
                guard workspace.config.isComplete, !workspace.localPath.isEmpty else { continue }
                let reference = workspace.lastSuccessfulMerge ?? workspace.firstTracked ?? now
                guard AutoMergePolicy.isStale(lastSuccessOrStart: reference, days: state.notifyStaleDays, now: now)
                else { continue }
                if let last = workspace.lastStaleNotified, now.timeIntervalSince(last) < AutoMergePolicy.secondsPerDay {
                    continue
                }
                state.workspaces[index].lastStaleNotified = now
                notified = true
                let plural = state.notifyStaleDays == 1 ? "" : "s"
                effects.append(
                    .postNotification(
                        id: workspace.id, title: "Merge overdue",
                        body: "\(workspace.config.displayName) has not merged successfully for "
                            + "\(state.notifyStaleDays) day\(plural) or more."))
            }
            if notified { effects.append(.persistMergeTracking) }

        case .testReminderRequested:
            // Debug affordance: force the reminder for every configured folder,
            // ignoring the staleness threshold + throttle, so the notification path
            // can be exercised on demand. Does not touch tracking.
            let days = max(state.notifyStaleDays, 1)
            let plural = days == 1 ? "" : "s"
            for workspace in state.workspaces where workspace.config.isComplete && !workspace.localPath.isEmpty {
                effects.append(
                    .postNotification(
                        id: workspace.id, title: "Merge overdue",
                        body: "\(workspace.config.displayName) has not merged successfully for "
                            + "\(days) day\(plural) or more."))
            }

        case .mergeMtimesRefreshed(let dates):
            for index in state.workspaces.indices {
                state.workspaces[index].lastMergeMtime = dates[state.workspaces[index].id]
            }

        case .quitClicked:
            effects.append(.quit)
        }

        var unique: [Effect] = []
        for effect in effects where !unique.contains(effect) { unique.append(effect) }
        return Reduction(state: state, effects: unique)
    }

    // MARK: - Shared helpers

    // Optimistic-running transition shared by manual start, the Status window's
    // Merge button, and the auto-merge scheduler. Guards mutual exclusion.
    // swiftlint:disable:next function_parameter_count
    static func beginOperation(
        _ state: inout AppState, _ effects: inout [Effect],
        id: UUID, kind: OperationKind, presentWindow: Bool, isAutoMerge: Bool
    ) {
        guard let index = state.index(id), !state.workspaces[index].isBusy else { return }
        if kind == .merge || kind == .sync { state.lastResultMessage = "" }
        state.workspaces[index].setOperation(kind, .running(message: prepMessage(kind), detail: "", canCancel: true))
        if isAutoMerge { state.workspaces[index].isAutoMerge = true }
        if presentWindow {
            state.openWindows.insert(WindowKey(workspaceID: id, kind: kind))
            effects.append(.focusProgressWindow(id: id, kind: kind))
        }
        effects.append(.startOperation(id: id, kind: kind, isAutoMerge: isAutoMerge))
    }

    static func recordSuccessfulMerge(_ state: inout AppState, _ effects: inout [Effect], id: UUID, now: Date) {
        guard let index = state.index(id) else { return }
        state.workspaces[index].lastSuccessfulMerge = now
        state.workspaces[index].lastStaleNotified = nil
        effects.append(.persistMergeTracking)
        effects.append(.refreshMergeMtimes)  // the workspace head was just rewritten
        setNetworkBackoff(&state, &effects, id: id, active: false)
    }

    // Reschedules only when a path flips the overall backoff state, so one poll
    // pass that fails one path and succeeds another settles on a single interval.
    static func setNetworkBackoff(_ state: inout AppState, _ effects: inout [Effect], id: UUID, active: Bool) {
        guard let index = state.index(id) else { return }
        let wasActive = state.autoMergeBackoffActive
        state.workspaces[index].inNetworkBackoff = active
        if state.autoMergeBackoffActive != wasActive { effects.append(.rescheduleAutoMerge) }
    }

    private static func prepMessage(_ kind: OperationKind) -> String {
        switch kind {
        case .merge: return "Preparing merge..."
        case .status: return "Scanning workspace..."
        case .sync: return "Preparing sync..."
        }
    }

    private static func selectInitialWorkspace(_ state: inout AppState) {
        if let id = state.selectedWorkspaceID, state.workspaces.contains(where: { $0.id == id }) { return }
        state.selectedWorkspaceID = state.workspaces.first?.id
    }

    private static func updateDraftFromSelection(_ state: inout AppState) {
        if let workspace = state.selectedSavedWorkspace {
            state.draftConfig = workspace.config
            if state.draftConfig.author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                state.draftConfig.author = loginAuthorName
            }
        } else {
            state.draftConfig = WorkspaceConfig()
        }
    }

    private static func updateDraftInList(_ state: inout AppState, _ effects: inout [Effect], now: Date) {
        guard let id = state.selectedWorkspaceID, let index = state.index(id) else { return }
        state.workspaces[index].config = state.draftConfig
        ensureMergeTracking(&state, &effects, now: now)
        effects.append(.persistWorkspaces)
    }

    private static func normalizedDraftConfig(_ draft: WorkspaceConfig) -> WorkspaceConfig {
        WorkspaceConfig(
            id: draft.id,
            hostURL: draft.normalizedHostURL,
            localDirectory: draft.normalizedLocalDirectory,
            repoPathPrefix: draft.normalizedRepoPathPrefix,
            author: draft.normalizedAuthor,
            verifiedAccessSignature: draft.verifiedAccessSignature,
            repositoryURI: draft.repositoryURI,
            localDirectoryBookmark: draft.localDirectoryBookmark)
    }

    // On a path/URI identity change, clear the previous repo's saved passphrase and
    // forget its merge tracking (Bug A2: only here and on remove, NEVER on a draft
    // keystroke). Resets only the merge op, matching the old upsert.
    private static func upsert(_ state: inout AppState, _ effects: inout [Effect], config: WorkspaceConfig, now: Date) {
        if let index = state.index(config.id) {
            let previous = state.workspaces[index].config
            if previous.normalizedLocalDirectory != config.normalizedLocalDirectory
                || previous.bridgeRepositoryURI != config.bridgeRepositoryURI
            {
                effects.append(.clearWorkspacePassphrase(uri: previous.bridgeRepositoryURI))
                state.workspaces[index].lastSuccessfulMerge = nil
                state.workspaces[index].firstTracked = nil
                state.workspaces[index].lastStaleNotified = nil
                state.workspaces[index].isAutoMerge = false
                setNetworkBackoff(&state, &effects, id: config.id, active: false)
                effects.append(.persistMergeTracking)
                state.workspaces[index].merge = .idle
                state.workspaces[index].mergeShowsDetails = false
            }
            state.workspaces[index].config = config
        } else {
            state.workspaces.append(WorkspaceState(config: config))
        }
        ensureMergeTracking(&state, &effects, now: now)
        state.selectedWorkspaceID = config.id
        state.draftConfig = config
        effects.append(.persistWorkspaces)
        effects.append(.refreshMergeMtimes)
    }

    // Starts the staleness clock for any complete workspace not seen before, so a
    // folder that never once merges still trips the overdue notification.
    private static func ensureMergeTracking(_ state: inout AppState, _ effects: inout [Effect], now: Date) {
        var changed = false
        for index in state.workspaces.indices where state.workspaces[index].config.isComplete {
            let path = state.workspaces[index].localPath
            guard !path.isEmpty, state.workspaces[index].firstTracked == nil else { continue }
            state.workspaces[index].firstTracked = now
            changed = true
        }
        if changed { effects.append(.persistMergeTracking) }
    }
}
