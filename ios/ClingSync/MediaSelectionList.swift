import SwiftUI

// The repository file list + selection + upload bar shared by the main backup
// screen and the share screen: each file shows its scan/upload status, the user
// (de)selects not-yet-synced files, and the bottom bar drives upload/progress. The
// caller supplies its own navigation chrome and the Upload action.
struct MediaSelectionList: View {
    @ObservedObject var store: MainStore
    let onUpload: () -> Void
    // The share screen passes its dismissal here, so dismissing a succeeded/failed
    // banner returns to the main app. A no-op on the main screen (the banner just clears).
    var onUploadFinished: () -> Void = {}

    var body: some View {
        ZStack {
            VStack(spacing: 0) {
                if !store.state.isConnected, store.state.configuration.isConfigured {
                    RepositoryAccessBanner { store.dispatch(.connectClicked) }
                }

                List {
                    ForEach(store.state.displayedFiles) { file in
                        Button {
                            store.dispatch(
                                .fileSelectionChanged(
                                    id: file.id, selected: !store.state.selectedIds.contains(file.id)))
                        } label: {
                            MediaFileView(
                                file: file,
                                status: store.state.fileStatus[file.id],
                                isSelected: store.state.selectedIds.contains(file.id),
                                loadThumbnail: { await store.thumbnail(for: file) })
                        }
                        .buttonStyle(.plain)
                        .disabled(!isSelectable(store.state.fileStatus[file.id]))
                    }
                }
            }
            .opacity(store.state.isLoadingFiles ? 0 : 1)

            if store.state.isLoadingFiles {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .scaleEffect(1.5)
            }
        }
        .safeAreaInset(edge: .bottom) { bottomBar }
        .animation(.easeInOut(duration: 0.25), value: store.state.selectedIds.isEmpty)
    }

    @ViewBuilder
    private var bottomBar: some View {
        if store.state.isUploading || store.state.isUploadInitiated || store.uploadOutcome != nil {
            UploadProgress(
                currentFile: store.state.uploadInfo?.currentFile,
                uploadedBytes: store.state.uploadedBytes,
                totalBytes: uploadTotalBytes,
                outcome: store.uploadOutcome,
                onAbort: { store.dispatch(.abortClicked) },
                onDismiss: {
                    let outcome = store.uploadOutcome
                    store.dismissUploadOutcome()
                    guard let outcome else { return }
                    switch outcome {
                    case .succeeded, .failed: onUploadFinished()
                    case .aborted: break
                    }
                })
        } else if !store.state.selectedFiles.isEmpty {
            let selected = store.state.selectedFiles
            let selectedSize = selected.reduce(Int64(0)) { $0 + $1.size }
            HStack {
                Text("\(selected.count) selected (\(fileSizeFormatter.string(fromByteCount: selectedSize)))")
                    .font(.subheadline)
                Spacer()
                Button("Upload") { onUpload() }
                    .buttonStyle(.borderedProminent)
                    .disabled(
                        !store.state.isConnected
                            || selected.contains { store.state.fileStatus[$0.id] == .checking })
            }
            .padding()
            .background(.regularMaterial)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private var uploadTotalBytes: Int64 {
        store.state.files
            .filter { store.state.currentUploadIds.contains($0.id) }
            .reduce(Int64(0)) { $0 + $1.size }
    }
}

// Whether Select All has already selected everything selectable, so callers can
// choose between the Select All and Deselect All toolbar button.
func allSelectableSelected(_ state: AppState) -> Bool {
    let targets = state.selectAllTargets
    return !targets.isEmpty && targets.isSubset(of: state.selectedIds)
}

// The leading toolbar button shared by the main and share screens. Once a scan
// settles with nothing left to back up it reads "No new files" and is disabled.
struct SelectAllButton: View {
    @ObservedObject var store: MainStore

    var body: some View {
        if store.state.selectAllTargets.isEmpty {
            Button(store.state.isScanning ? "Select All" : "No new files") {}
                .disabled(true)
        } else if allSelectableSelected(store.state) {
            Button("Deselect All") { store.dispatch(.deselectAllClicked) }
        } else {
            Button("Select All") { store.dispatch(.selectAllClicked) }
        }
    }
}
