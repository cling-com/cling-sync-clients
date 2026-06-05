import Foundation
import Testing

@testable import ClingSync

struct MainReducerTest {
    private func config(
        host: String = "s3+http://server-a",
        prefix: String = "/phone/",
        author: String = "Tester"
    ) -> RepositoryConfiguration {
        RepositoryConfiguration(hostURL: host, repoPathPrefix: prefix, author: author)
    }

    private func file(_ name: String) -> SourceFile {
        SourceFile(id: name, name: name, size: 10, modificationDate: .distantPast)
    }

    private func stateWithFiles(_ statuses: [String: FileStatus]) -> AppState {
        var state = AppState(configuration: config())
        state.files = statuses.keys.sorted().map { file($0) }
        state.fileStatus = statuses
        state.isConnected = true
        return state
    }

    @Test func toggleSelectionAddsThenRemoves() {
        let state = stateWithFiles(["a.jpg": .new])
        let selected = MainReducer.reduce(state, .fileSelectionChanged(id: "a.jpg", selected: true)).state
        #expect(selected.selectedIds == ["a.jpg"])
        let deselected = MainReducer.reduce(selected, .fileSelectionChanged(id: "a.jpg", selected: false)).state
        #expect(deselected.selectedIds.isEmpty)
    }

    @Test func selectAllPicksOnlySelectableFiles() {
        let state = stateWithFiles([
            "new.jpg": .new,
            "synced.jpg": .exists(repoPath: "phone/synced.jpg"),
            "done.jpg": .done,
            "aborted.jpg": .aborted,
            "failed.jpg": .failed(message: "boom"),
        ])

        let next = MainReducer.reduce(state, .selectAllClicked).state

        #expect(next.selectedIds == ["new.jpg", "aborted.jpg", "failed.jpg"])
    }

    @Test func searchQueryChangeClearsSelection() {
        var state = stateWithFiles(["a.jpg": .new])
        state.selectedIds = ["a.jpg"]
        let next = MainReducer.reduce(state, .searchQueryChanged("foo")).state
        #expect(next.searchQuery == "foo")
        #expect(next.selectedIds.isEmpty)
    }

    @Test func clearingSearchKeepsSelection() {
        var state = stateWithFiles(["a.jpg": .new])
        state.searchQuery = "a"
        state.selectedIds = ["a.jpg"]

        let next = MainReducer.reduce(state, .searchCleared).state

        #expect(next.searchQuery == "")
        // Unlike editing the query, the clear-X preserves the selection.
        #expect(next.selectedIds == ["a.jpg"])
    }

    @Test func searchFilterMatchesName() {
        var state = stateWithFiles(["beach.jpg": .new, "sunset.jpg": .new])
        state.searchQuery = "sun"
        #expect(state.displayedFiles.map(\.id) == ["sunset.jpg"])
    }

    @Test func openingSearchClearsSelectionClosingClearsQuery() {
        var state = stateWithFiles(["a.jpg": .new])
        state.selectedIds = ["a.jpg"]

        let opened = MainReducer.reduce(state, .searchToggled).state
        #expect(opened.showSearch)
        #expect(opened.selectedIds.isEmpty)

        var withQuery = opened
        withQuery.searchQuery = "x"
        let closed = MainReducer.reduce(withQuery, .searchToggled).state
        #expect(!closed.showSearch)
        #expect(closed.searchQuery == "")
    }

    @Test func uploadEnqueuesSelectedFilesAndMarksThemWaiting() {
        var state = stateWithFiles(["a.jpg": .new, "b.jpg": .new])
        state.selectedIds = ["a.jpg", "b.jpg"]

        let reduction = MainReducer.reduce(state, .uploadClicked)

        #expect(reduction.state.isUploadInitiated)
        #expect(reduction.state.currentUploadIds == ["a.jpg", "b.jpg"])
        #expect(reduction.state.fileStatus["a.jpg"] == .waiting)
        #expect(reduction.state.selectedIds.isEmpty)
        #expect(reduction.state.uploadInfo?.totalFiles == 2)
        #expect(reduction.effects == [.enqueueUpload(ids: ["a.jpg", "b.jpg"], author: "Tester")])
    }

