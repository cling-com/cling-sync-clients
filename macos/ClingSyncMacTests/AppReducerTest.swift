import Foundation
import Testing

@testable import ClingSyncMac

private func makeWorkspace(host: String = "s3+https://h", path: String = "/p", author: String = "me") -> WorkspaceState
{
    WorkspaceState(config: WorkspaceConfig(hostURL: host, localDirectory: path, author: author))
}

private func stateWith(_ workspaces: [WorkspaceState]) -> AppState {
    var state = AppState()
    state.workspaces = workspaces
    state.selectedWorkspaceID = workspaces.first?.id
    return state
}

private let fixedNow = Date(timeIntervalSince1970: 10_000_000)

private func hasNotification(_ effects: [Effect]) -> Bool {
    effects.contains {
        if case .postNotification = $0 { return true }
        return false
    }
}

private func hasClearPassphrase(_ effects: [Effect]) -> Bool {
    effects.contains {
        if case .clearWorkspacePassphrase = $0 { return true }
        return false
    }
}

struct AppReducerStartTests {
    @Test func startSetsOptimisticRunningOpensWindowAndEmitsStart() {
        let workspace = makeWorkspace()
        let reduction = AppReducer.reduce(
            stateWith([workspace]),
            .operationStartRequested(id: workspace.id, kind: .merge, presentWindow: true, isAutoMerge: false))
        #expect(reduction.state.workspace(workspace.id)?.merge.isRunning == true)
        #expect(reduction.state.openWindows.contains(WindowKey(workspaceID: workspace.id, kind: .merge)))
        #expect(
            reduction.effects == [
                .focusProgressWindow(id: workspace.id, kind: .merge),
                .startOperation(id: workspace.id, kind: .merge, isAutoMerge: false),
            ])
    }

    @Test func runningOperationRejectsSiblingStart() {
        var workspace = makeWorkspace()
        workspace.merge = .running(message: "Preparing merge...", detail: "", canCancel: true)
        let reduction = AppReducer.reduce(
            stateWith([workspace]),
            .operationStartRequested(id: workspace.id, kind: .status, presentWindow: true, isAutoMerge: false))
        #expect(reduction.state.workspace(workspace.id)?.status == .idle)
        #expect(reduction.effects.isEmpty)
    }

    @Test func clickingIdleMergeStartsItButFailedMergeOpensWindow() {
        let idle = makeWorkspace()
        let started = AppReducer.reduce(stateWith([idle]), .operationClicked(id: idle.id, kind: .merge))
        #expect(started.state.workspace(idle.id)?.merge.isRunning == true)
        #expect(started.effects.contains(.startOperation(id: idle.id, kind: .merge, isAutoMerge: false)))

        var failed = makeWorkspace()
        failed.merge = .finished(.failed(message: "boom", detail: "", isNetwork: false))
        let opened = AppReducer.reduce(stateWith([failed]), .operationClicked(id: failed.id, kind: .merge))
        #expect(opened.state.openWindows.contains(WindowKey(workspaceID: failed.id, kind: .merge)))
        #expect(opened.state.workspace(failed.id)?.merge.isTerminalFailure == true)
        #expect(opened.effects == [.focusProgressWindow(id: failed.id, kind: .merge)])
    }

    // Bug A: a failed start clears the optimistic running to a terminal failure,
    // alerts (manual), and persists/touches no tracking.
    @Test func startFailedManualAlertsAndTouchesNoTracking() {
        var workspace = makeWorkspace()
        workspace.merge = .running(message: "Preparing merge...", detail: "", canCancel: true)
        let reduction = AppReducer.reduce(
            stateWith([workspace]),
            .operationStartFailed(id: workspace.id, kind: .merge, message: "boom", isNetwork: false, isAutoMerge: false)
        )
        #expect(
            reduction.state.workspace(workspace.id)?.merge
                == .finished(.failed(message: "boom", detail: "", isNetwork: false)))
        #expect(reduction.effects == [.showAlert(title: "Merge Failed", message: "boom")])
        #expect(!reduction.effects.contains(.persistMergeTracking))
    }
}

struct AppReducerOperationFoldTests {
    // Bug B: a terminal failure must survive a later empty / idle poll.
    @Test func terminalFailureSurvivesAbsentPoll() {
        var workspace = makeWorkspace()
        workspace.merge = .finished(.failed(message: "boom", detail: "", isNetwork: false))
        let reduction = AppReducer.reduce(
            stateWith([workspace]), .workUpdated(id: workspace.id, kind: .merge, update: .absent, now: fixedNow))
        #expect(reduction.state.workspace(workspace.id)?.merge.isTerminalFailure == true)
        #expect(reduction.effects.isEmpty)
    }

