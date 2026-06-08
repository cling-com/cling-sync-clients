import Foundation
import Testing

@testable import ClingSyncMac

struct AutoMergePolicyTests {
    @Test func coarseAgeFormatsDurations() {
        #expect(AutoMergePolicy.coarseAge(0) == "0s")
        #expect(AutoMergePolicy.coarseAge(45) == "45s")
        #expect(AutoMergePolicy.coarseAge(60) == "1m")
        #expect(AutoMergePolicy.coarseAge(125) == "2m")
        #expect(AutoMergePolicy.coarseAge(3600) == "1h")
        #expect(AutoMergePolicy.coarseAge(3600 * 5 + 120) == "5h")
        #expect(AutoMergePolicy.coarseAge(86_400) == "1d")
        #expect(AutoMergePolicy.coarseAge(86_400 * 9) == "9d")
        #expect(AutoMergePolicy.coarseAge(-10) == "0s")
    }

    @Test func isStaleHonorsThreshold() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(AutoMergePolicy.isStale(lastSuccessOrStart: now.addingTimeInterval(-3 * 86_400), days: 2, now: now))
        #expect(!AutoMergePolicy.isStale(lastSuccessOrStart: now.addingTimeInterval(-86_400), days: 2, now: now))
        #expect(!AutoMergePolicy.isStale(lastSuccessOrStart: now.addingTimeInterval(-100 * 86_400), days: 0, now: now))
    }
}
