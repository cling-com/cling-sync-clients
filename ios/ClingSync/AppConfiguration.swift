import Foundation

enum AppStorageKey {
    static let author = "author"
    static let hostURL = "hostURL"
    static let passphraseStorageMode = "passphraseStorageMode"
    static let repoHeadRevisionId = "repoHeadRevisionId"
    static let repoIdentifier = "repoIdentifier"
    static let repoPathPrefix = "repoPathPrefix"
    static let syncedFileIndex = "syncedFileIndex"
}

enum PassphraseStorageMode: String {
    case session
    case keychain

    var savesInKeychain: Bool {
        self != .session
    }
}

struct RepositoryConfiguration: Equatable {
    let hostURL: String
    let repoPathPrefix: String
    let author: String

    var isConfigured: Bool {
        !hostURL.isEmpty
    }

    var repositoryID: String {
        hostURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
