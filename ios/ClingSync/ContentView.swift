import Photos
import SwiftUI

enum AppState {
    case initializing
    case needsSettings
    case connectingToServer
    case connectionFailed(String)
    case ready
}

struct ContentView: View {
    @State var selectedFileNames = Set<String>()
    @State var files = [MediaFile]()
    @State var isLoading = false
    @State var repositoryConnected = false
    @State var showSettings = false
    @StateObject var passphrasePromptController = PassphrasePromptController()
    @State var uploader: Uploader?
    @State var appState: AppState = .initializing

    @AppStorage(AppStorageKey.author) var author = ""
    @AppStorage(AppStorageKey.hostURL) var hostURL = ""
    @AppStorage(AppStorageKey.passphraseStorageMode) var passphraseStorageModeRaw = PassphraseStorageMode.session
        .rawValue
    @AppStorage(AppStorageKey.repoPathPrefix) var repoPathPrefix = ""
    var configuration: RepositoryConfiguration {
        RepositoryConfiguration(hostURL: hostURL, repoPathPrefix: repoPathPrefix, author: author)
    }

    var passphraseStorageMode: PassphraseStorageMode {
        PassphraseStorageMode(rawValue: passphraseStorageModeRaw) ?? .session
    }

    var hasStoredPassphrase: Bool {
        PassphraseStore.shared.hasStoredPassphrase(for: configuration.repositoryID, mode: passphraseStorageMode)
    }

    var isUITestMode: Bool {
        ProcessInfo.processInfo.arguments.contains("--ui-test-mode")
    }

    var selectableFiles: [MediaFile] {
        files.filter { $0.uploadState == .none || $0.uploadState == .new }
    }

    var selectedFiles: [MediaFile] {
        files.filter { selectedFileNames.contains($0.id) }
    }

    var canUploadSelection: Bool {
        !selectedFiles.isEmpty && !selectedFiles.contains { $0.uploadState == .checking }
    }

    var visibleAppState: AppState {
        if case .needsSettings = appState, configuration.isConfigured, !showSettings {
            return .ready
        }
        return appState
    }

    var body: some View {
        Group {
            switch visibleAppState {
            case .initializing:
                ProgressView("Loading...")
                    .task { await initialize() }
            case .needsSettings:
                WelcomeStateView(isBusy: uploader != nil, showSettings: $showSettings)
            case .connectingToServer:
                ConnectingStateView()
            case .connectionFailed(let message):
                ConnectionFailedStateView(
                    message: message,
                    isBusy: uploader != nil,
                    retry: { Task { await connectToRepository(promptIfNeeded: true) } },
                    showSettings: $showSettings
                )
            case .ready:
                readyView
            }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(isPresented: $showSettings) { configuration, repositoryVerified in
                handleSettingsSave(configuration: configuration, repositoryVerified: repositoryVerified)
            }
        }
        .sheet(item: $passphrasePromptController.request) { request in
            PassphrasePromptView(controller: passphrasePromptController, request: request)
        }
    }

    var readyView: some View {
        NavigationView {
            ZStack {
                VStack(spacing: 0) {
                    if !repositoryConnected, configuration.isConfigured {
                        RepositoryAccessBanner {
                            Task { await connectToRepository(promptIfNeeded: true) }
                        }
                    }

                    List {
                        ForEach(files) { file in
                            Button {
                                toggleSelection(for: file)
                            } label: {
                                MediaFileView(file: file, isSelected: selectedFileNames.contains(file.id))
                            }
                            .buttonStyle(.plain)
                            .disabled(!isSelectable(file))
                        }
                    }
                }
                .opacity(isLoading ? 0 : 1)

                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .scaleEffect(1.5)
                }
            }
            .navigationTitle("Cling Sync")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button(
                        selectableFiles.count == selectedFileNames.count && !selectableFiles.isEmpty
                            ? "Deselect All" : "Select All"
                    ) {
                        toggleSelectAll()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Settings") {
                        showSettings = true
                    }
                    .disabled(uploader != nil)
                }
            }
            .safeAreaInset(edge: .bottom) {
                bottomBar
            }
            .animation(.easeInOut(duration: 0.25), value: selectedFileNames.isEmpty)
            .onAppear {
                if files.isEmpty {
                    Task { await loadMediaLibrary() }
                }
            }
            .onChange(of: selectedFileNames) { _ in
                if uploader?.finished == true {
                    uploader = nil
                }
            }
        }
    }

    @ViewBuilder
    var bottomBar: some View {
        if let uploader {
            UploadProgress(uploader: uploader) {
                self.uploader = nil
            }
        } else if !selectedFileNames.isEmpty {
            HStack {
                let selectedSize = selectedFiles.reduce(Int64(0)) { $0 + $1.size }
                Text("\(selectedFileNames.count) selected (\(fileSizeFormatter.string(fromByteCount: selectedSize)))")
                    .font(.subheadline)
                Spacer()
                Button("Upload") {
                    Task { await startUpload() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canUploadSelection)
            }
            .padding()
            .background(.regularMaterial)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

#Preview {
    ContentView()
}
