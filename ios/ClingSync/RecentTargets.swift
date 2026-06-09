import Foundation

// Persists the destination paths most recently used for a share upload (most
// recent first, de-duplicated, capped), so the share screen can offer them as
// quick targets alongside the configured settings prefix.
enum RecentTargets {
    private static let key = "recentShareTargets"
    static let maxCount = 10

    static func load(_ defaults: UserDefaults = .standard) -> [String] {
        defaults.stringArray(forKey: key) ?? []
    }

    static func record(_ target: String, _ defaults: UserDefaults = .standard) {
        let normalized = normalizeTarget(target)
        var list = load(defaults).filter { $0 != normalized }
        list.insert(normalized, at: 0)
        defaults.set(Array(list.prefix(maxCount)), forKey: key)
    }
}

// The repo path the upload actually uses trims surrounding slashes, so normalize
// targets the same way before storing or comparing them, or equivalent paths
// ("photos", "/photos/") would show up as separate recent entries.
func normalizeTarget(_ target: String) -> String {
    target
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
}

// The target-dir choices the share screen offers: the recent targets (most recent
// first) plus the settings prefix when it is not already among them. The default
// is the most recently used, falling back to the settings prefix when there are
// none. Pure so the share store's option logic is assertable on its own.
struct ShareTargetOptions: Equatable {
    let options: [String]
    let defaultTarget: String

    init(settingsPrefix: String, recent: [String]) {
        let prefix = normalizeTarget(settingsPrefix)
        var ordered = recent
        if !ordered.contains(prefix) {
            ordered.append(prefix)
        }
        options = ordered
        defaultTarget = recent.first ?? prefix
    }
}
