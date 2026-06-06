import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @AppStorage(AppStorageKey.author) private var storedAuthor = ""
    @AppStorage(AppStorageKey.hostURL) private var storedHostURL = ""
    @AppStorage(AppStorageKey.passphraseStorageMode) private var storedPassphraseStorageMode = PassphraseStorageMode
        .session.rawValue
    @AppStorage(AppStorageKey.repoPathPrefix) private var storedRepoPathPrefix = ""

    @ObservedObject var store: MainStore
    @Binding var isPresented: Bool
    @StateObject private var passphrasePromptController = PassphrasePromptController()
    @StateObject private var s3CredentialsPromptController = S3CredentialsPromptController()
    @State private var author = ""
    @State private var errorMessage = ""
    @State private var hostURL = ""
    @State private var isTesting = false
    @State private var repoPathPrefix = ""
    @State private var showError = false
    @State private var showSuccess = false
    @State private var showFolderPicker = false

    private var configuration: RepositoryConfiguration {
        RepositoryConfiguration(hostURL: hostURL, repoPathPrefix: repoPathPrefix, author: author)
    }

    private var storedPassphraseMode: PassphraseStorageMode {
        PassphraseStorageMode(rawValue: storedPassphraseStorageMode) ?? .session
    }

    private var hasStoredPassphrase: Bool {
        PassphraseStore.shared.hasStoredPassphrase(for: configuration.repositoryID, mode: storedPassphraseMode)
    }

    private var canSave: Bool {
        configuration.isConfigured && !isTesting
    }

    private var storedPassphraseLabel: String {
        guard hasStoredPassphrase else {
            return "No passphrase stored. You will be asked when you test the connection or start syncing."
        }
        switch storedPassphraseMode {
        case .session:
            return "No passphrase stored. You will be asked when needed."
        case .keychain:
            return "Passphrase is stored in the iPhone Keychain."
        }
    }

    var body: some View {
        NavigationView {
            content
                .navigationTitle("Repository Settings")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        Button("Cancel") {
                            isPresented = false
                        }
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Save") {
                            saveSettings()
                        }
                        .disabled(!canSave)
                    }
                }
                .alert("Settings Error", isPresented: $showError) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text(errorMessage)
                }
                .alert("Connection Succeeded", isPresented: $showSuccess) {
                    Button("OK", role: .cancel) {}
                } message: {
                    Text("The repository is reachable and the passphrase worked.")
                }
                .overlay {
                    if isTesting {
                        ConnectionTestingOverlay()
                    }
                }
                .sheet(item: $passphrasePromptController.request) { request in
                    PassphrasePromptView(controller: passphrasePromptController, request: request)
                }
                .sheet(item: $s3CredentialsPromptController.request) { request in
                    S3CredentialsPromptView(controller: s3CredentialsPromptController, request: request)
                }
                .onAppear(perform: loadStoredValues)
        }
    }

    // The settings sheet is split into tabs so the debug reminder controls live on
    // their own tab instead of lengthening the form. Release builds have only the
    // form, so the tab bar is omitted there.
    @ViewBuilder
    private var content: some View {
        #if DEBUG
            TabView {
                settingsForm
                    .tabItem { Label("Settings", systemImage: "gearshape") }
                ReminderTestTab()
                    .tabItem { Label("Reminders", systemImage: "bell.badge") }
            }
        #else
            settingsForm
        #endif
    }

    private var settingsForm: some View {
        Form {
            Section("Repository") {
                TextField("Host URL", text: $hostURL)
                    .textContentType(.URL)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)

                TextField("Destination path", text: $repoPathPrefix)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)

                TextField("Author", text: $author)
                    .textContentType(.name)
            }

            Section("Repository Access") {
                Text(storedPassphraseLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                Button("Test Connection") {
                    if !isTesting {
                        testConnection()
                    }
                }
                .disabled(!configuration.isConfigured || isTesting)

                if hasStoredPassphrase {
                    Button("Forget Stored Passphrase", role: .destructive) {
                        forgetStoredPassphrase()
                    }
                }
            }

            Section("Backup Source") {
                Text(sourceLabel)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Use Photo Library") {
                    store.selectSource(.photoLibrary)
                    isPresented = false
                }
                Button("Choose Folder…") {
                    showFolderPicker = true
                }
            }
        }
        .fileImporter(isPresented: $showFolderPicker, allowedContentTypes: [.folder]) { result in
            handleFolderPick(result)
        }
    }

    private func loadStoredValues() {
        hostURL = storedHostURL
        repoPathPrefix = storedRepoPathPrefix
        author = storedAuthor
    }

    private func saveSettings() {
        if let urlError = validateHostURL(hostURL) {
            show(urlError)
            return
        }
        isPresented = false
        let configuration = configuration
        DispatchQueue.main.async {
            store.handleSettingsSaved(configuration)
        }
    }

    private func testConnection() {
        if let urlError = validateHostURL(hostURL) {
            show(urlError)
            return
        }
        isTesting = true
        errorMessage = ""

        Task {
            do {
                try await store.testConnection(
                    configuration, passphrase: passphrasePromptController, s3: s3CredentialsPromptController)
                isTesting = false
                showSuccess = true
            } catch let error as BridgeError {
                show(error.message)
            } catch is CancellationError {
                show("Credential entry was cancelled.")
            } catch let error as PassphraseStoreError {
                show(error.message)
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    private func forgetStoredPassphrase() {
        do {
            try PassphraseStore.shared.clear(for: configuration.repositoryID)
            storedPassphraseStorageMode = PassphraseStorageMode.session.rawValue
        } catch let error as PassphraseStoreError {
            show(error.message)
        } catch {
            show(error.localizedDescription)
        }
    }

    private var sourceLabel: String {
        switch store.sourceSelection {
        case .photoLibrary: return "Backing up from your photo library."
        case .folder: return "Backing up from a selected folder."
        }
    }

    private func handleFolderPick(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        guard let bookmark = try? url.bookmarkData() else {
            show("Could not access the selected folder.")
            return
        }
        store.selectSource(.folder(bookmark: bookmark))
        isPresented = false
    }

    private func show(_ message: String) {
        isTesting = false
        errorMessage = message
        showError = true
    }
}

// Dimming spinner shown while a connection test runs.
private struct ConnectionTestingOverlay: View {
    var body: some View {
        Color.black.opacity(0.3)
            .ignoresSafeArea()
            .overlay {
                VStack(spacing: 16) {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle())
                        .scaleEffect(1.5)
                    Text("Testing connection...")
                        .font(.headline)
                }
                .padding(24)
                .background(Color(.systemBackground))
                .cornerRadius(12)
                .shadow(radius: 4)
            }
    }
}

#if DEBUG
    // Debug-only controls that fire the backup reminder in a few seconds, forced
    // onto the daily or weekly path, so the notification flow can be exercised by
    // hand. Mirrors the Android REMINDER_TEST_CONTROLS buttons.
    private struct ReminderTestTab: View {
        @State private var message: String?

        var body: some View {
            Form {
                Section {
                    Button("Test Daily Reminder") { trigger(weekly: false) }
                    Button("Test Weekly Reminder") { trigger(weekly: true) }
                } header: {
                    Text("Reminder Test")
                } footer: {
                    Text(message ?? defaultFooter)
                }
            }
        }

        private var defaultFooter: String {
            "Fires the backup reminder in a few seconds, forced onto the daily or weekly path. "
                + "Background the app to see the notification."
        }

        private func trigger(weekly: Bool) {
            MergeReminderScheduler.scheduleTest(weekly: weekly)
            let kind = weekly ? "Weekly" : "Daily"
            message =
                "\(kind) reminder will appear in about "
                + "\(Int(MergeReminderScheduler.testDelaySeconds)) seconds. Background the app now."
        }
    }
#endif

#Preview {
    SettingsView(store: MainStore(), isPresented: .constant(true))
}