    @Test func terminalFailureSurvivesIdleSnapshot() {
        var workspace = makeWorkspace()
        workspace.merge = .finished(.failed(message: "boom", detail: "", isNetwork: false))
        let reduction = AppReducer.reduce(
            stateWith([workspace]),
            .workUpdated(id: workspace.id, kind: .merge, update: .snapshot(.idle), now: fixedNow))
        #expect(reduction.state.workspace(workspace.id)?.merge.isTerminalFailure == true)
    }

    @Test func absentPollOnRunningGoesIdle() {
        var workspace = makeWorkspace()
        workspace.status = .running(message: "Scanning...", detail: "", canCancel: true)
        let reduction = AppReducer.reduce(
            stateWith([workspace]), .workUpdated(id: workspace.id, kind: .status, update: .absent, now: fixedNow))
        #expect(reduction.state.workspace(workspace.id)?.status == .idle)
    }

    // Bug E: a completed merge (even up to date) records last-merge; cancelled does not.
    @Test func completedMergeRecordsLastMerge() {
        var workspace = makeWorkspace()
        workspace.merge = .running(message: "Merging...", detail: "", canCancel: true)
        let next = OperationState.finished(.completed(message: "merged", detail: "", revisionId: "r1", upToDate: false))
        let reduction = AppReducer.reduce(
            stateWith([workspace]), .workUpdated(id: workspace.id, kind: .merge, update: .snapshot(next), now: fixedNow)
        )
        #expect(reduction.state.workspace(workspace.id)?.lastSuccessfulMerge == fixedNow)
        #expect(reduction.effects.contains(.persistMergeTracking))
        #expect(reduction.state.lastResultMessage == "\(workspace.config.displayName): merged")
    }

    @Test func upToDateMergeAlsoRecords() {
        var workspace = makeWorkspace()
        workspace.merge = .running(message: "Merging...", detail: "", canCancel: true)
        let next = OperationState.finished(
            .completed(message: "Up to date", detail: "", revisionId: "", upToDate: true))
        let reduction = AppReducer.reduce(
            stateWith([workspace]), .workUpdated(id: workspace.id, kind: .merge, update: .snapshot(next), now: fixedNow)
        )
        #expect(reduction.state.workspace(workspace.id)?.lastSuccessfulMerge == fixedNow)
    }

    @Test func cancelledMergeDoesNotRecord() {
        var workspace = makeWorkspace()
        workspace.merge = .running(message: "Cancelling merge...", detail: "", canCancel: false)
        let next = OperationState.finished(.cancelled(message: "Merge cancelled", detail: ""))
        let reduction = AppReducer.reduce(
            stateWith([workspace]), .workUpdated(id: workspace.id, kind: .merge, update: .snapshot(next), now: fixedNow)
        )
        #expect(reduction.state.workspace(workspace.id)?.lastSuccessfulMerge == nil)
        #expect(!reduction.effects.contains(.persistMergeTracking))
    }

    @Test func manualMergeFailureAlerts() {
        var workspace = makeWorkspace()
        workspace.merge = .running(message: "Merging...", detail: "", canCancel: true)
        let next = OperationState.finished(.failed(message: "disk full", detail: "", isNetwork: false))
        let reduction = AppReducer.reduce(
            stateWith([workspace]), .workUpdated(id: workspace.id, kind: .merge, update: .snapshot(next), now: fixedNow)
        )
        #expect(reduction.effects.contains(.showAlert(title: "Merge Failed", message: "disk full")))
    }

    @Test func repeatedTerminalPollDoesNotDoubleRecord() {
        var workspace = makeWorkspace()
        workspace.merge = .finished(.completed(message: "merged", detail: "", revisionId: "r1", upToDate: false))
        let same = OperationState.finished(.completed(message: "merged", detail: "", revisionId: "r1", upToDate: false))
        let reduction = AppReducer.reduce(
            stateWith([workspace]), .workUpdated(id: workspace.id, kind: .merge, update: .snapshot(same), now: fixedNow)
        )
        #expect(reduction.effects.isEmpty)
    }
}

struct AppReducerAutoMergeTests {
    private func autoMergeCompleting(_ outcome: OperationState.Outcome) -> Reduction {
        var workspace = makeWorkspace()
        workspace.merge = .running(message: "Merging...", detail: "", canCancel: true)
        workspace.isAutoMerge = true
        return AppReducer.reduce(
            stateWith([workspace]),
            .workUpdated(id: workspace.id, kind: .merge, update: .snapshot(.finished(outcome)), now: fixedNow))
    }

