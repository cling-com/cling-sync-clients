import SwiftUI

struct ResolvedPassphrase {
    let passphrase: String
    let mode: PassphraseStorageMode
}

struct PassphrasePromptRequest: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let allowsKeychainSave: Bool
    let suggestedMode: PassphraseStorageMode
}

struct PassphrasePromptResult {
    let passphrase: String
    let saveToKeychain: Bool
}

@MainActor
final class PassphrasePromptController: ObservableObject {
    @Published var request: PassphrasePromptRequest?

    private var continuation: CheckedContinuation<PassphrasePromptResult, Error>?

    func prompt(_ request: PassphrasePromptRequest) async throws -> PassphrasePromptResult {
        try await withCheckedThrowingContinuation { continuation in
            // A prior pending prompt (e.g. a connect superseded by another) must be
            // resumed before we overwrite it, or its awaiting task leaks forever.
            self.continuation?.resume(
                throwing: PassphraseStoreError(message: "Authentication was cancelled.", cancelled: true))
            self.request = request
            self.continuation = continuation
        }
    }

    func submit(passphrase: String, saveToKeychain: Bool) {
        continuation?.resume(
            returning: PassphrasePromptResult(
                passphrase: passphrase,
                saveToKeychain: saveToKeychain
            ))
        continuation = nil
        request = nil
    }

    func cancel() {
        continuation?.resume(
            throwing: PassphraseStoreError(message: "Authentication was cancelled.", cancelled: true))
        continuation = nil
        request = nil
    }

    func resolvePassphrase(
        repositoryID: String,
        currentMode: PassphraseStorageMode,
        promptIfNeeded: Bool,
        allowsKeychainSave: Bool,
        promptMessage: String
    ) async throws -> ResolvedPassphrase? {
        if let passphrase = try PassphraseStore.shared.loadIfAvailable(
            for: repositoryID,
            mode: currentMode,
            prompt: "Unlock the repository passphrase."
        ) {
            return ResolvedPassphrase(passphrase: passphrase, mode: currentMode)
        }
        guard promptIfNeeded else {
            return nil
        }
        let result = try await prompt(
            PassphrasePromptRequest(
                title: "Repository Passphrase",
                message: promptMessage,
                allowsKeychainSave: allowsKeychainSave,
                suggestedMode: currentMode
            ))
        let mode: PassphraseStorageMode = result.saveToKeychain ? .keychain : .session
        return ResolvedPassphrase(passphrase: result.passphrase, mode: mode)
    }
}

struct PassphrasePromptView: View {
    @ObservedObject var controller: PassphrasePromptController
    let request: PassphrasePromptRequest

    @Environment(\.dismiss) private var dismiss
    @State private var passphrase = ""
    @State private var saveToKeychain = false

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Text(request.message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Passphrase") {
                    SecureField("Passphrase", text: $passphrase)
                        .textContentType(.password)
                }

                if request.allowsKeychainSave {
                    Section("Storage") {
                        Toggle("Save in iPhone Keychain", isOn: $saveToKeychain)
                    }
                }
            }
            .interactiveDismissDisabled()
            .navigationTitle(request.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        controller.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Continue") {
                        controller.submit(
                            passphrase: passphrase,
                            saveToKeychain: saveToKeychain
                        )
                        dismiss()
                    }
                    .disabled(passphrase.isEmpty)
                }
            }
            .onAppear {
                saveToKeychain = request.allowsKeychainSave && request.suggestedMode.savesInKeychain
            }
        }
    }
}
