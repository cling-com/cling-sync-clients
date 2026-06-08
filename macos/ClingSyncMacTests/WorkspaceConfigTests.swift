import Foundation
import Testing

@testable import ClingSyncMac

struct ValidateHostURLTests {
    @Test func acceptsS3Schemes() {
        #expect(validateHostURL("s3+http://bucket.s3.example.com") == nil)
        #expect(validateHostURL("s3+https://bucket.s3.example.com/prefix") == nil)
        #expect(validateHostURL("  s3+https://bucket.s3.example.com  ") == nil)
    }

    @Test func acceptsLocalPaths() {
        #expect(validateHostURL("/Users/me/repo") == nil)
        #expect(validateHostURL("relative/path") == nil)
        #expect(validateHostURL("") == nil)
    }

    @Test func rejectsNonS3URLs() {
        #expect(validateHostURL("https://wrong.example.com") != nil)
        #expect(validateHostURL("http://wrong.example.com") != nil)
        #expect(validateHostURL("ftp://host/x") != nil)
    }
}

struct WorkspaceConfigTests {
    private func config(
        hostURL: String = "",
        localDirectory: String = "",
        repoPathPrefix: String = "",
        author: String = "Tester",
        repositoryURI: String = ""
    ) -> WorkspaceConfig {
        WorkspaceConfig(
            hostURL: hostURL,
            localDirectory: localDirectory,
            repoPathPrefix: repoPathPrefix,
            author: author,
            repositoryURI: repositoryURI
        )
    }

    @Test func completenessFlags() {
        #expect(!config().isComplete)
        #expect(!config(hostURL: "s3+https://x").isComplete)
        #expect(!config(hostURL: "s3+https://x", localDirectory: "/p", author: "  ").isComplete)
        #expect(config(hostURL: "s3+https://x", localDirectory: "/p", author: "me").isComplete)
    }

    @Test func readyForTestNeedsHostAndFolderOnly() {
        #expect(config(hostURL: "s3+https://x", localDirectory: "/p", author: "").isReadyForTest)
        #expect(!config(hostURL: "s3+https://x", author: "me").isReadyForTest)
        #expect(!config(localDirectory: "/p", author: "me").isReadyForTest)
    }

    @Test func validForSaveRequiresCompleteAndVerified() {
        var verified = config(hostURL: "s3+https://x", localDirectory: "/p", author: "me")
        #expect(!verified.isValidForSave)
        verified.verifiedAccessSignature = verified.accessSignature
        #expect(verified.isValidForSave)
    }

    @Test func s3HostDetection() {
        #expect(config(hostURL: "s3+https://x").isS3Host)
        #expect(config(hostURL: "S3+HTTP://x").isS3Host)
        #expect(!config(hostURL: "/local/path").isS3Host)
        #expect(!config(hostURL: "https://x").isS3Host)
    }

    @Test func bridgeRepositoryURIPicksEncodedUriForS3() {
        let s3Config = config(hostURL: "s3+https://host", repositoryURI: "s3+https://creds@host")
        #expect(s3Config.bridgeRepositoryURI == "s3+https://creds@host")
        let fileConfig = config(hostURL: "/local/repo")
        #expect(fileConfig.bridgeRepositoryURI == "/local/repo")
    }

    @Test func embeddedCredentialDetection() {
        #expect(WorkspaceConfig.s3URIHasEmbeddedCredentials("s3+http://key@host/path"))
        #expect(!WorkspaceConfig.s3URIHasEmbeddedCredentials("s3+http://host/path"))
        #expect(!WorkspaceConfig.s3URIHasEmbeddedCredentials("s3+http://host"))
        #expect(!WorkspaceConfig.s3URIHasEmbeddedCredentials("/local/path"))
    }

    @Test func displayURLStripsCredentials() {
        #expect(WorkspaceConfig.displayURL(forRepositoryURI: "s3+http://creds@host/path") == "s3+http://host/path")
        #expect(WorkspaceConfig.displayURL(forRepositoryURI: "s3+http://host/path") == "s3+http://host/path")
        #expect(WorkspaceConfig.displayURL(forRepositoryURI: "/local/path") == "/local/path")
    }

    @Test func needsS3Credentials() {
        // S3 host with no encoded URI yet.
        #expect(config(hostURL: "s3+https://host").needsS3Credentials)
        // Encoded URI whose cleartext matches the host: ready, no prompt.
        #expect(!config(hostURL: "s3+https://host", repositoryURI: "s3+https://creds@host").needsS3Credentials)
        // Encoded URI for a different host than the one shown: must re-enter.
        #expect(config(hostURL: "s3+https://host", repositoryURI: "s3+https://creds@other").needsS3Credentials)
        // File repositories never need S3 credentials.
        #expect(!config(hostURL: "/local/repo").needsS3Credentials)
    }

    @Test func repoPathPrefixGetsTrailingSlash() {
        #expect(config(repoPathPrefix: "").normalizedRepoPathPrefix == "")
        #expect(config(repoPathPrefix: "  ").normalizedRepoPathPrefix == "")
        #expect(config(repoPathPrefix: "photos").normalizedRepoPathPrefix == "photos/")
        #expect(config(repoPathPrefix: "photos/").normalizedRepoPathPrefix == "photos/")
    }

    @Test func accessVerificationTracksSignatureChanges() {
        var cfg = config(hostURL: "s3+https://host", localDirectory: "/p", repoPathPrefix: "x", author: "me")
        #expect(!cfg.isAccessVerified)
        cfg.verifiedAccessSignature = cfg.accessSignature
        #expect(cfg.isAccessVerified)
        // Any field that feeds the signature invalidates verification.
        cfg.hostURL = "s3+https://other"
        #expect(!cfg.isAccessVerified)
    }

    @Test func displayNameAndDetailText() {
        #expect(config(localDirectory: "/Users/me/Photos").displayName == "Photos")
        #expect(config().displayName == "Untitled Folder")
        #expect(config(hostURL: "s3+https://host", localDirectory: "/p").detailText == "/p")
        #expect(config(hostURL: "s3+https://host").detailText == "s3+https://host")
    }
}