    @Test func autoMergeUpToDateStaysSilentButRecords() {
        let reduction = autoMergeCompleting(
            .completed(message: "Up to date", detail: "", revisionId: "", upToDate: true))
        #expect(!hasNotification(reduction.effects))
        #expect(reduction.state.workspaces[0].isAutoMerge == false)
        #expect(reduction.state.workspaces[0].lastSuccessfulMerge == fixedNow)
    }

    @Test func autoMergeSuccessNotifies() {
        let reduction = autoMergeCompleting(
            .completed(message: "merged 1 file", detail: "", revisionId: "r", upToDate: false))
        #expect(hasNotification(reduction.effects))
    }

    @Test func autoMergeNetworkFailureSetsBackoffSilently() {
        let reduction = autoMergeCompleting(.failed(message: "offline", detail: "", isNetwork: true))
        #expect(reduction.state.workspaces[0].inNetworkBackoff == true)
        #expect(reduction.effects.contains(.rescheduleAutoMerge))
        #expect(!hasNotification(reduction.effects))
    }

    @Test func autoMergeOtherFailureNotifiesWithoutBackoff() {
        let reduction = autoMergeCompleting(.failed(message: "disk full", detail: "", isNetwork: false))
        #expect(reduction.state.workspaces[0].inNetworkBackoff == false)
        #expect(hasNotification(reduction.effects))
    }

    @Test func autoMergeTimerStartsCompleteIdleWorkspaces() {
        let workspace = makeWorkspace()
        let reduction = AppReducer.reduce(stateWith([workspace]), .autoMergeTimerFired(now: fixedNow))
        #expect(reduction.state.workspace(workspace.id)?.merge.isRunning == true)
        #expect(reduction.state.workspace(workspace.id)?.isAutoMerge == true)
        #expect(reduction.effects == [.startOperation(id: workspace.id, kind: .merge, isAutoMerge: true)])
    }

    @Test func staleCheckNotifiesOverdueWorkspaceOncePerDay() {
        var workspace = makeWorkspace()
        workspace.lastSuccessfulMerge = fixedNow.addingTimeInterval(-5 * 86_400)
        var state = stateWith([workspace])
        state.notifyStaleDays = 2
        let reduction = AppReducer.reduce(state, .staleCheckTimerFired(now: fixedNow))
        #expect(reduction.state.workspace(workspace.id)?.lastStaleNotified == fixedNow)
        #expect(hasNotification(reduction.effects))

        // A second check the same day is throttled.
        let again = AppReducer.reduce(reduction.state, .staleCheckTimerFired(now: fixedNow.addingTimeInterval(3_600)))
        #expect(!hasNotification(again.effects))
    }

    @Test func testReminderForcesNotificationForCompleteWorkspacesOnly() {
        let complete = makeWorkspace()  // freshly created, not stale
        let incomplete = makeWorkspace(host: "", path: "/q")  // missing host -> not complete
        var state = stateWith([complete, incomplete])
        state.notifyStaleDays = 0  // reminders "Off": the forced test must still fire

        let reduction = AppReducer.reduce(state, .testReminderRequested)
        let notifications = reduction.effects.filter {
            if case .postNotification = $0 { return true }
            return false
        }
        #expect(notifications.count == 1)
        // Pure test trigger: no tracking mutation or persist.
        #expect(reduction.state.workspace(complete.id)?.lastStaleNotified == nil)
        #expect(!reduction.effects.contains(.persistMergeTracking))
    }

    @Test func mergeMtimesRefreshedDrivesLastMergeDisplay() {
        let workspace = makeWorkspace()
        let date = Date(timeIntervalSince1970: 5_000)
        let populated = AppReducer.reduce(stateWith([workspace]), .mergeMtimesRefreshed([workspace.id: date]))
        #expect(populated.state.workspace(workspace.id)?.lastMergeMtime == date)
        #expect(populated.state.lastMergeText(populated.state.workspace(workspace.id)!).hasPrefix("Last Merge: "))

        // Absent from the map -> "never".
        let cleared = AppReducer.reduce(populated.state, .mergeMtimesRefreshed([:]))
        #expect(cleared.state.workspace(workspace.id)?.lastMergeMtime == nil)
        #expect(cleared.state.lastMergeText(cleared.state.workspace(workspace.id)!) == "Last Merge: never")
    }
}

