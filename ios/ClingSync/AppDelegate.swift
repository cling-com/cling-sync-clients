import UIKit

// Registers the backup-reminder background task. Registration must happen before
// the app finishes launching, which the SwiftUI App initializer cannot guarantee,
// so it lives in the app delegate.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // The reminder scheduler is inert under UI tests: its notification prompt
        // would interrupt the test harness, and there is nothing to schedule there.
        if !ProcessInfo.processInfo.arguments.contains("--ui-test-mode") {
            MergeReminderScheduler.registerBackgroundTask()
        }
        return true
    }
}
