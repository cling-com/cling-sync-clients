import Foundation
import Testing

@testable import ClingSync

struct ClingSyncTests {
    @Test func repositoryConfigurationBuildsStableRepositoryID() {
        let config = RepositoryConfiguration(hostURL: "http://example.com", repoPathPrefix: "/photos", author: "Tester")
        #expect(config.repositoryID == "http://example.com")
        #expect(config.isConfigured)

        // Trailing slashes are stripped, path prefix is not part of the ID.
        let config2 = RepositoryConfiguration(hostURL: "http://example.com/", repoPathPrefix: "other/", author: "")
        #expect(config.repositoryID == config2.repositoryID)

        // Different host URLs produce different IDs.
        let config3 = RepositoryConfiguration(hostURL: "http://other.com", repoPathPrefix: "/photos", author: "Tester")
        #expect(config.repositoryID != config3.repositoryID)
    }
}
