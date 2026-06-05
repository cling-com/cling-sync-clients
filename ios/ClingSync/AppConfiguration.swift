import Foundation

enum AppStorageKey {
    static let author = "author"
    static let hostURL = "hostURL"
    static let passphraseStorageMode = "passphraseStorageMode"
    static let repoPathPrefix = "repoPathPrefix"
    static let sourceBookmark = "sourceBookmark"
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

// Returns nil when `url` is a syntactically acceptable host URL, or a
// human-readable error message describing the required format otherwise.
func validateHostURL(_ url: String) -> String? {
    let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("s3+http://") || trimmed.hasPrefix("s3+https://") {
        return nil
    }
    return "The Host URL must start with \"s3+http://\" or \"s3+https://\".\n\n"
        + "Example: s3+https://bucket.s3.region.example.com"
}
