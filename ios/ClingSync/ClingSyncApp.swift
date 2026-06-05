import SwiftUI

@main
struct ClingSyncApp: App {
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
        }
    }
}
