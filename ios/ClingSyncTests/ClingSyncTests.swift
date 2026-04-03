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

    @Test func syncIndexResetsWhenHeadChanges() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let store = SyncIndexStore(defaults: defaults)
        let record = SyncedFileRecord(name: "IMG_0001.JPG", size: 12, modificationDate: .distantPast)

        store.add([record], repositoryID: "repo", headRevisionID: "head-1")
        #expect(store.contains(record, repositoryID: "repo"))

        store.resetIfRepositoryChanged(repositoryID: "repo", headRevisionID: "head-2")
        #expect(!store.contains(record, repositoryID: "repo"))
    }
}
