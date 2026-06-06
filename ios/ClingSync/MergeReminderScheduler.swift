import BackgroundTasks
import Foundation
import UserNotifications

// Schedules and runs the daily backup reminder via BGTaskScheduler. iOS runs the
// task opportunistically (near, not exactly, the reminder hour); each run
// recomputes whether files are pending and re-arms the next one. The identifier
// must match the one in Info.plist's BGTaskSchedulerPermittedIdentifiers.
enum MergeReminderScheduler {
    static let taskIdentifier = "com.cling.ClingSync.merge-reminder"
    static let reminderHour = 18
    static let testDelaySeconds: TimeInterval = 8

    // Registers the background task handler. Must run before the app finishes
    // launching, so it is called from the app delegate's didFinishLaunching.
    static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(forTaskWithIdentifier: taskIdentifier, using: nil) { task in
            handle(task)
        }
    }

    // Requests notification permission and arms the first reminder. Safe to call on
    // every launch.
    static func start() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        scheduleNext()
    }

    // Arms the next reminder for the upcoming reminder hour. Resubmitting replaces
    // any pending request for the same identifier.
    static func scheduleNext() {
        let request = BGAppRefreshTaskRequest(identifier: taskIdentifier)
        request.earliestBeginDate = nextReminderDate()
        try? BGTaskScheduler.shared.submit(request)
    }

    // Debug-only trigger (called by the Settings test controls): runs the reminder
    // check in a few seconds, forced onto the daily or weekly path, without touching
    // the real schedule.
    static func scheduleTest(weekly: Bool) {
        Task { await MergeReminderService.runCheck(mode: weekly ? .weekly : .daily, deliverAfter: testDelaySeconds) }
    }

    private static func handle(_ task: BGTask) {
        scheduleNext()
        let work = Task {
            await MergeReminderService.runCheck(mode: .auto)
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }

    private static func nextReminderDate(now: Date = Date(), calendar: Calendar = .current) -> Date {
        var components = calendar.dateComponents([.year, .month, .day], from: now)
        components.hour = reminderHour
        components.minute = 0
        components.second = 0
        let candidate = calendar.date(from: components) ?? now
        if candidate > now {
            return candidate
        }
        return calendar.date(byAdding: .day, value: 1, to: candidate) ?? candidate.addingTimeInterval(24 * 60 * 60)
    }
}
