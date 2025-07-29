import Photos
import SwiftUI

let fileSizeFormatter: ByteCountFormatter = {
    let formatter = ByteCountFormatter()
    formatter.countStyle = .file
    formatter.formattingContext = .standalone
    formatter.isAdaptive = true
    return formatter
}()

enum AppState {
    case initializing
    case needsSettings
    case connectingToServer
    case connectionFailed(String)
    case ready
}

// swiftlint:disable:next type_body_length
struct ContentView: View {
    @State private var selectedFileNames = Set<String>()
    @State private var files = [File]()
    @State private var isLoading = false
    @State private var showSettings = false
    @State private var uploader: Uploader?
    @State private var appState: AppState = .initializing
    @State private var disabledFileNames = Set<String>()
    @State private var fileChecker: FileChecker?
    @State private var isCheckingFiles = false

    @AppStorage("hostURL") private var hostURL = ""
    @AppStorage("passphrase") private var passphrase = ""
    @AppStorage("repoPathPrefix") private var repoPathPrefix = ""

    private var selectableFiles: [File] {
        files.filter { $0.uploadState == .none || $0.uploadState == .new }
    }

    private var selectedFiles: [File] {
        files.filter { selectedFileNames.contains($0.id) }
    }

    @ViewBuilder
    private var bottomBar: some View {
        if let uploader = uploader {
            UploadProgress(uploader: uploader) {
                self.uploader = nil
            }
        } else if !selectedFileNames.isEmpty {
            VStack(spacing: 12) {
                HStack {
                    let selectedSize: Int64 = selectedFiles.reduce(0) { $0 + $1.size }
                    Text(
                        "\(selectedFileNames.count) selected (\(fileSizeFormatter.string(fromByteCount: selectedSize)))"
                    )
                    .font(.subheadline)
                    Spacer()
                    Button(action: startUpload) {
                        Text("Upload")
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding()
            .background(.regularMaterial)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }

    private func toggleSelectAll() {
        if selectedFileNames.count == selectableFiles.count && !selectableFiles.isEmpty {
            selectedFileNames.removeAll()
        } else {
            selectedFileNames = Set(selectableFiles.map { $0.id })
        }
    }

    private func loadPhotosAsync() async {
        // todo: there seem to be duplicate filenames
        //       "ForEach<Array<File>, String, FileView>: the ID IMG_0009.HEIC occurs
        //       multiple times within the collection, this will give undefined results!"
        isLoading = true

        // Request photo permission first.
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            isLoading = false
            return
        }
        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let allPhotos = PHAsset.fetchAssets(with: .image, options: fetchOptions)
        let photoFiles = await Task.detached {
            var files = [File]()
            allPhotos.enumerateObjects { asset, _, _ in
                let resources = PHAssetResource.assetResources(for: asset)
                guard let resource = resources.first else { return }
                let filename = resource.originalFilename
                var fileSize: Int64 = 0
                if let size = resource.value(forKey: "fileSize") as? Int64 {
                    fileSize = size
                }
                files.append(File(name: filename, size: fileSize, asset: asset))
            }
            return files
        }.value

        files = photoFiles
        isLoading = false

        await checkFilesInRepository()
    }

    private func checkFilesInRepository() async {
        guard !files.isEmpty else { return }

        isCheckingFiles = true

        for file in files {
            file.uploadState = .checking
        }

        let checker = FileChecker(
            files: files,
            fileStatusUpdate: { fileStatuses in
                DispatchQueue.main.async {
                    for file in self.files {
                        if let repoPath = fileStatuses[file.name] {
                            if repoPath.isEmpty {
                                file.uploadState = .new
                            } else {
                                file.uploadState = .exists(repoPath: repoPath)
                            }
                        }
                    }
                }
            },
            progressUpdate: { processed, total in
                print("Checked \(processed) of \(total) files")
            }
        )

        fileChecker = checker

        do {
            try await checker.checkFiles()
        } catch {
            print("Error checking files: \(error)")
            for file in files where file.uploadState == .checking {
                file.uploadState = .new
            }
        }

        isCheckingFiles = false
        fileChecker = nil
    }

    var body: some View {
        switch appState {
        case .initializing:
            ProgressView("Loading...")
                .onAppear {
                    // Check settings first.
                    if hostURL.isEmpty || passphrase.isEmpty {
                        appState = .needsSettings
                    } else {
                        Task {
                            await connectToServer()
                        }
                    }
                }

        case .needsSettings:
            NavigationView {
                VStack {
                    Text("Welcome to Cling Sync")
                        .font(.largeTitle)
                        .padding()
                    Text("Please configure your server settings to get started.")
                        .padding()
                    Button("Configure Settings") {
                        showSettings = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(uploader != nil)
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(isPresented: $showSettings)
                    .interactiveDismissDisabled(hostURL.isEmpty || passphrase.isEmpty)
                    .onDisappear {
                        if !hostURL.isEmpty && !passphrase.isEmpty {
                            Task {
                                await connectToServer()
                            }
                        }
                    }
            }

        case .ready:
            NavigationView {
                ZStack {
                    List(selection: $selectedFileNames) {
                        ForEach(files) { file in
                            FileView(file: file)
                        }
                    }
                    .environment(\.editMode, .constant(.active))
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
                        Button(action: toggleSelectAll) {
                            Text(
                                selectedFileNames.count == selectableFiles.count
                                    ? "Deselect All" : "Select All")
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(
                            action: { showSettings = true },
                            label: {
                                Text("Settings")
                            }
                        )
                        .disabled(uploader != nil)
                    }
                }
                .safeAreaInset(edge: .bottom) {
                    bottomBar
                }
                .animation(.easeInOut(duration: 0.25), value: selectedFileNames.isEmpty)
                .onChange(of: selectedFileNames) { _, _ in
                    // Clear finished uploader when selection changes
                    if uploader?.finished == true {
                        uploader = nil
                    }
                }
            }
            .onAppear {
                Task {
                    await loadPhotosAsync()
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(isPresented: $showSettings)
            }

        case .connectingToServer:
            VStack(spacing: 16) {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle())
                    .scaleEffect(1.5)
                Text("Connecting to server...")
                    .font(.headline)
            }

        case .connectionFailed(let errorMessage):
            VStack(spacing: 16) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 48))
                    .foregroundColor(.red)
                Text("Connection Failed")
                    .font(.headline)
                Text(errorMessage)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Button("Go to Settings") {
                    showSettings = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(uploader != nil)
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(isPresented: $showSettings)
                    .onDisappear {
                        if !hostURL.isEmpty && !passphrase.isEmpty {
                            Task {
                                await connectToServer()
                            }
                        }
                    }
            }
        }
    }

    private func connectToServer() async {
        appState = .connectingToServer
        do {
            try await Bridge.connectToServer(url: hostURL, password: passphrase, repoPathPrefix: repoPathPrefix)
            appState = .ready
        } catch {
            let bridgeError = error as? BridgeError
            appState = .connectionFailed(bridgeError?.message ?? "Unknown error")
        }
    }

    private func startUpload() {
        guard !selectedFileNames.isEmpty else { return }
        guard uploader == nil else { return }
        let newUploader = Uploader(files: selectedFiles)
        self.uploader = newUploader
        newUploader.start()
        // todo: we should only remove all selected files when the upload is
        //       successful. Now, when we abort, we loose the selection.
        selectedFileNames.removeAll()
    }
}

#Preview {
    ContentView()
}
