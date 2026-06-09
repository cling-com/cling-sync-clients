import Foundation
import Testing

@testable import ClingSync

struct RecentTargetsTest {
    private func freshDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: "recent-targets-test")!
        defaults.removePersistentDomain(forName: "recent-targets-test")
        return defaults
    }

    @Test func recordsMostRecentFirstDedupedAndCapped() {
        let defaults = freshDefaults()
        for index in 0..<12 {
            RecentTargets.record("dir\(index)", defaults)
        }
        let list = RecentTargets.load(defaults)
        #expect(list.count == RecentTargets.maxCount)
        #expect(list.first == "dir11")

        RecentTargets.record("dir5", defaults)
        let moved = RecentTargets.load(defaults)
        #expect(moved.first == "dir5")
        #expect(moved.filter { $0 == "dir5" }.count == 1)
        #expect(moved.count == RecentTargets.maxCount)
    }

    @Test func recordTrimsWhitespace() {
        let defaults = freshDefaults()
        RecentTargets.record("  photos/2024  ", defaults)
        #expect(RecentTargets.load(defaults) == ["photos/2024"])
    }

    @Test func recordNormalizesSurroundingSlashesSoEquivalentPathsCollapse() {
        let defaults = freshDefaults()
        RecentTargets.record("/photos/2024/", defaults)
        RecentTargets.record("photos/2024", defaults)
        #expect(RecentTargets.load(defaults) == ["photos/2024"])
    }

    @Test func optionsPutRecentFirstThenSettingsPrefixWithLastUsedDefault() {
        let options = ShareTargetOptions(settingsPrefix: "backup", recent: ["photos", "docs"])
        #expect(options.options == ["photos", "docs", "backup"])
        #expect(options.defaultTarget == "photos")
    }

    @Test func optionsWithoutRecentDefaultToSettingsPrefix() {
        let options = ShareTargetOptions(settingsPrefix: "backup", recent: [])
        #expect(options.options == ["backup"])
        #expect(options.defaultTarget == "backup")
    }

    @Test func optionsDoNotDuplicateSettingsPrefixAlreadyInRecent() {
        let options = ShareTargetOptions(settingsPrefix: "photos", recent: ["photos", "docs"])
        #expect(options.options == ["photos", "docs"])
        #expect(options.defaultTarget == "photos")
    }
}
