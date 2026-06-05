import Foundation
import Testing

@testable import ClingSync

struct AppStateTest {
    private func config(host: String = "s3+http://server", author: String = "Tester") -> RepositoryConfiguration {
        RepositoryConfiguration(hostURL: host, repoPathPrefix: "/p/", author: author)
    }

    private func file(_ name: String) -> SourceFile {
        SourceFile(id: name, name: name, size: 10, modificationDate: .distantPast)
    }

    @Test func isBusyTracksUploadFlags() {
        var state = AppState(configuration: config())
        #expect(!state.isBusy)
        state.isUploadInitiated = true
        #expect(state.isBusy)
        state.isUploadInitiated = false
        state.isUploading = true
        #expect(state.isBusy)
    }

    @Test func displayedFilesFiltersByNameCaseInsensitively() {
        var state = AppState(configuration: config())
        state.files = [file("Beach.JPG"), file("sunset.png")]
        #expect(state.displayedFiles.count == 2)
        state.searchQuery = "BEACH"
        #expect(state.displayedFiles.map(\.id) == ["Beach.JPG"])
        state.searchQuery = "   "
        #expect(state.displayedFiles.count == 2)
    }

    @Test func selectAllTargetsAndSelectedFilesOnlyConsiderVisibleSelectable() {
        var state = AppState(configuration: config())
        state.files = [file("a.jpg"), file("b.jpg"), file("c.jpg")]
        state.fileStatus = ["a.jpg": .new, "b.jpg": .done, "c.jpg": .new]
        #expect(state.selectAllTargets == ["a.jpg", "c.jpg"])

        state.selectedIds = ["a.jpg", "b.jpg"]
        // Only visible files that are actually selected count.
        #expect(state.selectedFiles.map(\.id) == ["a.jpg", "b.jpg"])

        // A search narrows both derivations to the visible set.
        state.searchQuery = "a"
        #expect(state.selectAllTargets == ["a.jpg"])
        #expect(state.selectedFiles.map(\.id) == ["a.jpg"])
    }

    @Test func initialShowsSettingsOnlyWhenUnconfigured() {
        #expect(AppState.initial(configuration: config()).showSettings == false)
        #expect(AppState.initial(configuration: config(host: "")).showSettings == true)
    }

    @Test func isSelectablePinsTheNotYetUploadedStates() {
        // Unscanned (nil / .none) and re-uploadable states are selectable.
        #expect(isSelectable(nil))
        #expect(isSelectable(.none))
        #expect(isSelectable(.new))
        #expect(isSelectable(.failed(message: "boom")))
        #expect(isSelectable(.aborted))
        // In-flight and already-present states are not.
        #expect(!isSelectable(.checking))
        #expect(!isSelectable(.waiting))
        #expect(!isSelectable(.sending))
        #expect(!isSelectable(.sentWaitingCommit))
        #expect(!isSelectable(.committing))
        #expect(!isSelectable(.exists(repoPath: "")))
        #expect(!isSelectable(.done))
    }
}
