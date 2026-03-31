import Foundation
import Testing

@testable import ClingSync

struct ClingSyncTests {
    @Test func repositoryConfigurationBuildsStableRepositoryID() {
        let config = RepositoryConfiguration(hostURL: "http://example.com", repoPathPrefix: "/photos", author: "Tester")
        #expect(config.repositoryID == "http://example.com|photos")
        #expect(config.isConfigured)

        // Trailing slashes and case variations produce the same ID.
        let config2 = RepositoryConfiguration(hostURL: "HTTP://Example.com/", repoPathPrefix: "photos/", author: "")
        #expect(config.repositoryID == config2.repositoryID)
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
