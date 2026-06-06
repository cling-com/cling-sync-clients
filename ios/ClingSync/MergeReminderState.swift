import Foundation

// Remembers when the weekly full scan last ran so the daily check can choose
// between the cheap new-files check and the full new-or-changed scan.
struct MergeReminderState {
    var lastWeeklyScan: Date {
        get {
            Date(timeIntervalSince1970: UserDefaults.standard.double(forKey: AppStorageKey.mergeReminderLastWeeklyScan))
        }
        nonmutating set {
            UserDefaults.standard.set(newValue.timeIntervalSince1970, forKey: AppStorageKey.mergeReminderLastWeeklyScan)
        }
    }
}
