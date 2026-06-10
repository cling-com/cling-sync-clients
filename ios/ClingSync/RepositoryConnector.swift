import Foundation

// A graceful decline, not a failure: no passphrase available and prompting was disabled.
struct ConnectDeclined: Error {}

// The shared repository-open pipeline used by both the main screen and the share
// screen: open the repository (a no-op when already open), prompting for the
// passphrase and S3 credentials through the given controllers, and persisting the
// passphrase per its storage mode. The passphrase never leaves this flow.
struct RepositoryConnector {
    let repository: RepositoryGateway
    let settings: SettingsGateway

    // Throws ConnectDeclined when no passphrase is available and prompting is off.
    func connect(
        _ configuration: RepositoryConfiguration,
        promptIfNeeded: Bool,
        passphrase: PassphrasePromptController,
        s3 s3Controller: S3CredentialsPromptController
    ) async throws {
        if await repository.isAlreadyOpen(hostURL: configuration.hostURL).open {
            return
        }
        guard
            let access = try await requestPassphrase(
                configuration, promptIfNeeded: promptIfNeeded, controller: passphrase)
        else {
            throw ConnectDeclined()
        }
        // The open below runs detached and cannot be cancelled once issued; a
        // connect superseded while prompting (a background close, a repository
        // switch) must stop here, or it would reopen what was just closed.
        try Task.checkCancellation()
        try await Bridge.triggerNetworkPermissionIfNeeded(url: configuration.hostURL)
        _ = try await repository.open(
            hostURL: configuration.hostURL,
            passphrase: access.passphrase,
            askS3: { try await s3Controller.prompt(hostURL: configuration.hostURL) })
        if access.mode.savesInKeychain {
            try PassphraseStore.shared.save(
                passphrase: access.passphrase, for: configuration.repositoryID, mode: access.mode)
        }
        settings.save(passphraseMode: access.mode)
    }

    private func requestPassphrase(
        _ configuration: RepositoryConfiguration,
        promptIfNeeded: Bool,
        controller: PassphrasePromptController
    ) async throws -> (passphrase: String, mode: PassphraseStorageMode)? {
        let mode = settings.passphraseMode()
        if let stored = try PassphraseStore.shared.loadIfAvailable(
            for: configuration.repositoryID, mode: mode, prompt: "Unlock the repository passphrase.")
        {
            return (stored, mode)
        }
        guard promptIfNeeded else { return nil }
        let result = try await controller.prompt(
            PassphrasePromptRequest(
                title: "Repository Passphrase",
                message: "Enter the repository passphrase to connect.",
                allowsKeychainSave: true,
                suggestedMode: mode))
        return (result.passphrase, result.saveToKeychain ? .keychain : .session)
    }
}
