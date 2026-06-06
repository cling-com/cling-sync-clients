import Foundation
import UserNotifications

// Recomputes whether files are pending backup and posts a local notification when
// some are. Shared by the scheduled background task and the debug test controls.
// It never opens the repository: checkFiles answers from the persisted hash index.
enum MergeReminderService {
    enum Mode {
        case auto
        case daily
        case weekly
    }

    // Whether a reminder is due and for how many pending items. `.skipped` covers an
    // empty source or nothing left to back up.
    enum Outcome: Equatable {
        case skipped
        case due(count: Int, weekly: Bool)
    }

    // Runs the appropriate scan and posts a notification if anything is pending.
    // `deliverAfter` delays delivery so the debug controls can background the app
    // before the banner appears; the background task posts immediately (nil).
    static func runCheck(mode: Mode, deliverAfter: TimeInterval? = nil) async {
        let settings = UserDefaultsSettingsGateway()
        guard settings.load().isConfigured else { return }
        let source = makeSource(settings.loadSourceSelection())
        guard case .due(let count, let weekly) = await evaluate(mode: mode, source: source) else { return }
        await notifyBackupDue(count: count, weekly: weekly, deliverAfter: deliverAfter)
    }

    // Runs the daily or weekly scan and reports whether a reminder is due. Free of
    // notification side effects, so it is the unit-tested core of the reminder.
    static func evaluate(mode: Mode, source: SourceGateway) async -> Outcome {
        let files = await source.loadFiles()
        guard !files.isEmpty else { return .skipped }

        // Persist any hashes computed during a weekly scan so the next foreground
        // scan and the next reminder reuse them.
        defer { SHA256Cache.shared.save() }

        let scan = MergeReminderScan(source: source)
        let state = MergeReminderState()
        let now = Date()
        let weekly = isWeekly(mode: mode, state: state, now: now)
        let count: Int
        do {
            if weekly {
                count = try await scan.countUnsyncedOrChanged(files)
                if mode == .auto { state.lastWeeklyScan = now }
            } else {
                count = try scan.countUnsynced(files)
            }
        } catch {
            return .skipped
        }
        return count > 0 ? .due(count: count, weekly: weekly) : .skipped
    }

    private static func isWeekly(mode: Mode, state: MergeReminderState, now: Date) -> Bool {
        switch mode {
        case .daily: return false
        case .weekly: return true
        case .auto: return now.timeIntervalSince(state.lastWeeklyScan) >= weeklyInterval
        }
    }

    private static func makeSource(_ selection: SourceSelection) -> SourceGateway {
        switch selection {
        case .photoLibrary: return PhotoLibrarySource()
        case .folder(let bookmark): return FolderSource(bookmark: bookmark)
        }
    }

    private static func notifyBackupDue(count: Int, weekly: Bool, deliverAfter: TimeInterval?) async {
        let center = UNUserNotificationCenter.current()
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional else { return }

        let noun = count == 1 ? "item" : "items"
        let kind = weekly ? "new or changed" : "new"
        let content = UNMutableNotificationContent()
        content.title = "Back up your files"
        content.body = "\(count) \(kind) \(noun) ready to back up."
        content.sound = .default

        let trigger = deliverAfter.map { UNTimeIntervalNotificationTrigger(timeInterval: $0, repeats: false) }
        let request = UNNotificationRequest(identifier: notificationIdentifier, content: content, trigger: trigger)
        try? await center.add(request)
    }

    static let weeklyInterval: TimeInterval = 7 * 24 * 60 * 60
    private static let notificationIdentifier = "merge-reminder"
}
