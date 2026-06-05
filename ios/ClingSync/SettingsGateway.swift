import Foundation

// Reads and writes the repository settings, and drops a repository's stored
// credentials when the user switches away from it.
protocol SettingsGateway {
    func load() -> RepositoryConfiguration
    func passphraseMode() -> PassphraseStorageMode
    func save(_ configuration: RepositoryConfiguration)
    func save(passphraseMode: PassphraseStorageMode)
    func loadSourceSelection() -> SourceSelection
    func save(sourceSelection: SourceSelection)
    func invalidateRepository(repositoryID: String)
}

final class UserDefaultsSettingsGateway: SettingsGateway {
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> RepositoryConfiguration {
        RepositoryConfiguration(
            hostURL: defaults.string(forKey: AppStorageKey.hostURL) ?? "",
            repoPathPrefix: defaults.string(forKey: AppStorageKey.repoPathPrefix) ?? "",
            author: defaults.string(forKey: AppStorageKey.author) ?? "")
    }

    func passphraseMode() -> PassphraseStorageMode {
        PassphraseStorageMode(rawValue: defaults.string(forKey: AppStorageKey.passphraseStorageMode) ?? "") ?? .session
    }

    func save(_ configuration: RepositoryConfiguration) {
        defaults.set(configuration.hostURL, forKey: AppStorageKey.hostURL)
        defaults.set(configuration.repoPathPrefix, forKey: AppStorageKey.repoPathPrefix)
        defaults.set(configuration.author, forKey: AppStorageKey.author)
    }

    func save(passphraseMode: PassphraseStorageMode) {
        defaults.set(passphraseMode.rawValue, forKey: AppStorageKey.passphraseStorageMode)
    }

    func loadSourceSelection() -> SourceSelection {
        if let bookmark = defaults.data(forKey: AppStorageKey.sourceBookmark) {
            return .folder(bookmark: bookmark)
        }
        return .photoLibrary
    }

    func save(sourceSelection: SourceSelection) {
        switch sourceSelection {
        case .photoLibrary:
            defaults.removeObject(forKey: AppStorageKey.sourceBookmark)
        case .folder(let bookmark):
            defaults.set(bookmark, forKey: AppStorageKey.sourceBookmark)
        }
    }

    func invalidateRepository(repositoryID: String) {
        try? PassphraseStore.shared.clear(for: repositoryID)
        RepositoryURIStore.clear(for: repositoryID)
    }
}
