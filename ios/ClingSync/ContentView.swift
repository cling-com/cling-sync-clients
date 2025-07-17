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
    case ready
}

struct ContentView: View {
    @State private var selectedFileNames = Set<String>()
    @State private var files = [File]()
    @State private var isLoading = false
    @State private var showSettings = false
    @State private var uploader: Uploader?
    @State private var appState: AppState = .initializing
    @State private var disabledFileNames = Set<String>()

    @AppStorage("hostURL") private var hostURL = ""
    @AppStorage("passphrase") private var passphrase = ""
    @AppStorage("repoPathPrefix") private var repoPathPrefix = ""

    private var selectableFiles: [File] {
        files.filter { $0.uploadState == .none }
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
                        appState = .ready
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
                }
            }
            .sheet(isPresented: $showSettings) {
                SettingsView(isPresented: $showSettings)
                    .interactiveDismissDisabled(hostURL.isEmpty || passphrase.isEmpty)
                    .onDisappear {
                        appState = .ready
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
                            })
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

struct UploadProgress: View {
    @ObservedObject var uploader: Uploader
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            switch uploader.state {
            case .preparing:
                HStack {
                    Text(uploader.state == .preparing ? "Preparing" : "Aborted!")
                    Spacer()
                    Button("Abort", action: uploader.abort)
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                }
            case .aborted:
                HStack {
                    Text(uploader.state == .preparing ? "Preparing" : "Aborted!")
                    Spacer()
                    Button("OK") {
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            case .error:
                VStack(alignment: .leading, spacing: 8) {
                    Text(uploader.errorMessage)
                        .lineLimit(10)
                    HStack {
                        Spacer()
                        Button("OK") {
                            dismiss()
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            case .sending, .committing:
                VStack(alignment: .leading, spacing: 4) {
                    if let file = uploader.currentlySending {
                        HStack {
                            Text(file.name)
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Text(fileSizeFormatter.string(fromByteCount: file.size))
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text("Committing...")
                    }

                    ProgressView(
                        value: Double(uploader.uploadedBytes),
                        total: Double(uploader.totalBytes)
                    )
                    .progressViewStyle(.linear)
                }

                HStack {
                    let percentage = uploader.uploadedBytes * 100 / max(uploader.totalBytes, 1)
                    Text("\(percentage)% uploaded")
                        .font(.subheadline)

                    Spacer()

                    Button(action: uploader.abort) {
                        Text("Abort")
                    }
                    .disabled(uploader.state == .committing)
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            case .done:
                HStack {
                    let fileCount = uploader.files.count
                    let fileText = fileCount > 1 ? "files" : "file"
                    let sizeText = fileSizeFormatter.string(fromByteCount: uploader.uploadedBytes)
                    Text("Success! \(fileCount) \(fileText) uploaded (\(sizeText))")
                    Spacer()
                    Button("OK") {
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .padding()
        .background(.regularMaterial)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

#Preview {
    ContentView()
}
