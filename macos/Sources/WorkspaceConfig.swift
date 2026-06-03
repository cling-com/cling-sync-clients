import Foundation

let loginAuthorName: String = {
    let user = NSUserName().trimmingCharacters(in: .whitespacesAndNewlines)
    return user.isEmpty ? NSFullUserName() : user
}()

// Returns nil when `url` is a syntactically acceptable Repository URL, or a
// human-readable error message describing the required format otherwise.
// Local filesystem paths are accepted. Anything that looks like a URL must
// start with "s3+http://" or "s3+https://".
func validateHostURL(_ url: String) -> String? {
    let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.hasPrefix("s3+http://") || trimmed.hasPrefix("s3+https://") {
        return nil
    }
    if trimmed.contains("://") {
        return "Remote repository URLs must start with \"s3+http://\" or \"s3+https://\".\n\n"
            + "Example: s3+https://bucket.s3.region.example.com\n\n"
            + "Local folder paths are also accepted."
    }
    return nil
}

struct WorkspaceConfig: Codable, Identifiable, Equatable {
    var id: UUID
    var hostURL: String
    var localDirectory: String
    var repoPathPrefix: String
    var author: String
    var verifiedAccessSignature: String
    // The directly-openable repository URI sent to the bridge. For S3 it carries
    // the encrypted credentials; hostURL stays the cleartext value for display.
    var repositoryURI: String
    // Security-scoped bookmark for `localDirectory`. A sandboxed app can only
    // reach a user-selected folder across launches by resolving this.
    var localDirectoryBookmark: Data?

    init(
        id: UUID = UUID(),
        hostURL: String = "",
        localDirectory: String = "",
        repoPathPrefix: String = "",
        author: String = loginAuthorName,
        verifiedAccessSignature: String = "",
        repositoryURI: String = "",
        localDirectoryBookmark: Data? = nil
    ) {
        self.id = id
        self.hostURL = hostURL
        self.localDirectory = localDirectory
        self.repoPathPrefix = repoPathPrefix
        self.author = author
        self.verifiedAccessSignature = verifiedAccessSignature
        self.repositoryURI = repositoryURI
        self.localDirectoryBookmark = localDirectoryBookmark
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        hostURL = try container.decodeIfPresent(String.self, forKey: .hostURL) ?? ""
        localDirectory = try container.decodeIfPresent(String.self, forKey: .localDirectory) ?? ""
        repoPathPrefix = try container.decodeIfPresent(String.self, forKey: .repoPathPrefix) ?? ""
        author = try container.decodeIfPresent(String.self, forKey: .author) ?? loginAuthorName
        verifiedAccessSignature = try container.decodeIfPresent(String.self, forKey: .verifiedAccessSignature) ?? ""
        repositoryURI = try container.decodeIfPresent(String.self, forKey: .repositoryURI) ?? ""
        localDirectoryBookmark = try container.decodeIfPresent(Data.self, forKey: .localDirectoryBookmark)
    }

    var isComplete: Bool {
        !hostURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !localDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isValidForSave: Bool {
        isComplete && isAccessVerified
    }

    var isReadyForTest: Bool {
        !hostURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !localDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var normalizedHostURL: String {
        hostURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isS3Host: Bool {
        let lower = normalizedHostURL.lowercased()
        return lower.hasPrefix("s3+http://") || lower.hasPrefix("s3+https://")
    }

    // The URI handed to the bridge: the encrypted S3 URI for S3 repositories,
    // the host/path itself otherwise.
    var bridgeRepositoryURI: String {
        isS3Host ? repositoryURI.trimmingCharacters(in: .whitespacesAndNewlines) : normalizedHostURL
    }

    // True for an S3 repository whose credentials have not been encrypted into
    // `repositoryURI` yet (or were encrypted for a different URL), so the user
    // must supply an S3 key/secret.
    var needsS3Credentials: Bool {
        guard isS3Host else { return false }
        let uri = repositoryURI.trimmingCharacters(in: .whitespacesAndNewlines)
        guard WorkspaceConfig.s3URIHasEmbeddedCredentials(uri) else { return true }
        return WorkspaceConfig.displayURL(forRepositoryURI: uri) != normalizedHostURL
    }

    static func s3URIHasEmbeddedCredentials(_ uri: String) -> Bool {
        guard let schemeEnd = uri.range(of: "://") else { return false }
        let authority = uri[schemeEnd.upperBound...].prefix(while: { $0 != "/" })
        return authority.contains("@")
    }

    // Strips the encrypted credential userinfo from an S3 repository URI, giving
    // the cleartext URL to show and edit. Non-S3 URIs are returned unchanged.
    static func displayURL(forRepositoryURI uri: String) -> String {
        guard uri.hasPrefix("s3+"), let schemeEnd = uri.range(of: "://") else { return uri }
        let rest = uri[schemeEnd.upperBound...]
        let slash = rest.firstIndex(of: "/") ?? rest.endIndex
        let authority = rest[..<slash]
        guard let atIndex = authority.firstIndex(of: "@") else { return uri }
        let strippedAuthority = authority[authority.index(after: atIndex)...]
        return String(uri[..<schemeEnd.upperBound]) + strippedAuthority + rest[slash...]
    }

    var normalizedLocalDirectory: String {
        localDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedRepoPathPrefix: String {
        let trimmed = repoPathPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.hasSuffix("/") ? trimmed : trimmed + "/"
    }

    var normalizedAuthor: String {
        let trimmed = author.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? loginAuthorName : trimmed
    }

    var accessSignature: String {
        [normalizedLocalDirectory, normalizedHostURL, normalizedRepoPathPrefix].joined(separator: "\n")
    }

    var isAccessVerified: Bool {
        !verifiedAccessSignature.isEmpty && verifiedAccessSignature == accessSignature
    }

    var displayName: String {
        let path = normalizedLocalDirectory
        if path.isEmpty {
            return "Untitled Folder"
        }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    var detailText: String {
        let path = normalizedLocalDirectory
        return path.isEmpty ? normalizedHostURL : path
    }

    var lastMergeDate: Date? {
        let path = (normalizedLocalDirectory as NSString).appendingPathComponent(".cling/repository/refs/head")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        return attrs[.modificationDate] as? Date
    }
}
