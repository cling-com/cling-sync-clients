import AppKit

@main
enum Main {
    static func main() {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        try? Bridge.initialize(cacheDir: cacheDir.path)
        // Decrypted leftovers of a process that died with browse open.
        BrowseController.removeTempFiles()

        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
