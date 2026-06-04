import Foundation

// Kept free of AppKit so it can be unit tested without the app.
enum AutoMergePolicy {
    static let backoffInterval: TimeInterval = 15 * 60
    static let secondsPerDay: TimeInterval = 86_400

    // e.g. "5s", "3m", "2h", "4d".
    static func coarseAge(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 {
            return "\(total)s"
        }
        let minutes = total / 60
        if minutes < 60 {
            return "\(minutes)m"
        }
        let hours = minutes / 60
        if hours < 24 {
            return "\(hours)h"
        }
        return "\(hours / 24)d"
    }

    static func isStale(lastSuccessOrStart: Date, days: Int, now: Date) -> Bool {
        guard days > 0 else {
            return false
        }
        return now.timeIntervalSince(lastSuccessOrStart) >= Double(days) * secondsPerDay
    }
}
