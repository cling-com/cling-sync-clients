import SwiftUI

@main
struct ClingSyncApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.scenePhase) private var scenePhase
    private let isUITestMode = ProcessInfo.processInfo.arguments.contains("--ui-test-mode")

    init() {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        try? Bridge.initialize(cacheDir: cacheDir.path)

        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--reset"), let bundleIdentifier = Bundle.main.bundleIdentifier {
            UserDefaults.standard.removePersistentDomain(forName: bundleIdentifier)
            PassphraseStore.shared.resetAll()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .task {
                    if !isUITestMode {
                        MergeReminderScheduler.start()
                    }
                }
                .onChange(of: scenePhase) { _, phase in
                    if !isUITestMode, phase == .background {
                        MergeReminderScheduler.scheduleNext()
                    }
                }
        }
    }
}
