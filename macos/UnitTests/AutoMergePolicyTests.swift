import Foundation

// Standalone unit tests for AutoMergePolicy. Compiled together with
// Sources/AutoMergePolicy.swift by the build.sh unit_test step so the pure
// decision logic is verified without the Xcode UI-test machinery.
@main
struct AutoMergePolicyTests {
    static var failures = 0

    static func check(_ condition: Bool, _ message: String) {
        if condition {
            print("ok   - \(message)")
        } else {
            print("FAIL - \(message)")
            failures += 1
        }
    }

    static func eq(_ actual: String?, _ expected: String?, _ message: String) {
        check(actual == expected, "\(message) (got \(actual ?? "nil"), want \(expected ?? "nil"))")
    }

    static func main() {
        eq(AutoMergePolicy.coarseAge(0), "0s", "coarseAge zero")
        eq(AutoMergePolicy.coarseAge(45), "45s", "coarseAge seconds")
        eq(AutoMergePolicy.coarseAge(60), "1m", "coarseAge one minute")
        eq(AutoMergePolicy.coarseAge(125), "2m", "coarseAge minutes")
        eq(AutoMergePolicy.coarseAge(3600), "1h", "coarseAge one hour")
        eq(AutoMergePolicy.coarseAge(3600 * 5 + 120), "5h", "coarseAge hours")
        eq(AutoMergePolicy.coarseAge(86_400), "1d", "coarseAge one day")
        eq(AutoMergePolicy.coarseAge(86_400 * 9), "9d", "coarseAge days")
        eq(AutoMergePolicy.coarseAge(-10), "0s", "coarseAge negative clamps to zero")

        let now = Date(timeIntervalSince1970: 1_000_000)
        check(
            AutoMergePolicy.isStale(lastSuccessOrStart: now.addingTimeInterval(-3 * 86_400), days: 2, now: now),
            "3 days old beats a 2-day threshold")
        check(
            !AutoMergePolicy.isStale(lastSuccessOrStart: now.addingTimeInterval(-86_400), days: 2, now: now),
            "1 day old is within a 2-day threshold")
        check(
            !AutoMergePolicy.isStale(lastSuccessOrStart: now.addingTimeInterval(-100 * 86_400), days: 0, now: now),
            "a zero-day threshold is never stale")

        if failures > 0 {
            print("\n\(failures) failure(s)")
            exit(1)
        }
        print("\nall AutoMergePolicy tests passed")
    }
}