struct AppReducerDraftAndWindowTests {
    // Bug A2: editing a verified draft invalidates the test but NEVER clears the keychain.
    @Test func draftAccessEditInvalidatesVerificationWithoutClearingKeychain() {
        var workspace = makeWorkspace()
        var verified = workspace.config
        verified.verifiedAccessSignature = verified.accessSignature
        workspace.config = verified
        var state = stateWith([workspace])
        state.draftConfig = verified

        var edited = verified
        edited.hostURL = "s3+https://other"
        let reduction = AppReducer.reduce(state, .draftAccessEdited(edited, now: fixedNow))
        #expect(reduction.state.draftConfig.verifiedAccessSignature == "")
        #expect(!hasClearPassphrase(reduction.effects))
        #expect(reduction.effects.contains(.persistWorkspaces))
    }

    @Test func savingSameRepoDoesNotClearSecretsButDifferentRepoDoes() {
        let workspace = makeWorkspace()
        var state = stateWith([workspace])
        // Save the same config (verified): no identity change -> no clear.
        var same = workspace.config
        same.verifiedAccessSignature = same.accessSignature
        state.draftConfig = same
        let unchanged = AppReducer.reduce(state, .saveDraftClicked(now: fixedNow))
        #expect(!hasClearPassphrase(unchanged.effects))

        // Save with a different local folder -> identity changed -> clear the
        // previous secret (the bridge identity is bridgeRepositoryURI + localDirectory).
        var moved = same
        moved.localDirectory = "/moved"
        state.draftConfig = moved
        let changed = AppReducer.reduce(state, .saveDraftClicked(now: fixedNow))
        #expect(hasClearPassphrase(changed.effects))
    }

    // Bug C: closing a window never strands a running op; a finished status resets
    // to idle (re-runnable); a failed merge stays sticky (old behavior).
    @Test func closingRunningStatusWindowKeepsItRunning() {
        var workspace = makeWorkspace()
        workspace.status = .running(message: "Scanning...", detail: "", canCancel: true)
        var state = stateWith([workspace])
        state.openWindows = [WindowKey(workspaceID: workspace.id, kind: .status)]
        let reduction = AppReducer.reduce(state, .progressWindowClosed(id: workspace.id, kind: .status))
        #expect(reduction.state.workspace(workspace.id)?.status.isRunning == true)
        #expect(!reduction.state.openWindows.contains(WindowKey(workspaceID: workspace.id, kind: .status)))
    }

    @Test func closingFinishedStatusWindowResetsToIdle() {
        var workspace = makeWorkspace()
        workspace.status = .finished(.completed(message: "1 added", detail: "", revisionId: "", upToDate: false))
        var state = stateWith([workspace])
        state.openWindows = [WindowKey(workspaceID: workspace.id, kind: .status)]
        let reduction = AppReducer.reduce(state, .progressWindowClosed(id: workspace.id, kind: .status))
        #expect(reduction.state.workspace(workspace.id)?.status == .idle)
    }

    // Re-clicking Settings while it is already open (and backgrounded) must still
    // emit a focus effect, since the state does not change and so triggers no render.
    @Test func reopeningPreferencesEmitsFocus() {
        var state = stateWith([makeWorkspace()])
        state.preferencesOpen = true
        let reduction = AppReducer.reduce(state, .openPreferencesClicked)
        #expect(reduction.state.preferencesOpen)
        #expect(reduction.effects.contains(.focusPreferences))
    }

    @Test func closingFailedMergeWindowKeepsFailedState() {
        var workspace = makeWorkspace()
        workspace.merge = .finished(.failed(message: "boom", detail: "", isNetwork: false))
        var state = stateWith([workspace])
        state.openWindows = [WindowKey(workspaceID: workspace.id, kind: .merge)]
        let reduction = AppReducer.reduce(state, .progressWindowClosed(id: workspace.id, kind: .merge))
        #expect(reduction.state.workspace(workspace.id)?.merge.isTerminalFailure == true)
    }

    @Test func removeWorkspaceClearsSecretsPersistsAndReopensPrefsWhenEmpty() {
        let workspace = makeWorkspace()
        let reduction = AppReducer.reduce(stateWith([workspace]), .removeWorkspaceClicked(id: workspace.id))
        #expect(reduction.state.workspaces.isEmpty)
        #expect(hasClearPassphrase(reduction.effects))
        #expect(reduction.effects.contains(.persistWorkspaces))
        #expect(reduction.state.preferencesOpen)
        #expect(reduction.state.lastResultMessage == "Folder removed")
    }

    @Test func removeWorkspaceClosesItsOpenWindowsButNotOthers() {
        let workspace = makeWorkspace()
        let other = makeWorkspace(path: "/q")
        var state = stateWith([workspace, other])
        state.openWindows = [
            WindowKey(workspaceID: workspace.id, kind: .merge),
            WindowKey(workspaceID: other.id, kind: .status),
        ]
        let reduction = AppReducer.reduce(state, .removeWorkspaceClicked(id: workspace.id))
        #expect(!reduction.state.openWindows.contains(WindowKey(workspaceID: workspace.id, kind: .merge)))
        #expect(reduction.state.openWindows.contains(WindowKey(workspaceID: other.id, kind: .status)))
    }

