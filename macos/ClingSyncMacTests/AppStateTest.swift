import Foundation
import Testing

@testable import ClingSyncMac

struct AppStateTests {
    private func workspace(name: String) -> WorkspaceState {
        WorkspaceState(config: WorkspaceConfig(hostURL: "s3+https://h", localDirectory: "/\(name)", author: "me"))
    }

    @Test func trayTooltipCountsRunningOperations() {
        var idle = AppState()
        #expect(idle.trayTooltip == "Cling Sync")

        var one = workspace(name: "a")
        one.merge = .running(message: "Merging...", detail: "", canCancel: true)
        idle.workspaces = [one]
        #expect(idle.trayTooltip == "Merge in progress")

        var second = workspace(name: "b")
        second.sync = .running(message: "Syncing...", detail: "", canCancel: true)
        idle.workspaces = [one, second]
        #expect(idle.trayTooltip == "2 operations in progress")
    }

    @Test func statusMessagePrecedence() {
        var state = AppState()
        #expect(state.statusMessage == "Setup required")

        let single = workspace(name: "Photos")
        state.workspaces = [single]
        #expect(state.statusMessage == single.config.displayName)

        state.workspaces = [single, workspace(name: "Docs")]
        #expect(state.statusMessage == "2 folders")

        state.lastResultMessage = "Saved Photos"
        #expect(state.statusMessage == "Saved Photos")

        state.isTesting = true
        #expect(state.statusMessage == "Testing...")

        var merging = single
        merging.merge = .running(message: "Uploading 3 files", detail: "", canCancel: true)
        state.workspaces = [merging]
        #expect(state.statusMessage == "\(merging.config.displayName): Uploading 3 files")
    }

    @Test func busyAndRunningDerivations() {
        var merging = workspace(name: "a")
        merging.merge = .running(message: "Merging...", detail: "", canCancel: true)
        var state = AppState()
        state.workspaces = [merging]
        #expect(state.anyOperationRunning)
        #expect(state.hasActiveMerges)
        #expect(!state.hasActiveStatuses)
        #expect(state.workspaces[0].isBusy)
        #expect(state.workspaces[0].runningKind == .merge)
        #expect(state.runningOperationLabels == ["Merge"])
    }

    @Test func draftGatesNeedSelectionAndValidity() {
        var state = AppState()
        var config = WorkspaceConfig(hostURL: "s3+https://h", localDirectory: "/p", author: "me")
        state.workspaces = [WorkspaceState(config: config)]
        state.selectedWorkspaceID = config.id
        config.verifiedAccessSignature = config.accessSignature
        state.draftConfig = config
        #expect(state.canTestDraft)
        #expect(state.canSaveDraft)
        #expect(!state.draftNeedsTest)

        state.draftConfig.hostURL = "s3+https://changed"
        #expect(state.draftNeedsTest)
        #expect(!state.canSaveDraft)
    }
}