    @Test func uploadWithNoSelectionDoesNothing() {
        let state = stateWithFiles(["a.jpg": .new])
        let reduction = MainReducer.reduce(state, .uploadClicked)
        #expect(reduction.state == state)
        #expect(reduction.effects.isEmpty)
    }

    @Test func abortResetsInitiatedAndRequestsCancel() {
        var state = stateWithFiles([:])
        state.isUploadInitiated = true
        let reduction = MainReducer.reduce(state, .abortClicked)
        #expect(!reduction.state.isUploadInitiated)
        #expect(reduction.effects == [.cancelUpload])
    }

    @Test func savingANewRepositoryInvalidatesTheOldOne() {
        var state = stateWithFiles(["a.jpg": .done])
        state.selectedIds = ["a.jpg"]
        let newConfig = config(host: "s3+http://server-b")

        let reduction = MainReducer.reduce(state, .settingsSaved(newConfig))

        #expect(!reduction.state.isConnected)
        #expect(reduction.state.fileStatus.isEmpty)
        #expect(reduction.state.selectedIds.isEmpty)
        #expect(!reduction.state.showSettings)
        #expect(
            reduction.effects == [
                .persistSettings(newConfig),
                .invalidateRepository(repositoryID: "s3+http://server-a"),
                .loadFiles,
            ])
    }

    @Test func changingNonRepoSettingsJustPersists() {
        let state = stateWithFiles(["a.jpg": .done])
        let newConfig = config(author: "Renamed")

        let reduction = MainReducer.reduce(state, .settingsSaved(newConfig))

        #expect(reduction.state.isConnected)
        #expect(reduction.state.fileStatus == ["a.jpg": .done])
        #expect(reduction.effects == [.persistSettings(newConfig)])
    }

    @Test func savingUnchangedSettingsJustPersists() {
        let state = stateWithFiles(["a.jpg": .done])
        let reduction = MainReducer.reduce(state, .settingsSaved(state.configuration))
        #expect(reduction.state.isConnected)
        #expect(reduction.state.fileStatus == ["a.jpg": .done])
        #expect(reduction.effects == [.persistSettings(state.configuration)])
    }

    @Test func savingAnInvalidHostUrlShowsErrorAndDoesNotPersist() {
        let state = stateWithFiles([:])
        let reduction = MainReducer.reduce(state, .settingsSaved(config(host: "https://nope")))

        if case .error(let title, _) = reduction.state.overlay {
            #expect(title == "Invalid Host URL")
        } else {
            Issue.record("expected an error overlay")
        }
        #expect(reduction.state.configuration == state.configuration)
        #expect(reduction.effects.isEmpty)
    }

    @Test func connectFailureLandsOnTheConnectionFailedScreen() {
        var state = stateWithFiles([:])
        state.isConnecting = true
        let next = MainReducer.reduce(state, .connectFailed("Failed to connect: nope")).state
        #expect(!next.isConnecting)
        #expect(!next.isConnected)
        #expect(next.phase == .connectionFailed("Failed to connect: nope"))
    }

    @Test func scanFailureRevertsScanningFilesToNew() {
        let state = stateWithFiles(["a.jpg": .checking, "b.jpg": .done])
        let next = MainReducer.reduce(state, .scanFailed(message: "io", ids: ["a.jpg", "b.jpg"])).state
        #expect(next.fileStatus["a.jpg"] == .new)
        // Only files that were checking are reverted.
        #expect(next.fileStatus["b.jpg"] == .done)
        #expect(!next.isScanning)
        #expect(next.overlay == .error(title: "File Scanning Error", message: "Some files could not be scanned: io"))
    }
}
