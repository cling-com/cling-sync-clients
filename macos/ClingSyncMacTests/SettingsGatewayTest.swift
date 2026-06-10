import Foundation
import Testing

@testable import ClingSyncMac

struct SettingsGatewayTests {
    private func freshGateway() -> UserDefaultsSettingsGateway {
        let defaults = UserDefaults(suiteName: "test.clingsyncmac.\(UUID().uuidString)")!
        return UserDefaultsSettingsGateway(defaults: defaults, credentials: InMemoryCredentialStore())
    }

    @Test func workspaceConfigsRoundTrip() {
        let gateway = freshGateway()
        #expect(gateway.loadWorkspaceConfigs().isEmpty)
        let configs = [
            WorkspaceConfig(hostURL: "s3+https://h", localDirectory: "/a", author: "me"),
            WorkspaceConfig(hostURL: "/local", localDirectory: "/b", author: "you"),
        ]
        gateway.saveWorkspaceConfigs(configs)
        #expect(gateway.loadWorkspaceConfigs() == configs)
    }

    @Test func appSettingsDefaultAndRoundTrip() {
        let gateway = freshGateway()
        #expect(gateway.loadAppSettings() == AppSettings(syncWorkers: 2, autoMergeIntervalHours: 0, notifyStaleDays: 0))
        gateway.saveSetting(.syncWorkers, 8)
        gateway.saveSetting(.autoMergeIntervalHours, 4)
        gateway.saveSetting(.notifyStaleDays, 7)
        #expect(gateway.loadAppSettings() == AppSettings(syncWorkers: 8, autoMergeIntervalHours: 4, notifyStaleDays: 7))
    }

    @Test func trackingRoundTrip() {
        let gateway = freshGateway()
        #expect(gateway.loadTracking() == MergeTracking())
        let tracking = MergeTracking(
            lastSuccessfulMerge: ["/a": Date(timeIntervalSince1970: 1_000)],
            firstTracked: ["/a": Date(timeIntervalSince1970: 500)],
            lastStaleNotified: [:])
        gateway.saveTracking(tracking)
        #expect(gateway.loadTracking() == tracking)
    }

    @Test func mergeTrackingHarvestsFromWorkspaces() {
        var workspace = WorkspaceState(
            config: WorkspaceConfig(hostURL: "s3+https://h", localDirectory: "/a", author: "me"))
        workspace.lastSuccessfulMerge = Date(timeIntervalSince1970: 2_000)
        let tracking = MergeTracking(from: [workspace])
        #expect(tracking.lastSuccessfulMerge["/a"] == Date(timeIntervalSince1970: 2_000))
        #expect(tracking.firstTracked.isEmpty)
    }
}
