import AppKit
import UserNotifications

extension AppController {
    static let notificationWorkspaceIDKey = "workspaceID"

    var autoMergeChoices: [Int] { [1, 2, 3, 4, 6, 8, 12, 24] }

    func autoMergeIntervalLabel(_ hours: Int) -> String {
        switch hours {
        case 0: return "Off"
        case 1: return "Every hour"
        default: return "Every \(hours) hours"
        }
    }

    var notifyStaleDayChoices: [Int] { [1, 2, 3, 7, 14, 30] }

    func staleDaysLabel(_ days: Int) -> String {
        days == 1 ? "1 day" : "\(days) days"
    }

    var autoMergeBackoffActive: Bool { !networkBackoffPaths.isEmpty }

    // Reschedules only when a path flips the overall backoff state, so one poll
    // pass that both fails and succeeds different paths settles on one interval.
    func setNetworkBackoff(_ active: Bool, for path: String) {
        let wasActive = autoMergeBackoffActive
        if active {
            networkBackoffPaths.insert(path)
        } else {
            networkBackoffPaths.remove(path)
        }
        if autoMergeBackoffActive != wasActive {
            rescheduleAutoMerge()
        }
    }

    // A zero interval or test mode leaves the timer off. While a repository is
    // unreachable the interval drops so the merge resumes soon after the network
    // returns.
    func rescheduleAutoMerge() {
        autoMergeTimer?.invalidate()
        autoMergeTimer = nil
        guard autoMergeIntervalHours > 0, !isTestMode else { return }
        prepareAutoMergeNotifications()
        let interval =
            autoMergeBackoffActive
            ? AutoMergePolicy.backoffInterval
            : TimeInterval(autoMergeIntervalHours) * 3600
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runScheduledAutoMerge() }
        }
        RunLoop.main.add(timer, forMode: .common)
        autoMergeTimer = timer
    }

    func runScheduledAutoMerge() {
        for workspace in workspaceConfigs where workspace.isComplete {
            Task { await self.autoMergeWorkspace(workspace) }
        }
    }

    // Never prompts. Even a failure to start is reported so a broken folder
    // cannot go unnoticed.
    func autoMergeWorkspace(_ workspace: WorkspaceConfig) async {
        guard !isBusy(workspace) else { return }
        let path = workspace.normalizedLocalDirectory
        autoMergePaths.insert(path)
        do {
            try await startMergeWorkspace(workspace, password: nil, presentWindow: false)
        } catch {
            autoMergePaths.remove(path)
            let isNetwork = (error as? BridgeError)?.isNetworkError ?? false
            reportAutoMergeFailure(workspace, message: userFacingMessage(for: error), isNetworkError: isNetwork)
        }
    }

    // "up to date" stays silent so a short interval does not produce a stream of
    // no-op notifications.
    func handleAutoMergeCompletion(workspace: WorkspaceConfig, status: MergeWorkspaceStatus) {
        if !status.errorMessage.isEmpty {
            reportAutoMergeFailure(workspace, message: status.errorMessage, isNetworkError: status.errorIsNetwork)
        } else if status.cancelled || status.upToDate {
            return
        } else {
            postAutoMergeNotification(
                workspace: workspace,
                title: "Automatic merge complete",
                body: "\(workspace.displayName): \(status.statusMessage)"
            )
        }
    }

    // A connection failure is usually transient, so the path retries sooner and
    // stays silent (the "Merge (failed)" menu entry still surfaces it). Other
    // failures are notified.
    func reportAutoMergeFailure(_ workspace: WorkspaceConfig, message: String, isNetworkError: Bool) {
        setNetworkBackoff(isNetworkError, for: workspace.normalizedLocalDirectory)
        if isNetworkError {
            return
        }
        postAutoMergeNotification(workspace: workspace, title: "Automatic merge failed", body: message)
    }

    func rescheduleStaleCheck() {
        staleCheckTimer?.invalidate()
        staleCheckTimer = nil
        guard notifyStaleDays > 0, !isTestMode else { return }
        prepareAutoMergeNotifications()
        let timer = Timer(timeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.runStaleCheck() }
        }
        RunLoop.main.add(timer, forMode: .common)
        staleCheckTimer = timer
        runStaleCheck()
    }

    func runStaleCheck() {
        guard notifyStaleDays > 0 else { return }
        let now = Date()
        var notified = false
        for workspace in workspaceConfigs where workspace.isComplete {
            let path = workspace.normalizedLocalDirectory
            guard !path.isEmpty else { continue }
            let reference = lastSuccessfulMergeByPath[path] ?? firstTrackedByPath[path] ?? now
            guard AutoMergePolicy.isStale(lastSuccessOrStart: reference, days: notifyStaleDays, now: now) else {
                continue
            }
            if let last = lastStaleNotifiedByPath[path], now.timeIntervalSince(last) < AutoMergePolicy.secondsPerDay {
                continue
            }
            lastStaleNotifiedByPath[path] = now
            notified = true
            let plural = notifyStaleDays == 1 ? "" : "s"
            postAutoMergeNotification(
                workspace: workspace,
                title: "Merge overdue",
                body:
                    "\(workspace.displayName) has not merged successfully for \(notifyStaleDays) day\(plural) or more."
            )
        }
        if notified {
            persistMergeTrackingState()
        }
    }

    func scheduleAutoMergeSoon() {
        prepareAutoMergeNotifications()
        manualAutoMergeTimer?.invalidate()
        let timer = Timer(timeInterval: 5, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.runScheduledAutoMerge() }
        }
        RunLoop.main.add(timer, forMode: .common)
        manualAutoMergeTimer = timer
    }

    func prepareAutoMergeNotifications() {
        guard !isTestMode else { return }
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func postAutoMergeNotification(workspace: WorkspaceConfig, title: String, body: String) {
        guard !isTestMode else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = [Self.notificationWorkspaceIDKey: workspace.id.uuidString]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { _ in }
    }
}

extension AppController: UNUserNotificationCenterDelegate {
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        let raw = response.notification.request.content.userInfo[Self.notificationWorkspaceIDKey] as? String
        Task { @MainActor in
            if let raw, let id = UUID(uuidString: raw), let workspace = self.workspace(for: id) {
                NSApp.activate(ignoringOtherApps: true)
                self.showMergeProgressWindow(for: workspace)
            }
            completionHandler()
        }
    }
}
