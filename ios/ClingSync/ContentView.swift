import SwiftUI

struct ContentView: View {
    @StateObject private var passphraseController: PassphrasePromptController
    @StateObject private var s3Controller: S3CredentialsPromptController
    @StateObject private var store: MainStore

    init() {
        let passphrase = PassphrasePromptController()
        let s3Prompt = S3CredentialsPromptController()
        _passphraseController = StateObject(wrappedValue: passphrase)
        _s3Controller = StateObject(wrappedValue: s3Prompt)
        _store = StateObject(wrappedValue: MainStore(passphraseController: passphrase, s3Controller: s3Prompt))
    }

    var body: some View {
        Group {
            switch store.state.phase {
            case .initializing:
                ProgressView("Loading...")
            case .needsSettings:
                WelcomeStateView(isBusy: store.state.isBusy, showSettings: showSettings)
            case .connectingToServer:
                ConnectingStateView()
            case .connectionFailed(let message):
                ConnectionFailedStateView(
                    message: message,
                    isBusy: store.state.isBusy,
                    retry: { store.dispatch(.connectClicked) },
                    showSettings: showSettings)
            case .ready:
                readyView
            }
        }
        .task { store.onStart() }
        .sheet(isPresented: showSettings) {
            SettingsView(
                isPresented: showSettings,
                onSave: { store.handleSettingsSaved($0) },
                onConnected: { store.reflectConnected($0) },
                currentSource: store.sourceSelection,
                onSelectSource: { store.selectSource($0) })
        }
        .sheet(item: $passphraseController.request) { request in
            PassphrasePromptView(controller: passphraseController, request: request)
        }
        .sheet(item: $s3Controller.request) { request in
            S3CredentialsPromptView(controller: s3Controller, request: request)
        }
        .alert(overlayTitle, isPresented: showOverlay) {
            Button("OK", role: .cancel) { store.dispatch(.errorDismissed) }
        } message: {
            Text(overlayMessage)
        }
    }

    private var readyView: some View {
        NavigationView {
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
            .navigationTitle("Cling Sync")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if allSelectableSelected {
                        Button("Deselect All") { store.dispatch(.deselectAllClicked) }
                    } else {
                        Button("Select All") { store.dispatch(.selectAllClicked) }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Settings") { store.dispatch(.settingsClicked) }
                        .disabled(store.state.isBusy)
                }
            }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .animation(.easeInOut(duration: 0.25), value: store.state.selectedIds.isEmpty)
        }
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
                onDismiss: { store.dismissUploadOutcome() })
        } else if !store.state.selectedFiles.isEmpty {
            let selected = store.state.selectedFiles
            let selectedSize = selected.reduce(Int64(0)) { $0 + $1.size }
            HStack {
                Text("\(selected.count) selected (\(fileSizeFormatter.string(fromByteCount: selectedSize)))")
                    .font(.subheadline)
                Spacer()
                Button("Upload") { store.dispatch(.uploadClicked) }
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

    private var allSelectableSelected: Bool {
        let targets = store.state.selectAllTargets
        return !targets.isEmpty && targets.isSubset(of: store.state.selectedIds)
    }

    private var uploadTotalBytes: Int64 {
        store.state.files
            .filter { store.state.currentUploadIds.contains($0.id) }
            .reduce(Int64(0)) { $0 + $1.size }
    }

    private var showSettings: Binding<Bool> {
        Binding(
            get: { store.state.showSettings },
            set: { store.dispatch($0 ? .settingsClicked : .settingsDismissed) })
    }

    private var showOverlay: Binding<Bool> {
        Binding(
            get: {
                if case .error = store.state.overlay { return true }
                return false
            },
            set: { if !$0 { store.dispatch(.errorDismissed) } })
    }

    private var overlayTitle: String {
        if case .error(let title, _) = store.state.overlay { return title }
        return ""
    }

    private var overlayMessage: String {
        if case .error(_, let message) = store.state.overlay { return message }
        return ""
    }
}

#Preview {
    ContentView()
}
