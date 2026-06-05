import SwiftUI

struct SettingsView: View {
    @AppStorage(AppStorageKey.author) private var storedAuthor = ""
    @AppStorage(AppStorageKey.hostURL) private var storedHostURL = ""
    @AppStorage(AppStorageKey.passphraseStorageMode) private var storedPassphraseStorageMode = PassphraseStorageMode
        .session.rawValue
    @AppStorage(AppStorageKey.repoPathPrefix) private var storedRepoPathPrefix = ""

    @Binding var isPresented: Bool
    let onSave: (RepositoryConfiguration, Bool) -> Void
    @StateObject private var passphrasePromptController = PassphrasePromptController()
    @StateObject private var s3CredentialsPromptController = S3CredentialsPromptController()
    private let repositoryGateway = RepositoryGateway()
    @State private var author = ""
    @State private var errorMessage = ""
    @State private var hostURL = ""
    @State private var isTesting = false
    @State private var repoPathPrefix = ""
    @State private var testedConfiguration: RepositoryConfiguration?
    @State private var showError = false
    @State private var showSuccess = false

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
            }
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
            .sheet(item: $passphrasePromptController.request) { request in
                PassphrasePromptView(controller: passphrasePromptController, request: request)
            }
            .sheet(item: $s3CredentialsPromptController.request) { request in
                S3CredentialsPromptView(controller: s3CredentialsPromptController, request: request)
            }
            .onAppear(perform: loadStoredValues)
        }
    }

    private func loadStoredValues() {
        hostURL = storedHostURL
        repoPathPrefix = storedRepoPathPrefix
        author = storedAuthor
        testedConfiguration = nil
    }

    private func saveSettings() {
        if let urlError = validateHostURL(hostURL) {
            show(urlError)
            return
        }
        storedHostURL = hostURL
        storedRepoPathPrefix = repoPathPrefix
        storedAuthor = author
        isPresented = false
        let configuration = configuration
        let repositoryVerified = testedConfiguration == configuration
        DispatchQueue.main.async {
            onSave(configuration, repositoryVerified)
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
                let resolved = try await verifyConnection()
                if resolved.mode.savesInKeychain {
                    storedPassphraseStorageMode = resolved.mode.rawValue
                }
                testedConfiguration = configuration
                isTesting = false
                showSuccess = true
            } catch let error as BridgeError {
                show(error.message)
            } catch let error as PassphraseStoreError {
                show(error.message)
            } catch {
                show(error.localizedDescription)
            }
        }
    }

    private func verifyConnection() async throws -> ResolvedPassphrase {
        guard
            let resolved = try await passphrasePromptController.resolvePassphrase(
                repositoryID: configuration.repositoryID,
                currentMode: storedPassphraseMode,
                promptIfNeeded: true,
                allowsKeychainSave: true,
                promptMessage: "Enter the passphrase for \(hostURL)."
            )
        else {
            throw PassphraseStoreError(message: "Authentication was cancelled.")
        }
        let currentConfiguration = configuration
        try await Bridge.triggerNetworkPermissionIfNeeded(url: currentConfiguration.hostURL)
        _ = try await repositoryGateway.open(
            hostURL: currentConfiguration.hostURL,
            passphrase: resolved.passphrase,
            askS3: { try await self.s3CredentialsPromptController.prompt(hostURL: currentConfiguration.hostURL) }
        )

        if resolved.mode.savesInKeychain {
            try PassphraseStore.shared.save(
                passphrase: resolved.passphrase, for: configuration.repositoryID, mode: resolved.mode)
        }
        return resolved
    }

    private func forgetStoredPassphrase() {
        do {
            try PassphraseStore.shared.clear(for: configuration.repositoryID)
            storedPassphraseStorageMode = PassphraseStorageMode.session.rawValue
            testedConfiguration = nil
        } catch let error as PassphraseStoreError {
            show(error.message)
        } catch {
            show(error.localizedDescription)
        }
    }

    private func show(_ message: String) {
        isTesting = false
        errorMessage = message
        showError = true
    }
}

#Preview {
    SettingsView(isPresented: .constant(true), onSave: { _, _ in })
}
