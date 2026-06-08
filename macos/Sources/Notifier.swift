import UserNotifications

// The user-notification seam (auto-merge/staleness alerts). Injected so tests use
// a no-op SilentNotifier and the store can suppress notifications in test mode.
@MainActor
protocol Notifier {
    func requestAuthorization()
    func post(id: UUID, title: String, body: String)
}

@MainActor
final class UserNotificationsNotifier: Notifier {
    static let workspaceIDKey = "workspaceID"

    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func post(id: UUID, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = [Self.workspaceIDKey: id.uuidString]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}

@MainActor
final class SilentNotifier: Notifier {
    func requestAuthorization() {}
    func post(id: UUID, title: String, body: String) {}
}
