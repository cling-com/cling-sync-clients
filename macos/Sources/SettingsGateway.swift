import Foundation

// The persisted scalar settings (UserDefaults-backed). The protocol + impl land
// in Phase B step b; these value types are needed now by AppEvent/AppReducer.
struct AppSettings: Equatable {
    var syncWorkers = 2
    var autoMergeIntervalHours = 0
    var notifyStaleDays = 0
}

// The persisted per-path merge-tracking dicts. The on-disk format stays path-keyed
// for back-compat; it is assembled from / applied onto the per-workspace fields at
// the load/persist boundary only.
struct MergeTracking: Equatable {
    var lastSuccessfulMerge: [String: Date] = [:]
    var firstTracked: [String: Date] = [:]
    var lastStaleNotified: [String: Date] = [:]
}

extension MergeTracking {
    init(from workspaces: [WorkspaceState]) {
        for workspace in workspaces {
            let path = workspace.localPath
            guard !path.isEmpty else { continue }
            if let date = workspace.lastSuccessfulMerge { lastSuccessfulMerge[path] = date }
            if let date = workspace.firstTracked { firstTracked[path] = date }
            if let date = workspace.lastStaleNotified { lastStaleNotified[path] = date }
        }
    }
}

// The persistence seam. Injected so tests can back it with a UserDefaults(suiteName:).
protocol SettingsGateway {
    func loadWorkspaceConfigs() -> [WorkspaceConfig]
    func saveWorkspaceConfigs(_ configs: [WorkspaceConfig])
    func loadAppSettings() -> AppSettings
    func saveSetting(_ key: SettingKey, _ value: Int)
    func loadTracking() -> MergeTracking
    func saveTracking(_ tracking: MergeTracking)
}

final class UserDefaultsSettingsGateway: SettingsGateway {
    private let defaults: UserDefaults
    private let credentials: CredentialStore
    private let workspaceConfigsKey = "workspaceConfigs"
    private let lastSuccessfulMergeKey = "lastSuccessfulMergeByPath"
    private let firstTrackedKey = "firstTrackedByPath"
    private let lastStaleNotifiedKey = "lastStaleNotifiedByPath"

    // The credential store keeps the per-workspace repository URI (with the
    // passphrase-encrypted S3 credentials) out of UserDefaults/Time Machine. It
    // defaults to the real Keychain everywhere the real app runs, including the
    // XCUITest-launched app (which isolates only UserDefaults via the env suite), so
    // the Keychain relocation is exercised end to end. Unit tests pass an in-memory
    // store explicitly to stay in-process.
    init(defaults: UserDefaults? = nil, credentials: CredentialStore? = nil) {
        if let defaults {
            self.defaults = defaults
        } else {
            let suite = ProcessInfo.processInfo.environment["CLING_SYNC_TEST_DEFAULTS_SUITE"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let suite, !suite.isEmpty, let suiteDefaults = UserDefaults(suiteName: suite) {
                self.defaults = suiteDefaults
            } else {
                self.defaults = .standard
            }
        }
        self.credentials = credentials ?? KeychainCredentialStore()
    }

    func loadWorkspaceConfigs() -> [WorkspaceConfig] {
        var configs = decodeWorkspaceConfigs()
        var needsMigration = false
        for index in configs.indices {
            if let uri = credentials.get(configs[index].id.uuidString) {
                configs[index].repositoryURI = uri
            } else if !configs[index].repositoryURI.isEmpty {
                // The URI is still in the UserDefaults JSON from a pre-Keychain
                // version; move it into the credential store and re-persist stripped.
                needsMigration = true
            }
        }
        if needsMigration {
            saveWorkspaceConfigs(configs)
        }
        return configs
    }

    func saveWorkspaceConfigs(_ configs: [WorkspaceConfig]) {
        let liveIds = Set(configs.map { $0.id.uuidString })
        for stale in decodeWorkspaceConfigs() where !liveIds.contains(stale.id.uuidString) {
            credentials.remove(stale.id.uuidString)
        }
        var stripped = configs
        for index in stripped.indices {
            credentials.set(stripped[index].id.uuidString, stripped[index].repositoryURI)
            stripped[index].repositoryURI = ""
        }
        if let data = try? JSONEncoder().encode(stripped) {
            defaults.set(data, forKey: workspaceConfigsKey)
        }
    }

    private func decodeWorkspaceConfigs() -> [WorkspaceConfig] {
        guard let data = defaults.data(forKey: workspaceConfigsKey),
            let decoded = try? JSONDecoder().decode([WorkspaceConfig].self, from: data)
        else {
            return []
        }
        return decoded
    }

    func loadAppSettings() -> AppSettings {
        AppSettings(
            syncWorkers: max(1, (defaults.object(forKey: SettingKey.syncWorkers.rawValue) as? Int) ?? 2),
            autoMergeIntervalHours: max(
                0, (defaults.object(forKey: SettingKey.autoMergeIntervalHours.rawValue) as? Int) ?? 0),
            notifyStaleDays: max(0, (defaults.object(forKey: SettingKey.notifyStaleDays.rawValue) as? Int) ?? 0))
    }

    func saveSetting(_ key: SettingKey, _ value: Int) {
        defaults.set(value, forKey: key.rawValue)
    }

    func loadTracking() -> MergeTracking {
        MergeTracking(
            lastSuccessfulMerge: loadDateDict(lastSuccessfulMergeKey),
            firstTracked: loadDateDict(firstTrackedKey),
            lastStaleNotified: loadDateDict(lastStaleNotifiedKey))
    }

    func saveTracking(_ tracking: MergeTracking) {
        saveDateDict(tracking.lastSuccessfulMerge, lastSuccessfulMergeKey)
        saveDateDict(tracking.firstTracked, firstTrackedKey)
        saveDateDict(tracking.lastStaleNotified, lastStaleNotifiedKey)
    }

    private func loadDateDict(_ key: String) -> [String: Date] {
        let raw = defaults.dictionary(forKey: key) as? [String: Double] ?? [:]
        return raw.mapValues { Date(timeIntervalSince1970: $0) }
    }

    private func saveDateDict(_ dict: [String: Date], _ key: String) {
        defaults.set(dict.mapValues { $0.timeIntervalSince1970 }, forKey: key)
    }
}
