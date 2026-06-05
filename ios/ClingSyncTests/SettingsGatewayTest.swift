import Foundation
import Testing

@testable import ClingSync

struct SettingsGatewayTest {
    @Test func loadsDefaultsAndPersistsRoundTrip() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let gateway = UserDefaultsSettingsGateway(defaults: defaults)

        #expect(gateway.load() == RepositoryConfiguration(hostURL: "", repoPathPrefix: "", author: ""))
        #expect(gateway.passphraseMode() == .session)

        let config = RepositoryConfiguration(hostURL: "s3+http://host", repoPathPrefix: "/phone/", author: "Tester")
        gateway.save(config)
        gateway.save(passphraseMode: .keychain)

        #expect(gateway.load() == config)
        #expect(gateway.passphraseMode() == .keychain)
    }

    @Test func sourceSelectionRoundTrips() {
        let defaults = UserDefaults(suiteName: #function)!
        defaults.removePersistentDomain(forName: #function)
        let gateway = UserDefaultsSettingsGateway(defaults: defaults)

        #expect(gateway.loadSourceSelection() == .photoLibrary)

        let bookmark = Data([1, 2, 3, 4])
        gateway.save(sourceSelection: .folder(bookmark: bookmark))
        #expect(gateway.loadSourceSelection() == .folder(bookmark: bookmark))

        gateway.save(sourceSelection: .photoLibrary)
        #expect(gateway.loadSourceSelection() == .photoLibrary)
    }
}