    @Test func operationStartCancelledIdlesAndClosesWindow() {
        var workspace = makeWorkspace()
        workspace.merge = .running(message: "Preparing merge...", detail: "", canCancel: true)
        var state = stateWith([workspace])
        state.openWindows = [WindowKey(workspaceID: workspace.id, kind: .merge)]
        let reduction = AppReducer.reduce(state, .operationStartCancelled(id: workspace.id, kind: .merge))
        #expect(reduction.state.workspace(workspace.id)?.merge == .idle)
        #expect(!reduction.state.openWindows.contains(WindowKey(workspaceID: workspace.id, kind: .merge)))
    }
}

struct AppReducerSettingsTests {
    @Test func autoMergeIntervalChangeReschedulesAndClearsBackoff() {
        var workspace = makeWorkspace()
        workspace.inNetworkBackoff = true
        let reduction = AppReducer.reduce(stateWith([workspace]), .autoMergeIntervalChanged(4))
        #expect(reduction.state.autoMergeIntervalHours == 4)
        #expect(reduction.state.workspace(workspace.id)?.inNetworkBackoff == false)
        #expect(reduction.effects.contains(.rescheduleAutoMerge))
        #expect(reduction.effects.contains(.persistSetting(.autoMergeIntervalHours, 4)))
    }

    @Test func unchangedIntervalIsANoOp() {
        var state = stateWith([makeWorkspace()])
        state.autoMergeIntervalHours = 4
        let reduction = AppReducer.reduce(state, .autoMergeIntervalChanged(4))
        #expect(reduction.effects.isEmpty)
    }

    @Test func notifyStaleDaysChangeReschedules() {
        let reduction = AppReducer.reduce(stateWith([makeWorkspace()]), .notifyStaleDaysChanged(7))
        #expect(reduction.state.notifyStaleDays == 7)
        #expect(reduction.effects.contains(.rescheduleStaleCheck))
        #expect(reduction.effects.contains(.persistSetting(.notifyStaleDays, 7)))
    }

    @Test func syncWorkersChangePersists() {
        let reduction = AppReducer.reduce(stateWith([makeWorkspace()]), .syncWorkersChanged(8))
        #expect(reduction.state.syncWorkers == 8)
        #expect(reduction.effects == [.persistSetting(.syncWorkers, 8)])
    }
}

struct AppReducerLaunchTests {
    @Test func stateLoadedBuildsWorkspacesAppliesTrackingAndSchedules() {
        let config = WorkspaceConfig(hostURL: "s3+https://h", localDirectory: "/p", author: "me")
        var tracking = MergeTracking()
        tracking.lastSuccessfulMerge["/p"] = Date(timeIntervalSince1970: 1_000)
        let reduction = AppReducer.reduce(
            AppState(),
            .stateLoaded(
                workspaces: [config], tracking: tracking,
                settings: AppSettings(syncWorkers: 4, autoMergeIntervalHours: 2, notifyStaleDays: 7), now: fixedNow))
        #expect(reduction.state.workspaces.count == 1)
        #expect(reduction.state.workspace(config.id)?.lastSuccessfulMerge == Date(timeIntervalSince1970: 1_000))
        #expect(reduction.state.syncWorkers == 4)
        #expect(reduction.state.selectedWorkspaceID == config.id)
        #expect(reduction.effects.contains(.rescheduleAutoMerge))
        #expect(reduction.effects.contains(.rescheduleStaleCheck))
        #expect(reduction.effects.contains(.loadSyncTargets(id: config.id)))
    }

    @Test func stateLoadedSeedsFirstTrackedForCompleteWorkspace() {
        let config = WorkspaceConfig(hostURL: "s3+https://h", localDirectory: "/p", author: "me")
        let reduction = AppReducer.reduce(
            AppState(),
            .stateLoaded(workspaces: [config], tracking: MergeTracking(), settings: AppSettings(), now: fixedNow))
        #expect(reduction.state.workspace(config.id)?.firstTracked == fixedNow)
        #expect(reduction.effects.contains(.persistMergeTracking))
    }

    @Test func emptyLaunchOpensPreferences() {
        let reduction = AppReducer.reduce(
            AppState(), .stateLoaded(workspaces: [], tracking: MergeTracking(), settings: AppSettings(), now: fixedNow))
        #expect(reduction.state.preferencesOpen)
    }
}
