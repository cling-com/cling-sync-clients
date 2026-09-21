import SwiftUI
import WebKit

// Hosts the Go-rendered browse UI. There is no HTTP server: the page's JS
// sends every request through window.__cling (one script message handler),
// and the reply is the HTML fragment rendered by the browse Go module.
// Downloads are streamed to disk by Go so file bytes never cross the JS
// bridge.
struct BrowseView: NSViewRepresentable {
    let controller: BrowseController

    func makeNSView(context: Context) -> WKWebView {
        controller.makeWebView()
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

// WKWebView and the script-message reply handler are main-thread-only, so
// the whole controller lives on the main actor; only the blocking bridge
// calls hop off via Task.detached.
@MainActor
final class BrowseController: NSObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    private let localPath: String
    private let openWithPromptedPassphrase: @MainActor ((String) async throws -> Int) async throws -> Int?
    private var handle: Int?
    private var isShutdown = false
    private weak var webView: WKWebView?

    init(
        localPath: String,
        openWithPromptedPassphrase: @escaping @MainActor ((String) async throws -> Int) async throws -> Int?
    ) {
        self.localPath = localPath
        self.openWithPromptedPassphrase = openWithPromptedPassphrase
    }

    func makeWebView() -> WKWebView {
        if let webView {
            return webView
        }
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "cling")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        self.webView = webView
        webView.loadHTMLString(Self.messagePage("Loading \u{2026}"), baseURL: nil)
        open(webView)
        return webView
    }

    // The message handler is attached to every document the web view loads,
    // so the only documents it may ever show are the ones handed over by
    // loadHTMLString (baseURL nil, hence about:blank). Everything else
    // (links, dropped files, anything a page might try) is refused.
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        let isInitialLoad =
            navigationAction.navigationType == .other && navigationAction.targetFrame?.isMainFrame == true
            && navigationAction.request.url?.absoluteString == "about:blank"
        return isInitialLoad ? .allow : .cancel
    }

    // Deletes all browse temp files. Only valid before any browse session is
    // open, i.e. at launch.
    nonisolated static func removeTempFiles() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("browse", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    // Closing the session is fire-and-forget: the window is already gone.
    // Also flags the controller so an open() still in flight closes the
    // session it was about to store instead of leaking it.
    func shutdown() {
        isShutdown = true
        guard let handle else { return }
        self.handle = nil
        Task.detached {
            try? Bridge.browseClose(handle: handle)
        }
    }

    private func open(_ webView: WKWebView) {
        let localPath = localPath
        Task {
            do {
                let tmpDir = try Self.browseTmpDir()
                let handle: Int
                do {
                    handle = try await Self.open(localPath, passphrase: nil, tmpDir: tmpDir)
                } catch let error as BridgeError where error.isPassphraseRequired {
                    let prompted = try await openWithPromptedPassphrase { passphrase in
                        try await Self.open(localPath, passphrase: passphrase, tmpDir: tmpDir)
                    }
                    guard let prompted else {
                        webView.loadHTMLString(
                            Self.messagePage("Browsing needs the repository passphrase."), baseURL: nil)
                        return
                    }
                    handle = prompted
                }
                if isShutdown {
                    Task.detached {
                        try? Bridge.browseClose(handle: handle)
                    }
                    return
                }
                self.handle = handle
                let page = try await Self.call(handle: handle, target: "/")
                webView.loadHTMLString(page, baseURL: nil)
            } catch let error as BridgeError {
                webView.loadHTMLString(Self.messagePage(error.message), baseURL: nil)
            } catch {
                webView.loadHTMLString(Self.messagePage(String(describing: error)), baseURL: nil)
            }
        }
    }

    func userContentController(
        _ userContentController: WKUserContentController, didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard message.frameInfo.isMainFrame else {
            replyHandler(nil, "Invalid frame")
            return
        }
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else {
            replyHandler(nil, "Invalid message")
            return
        }
        switch kind {
        case "request":
            guard let handle else {
                replyHandler(nil, "No open session")
                return
            }
            let target = body["url"] as? String ?? "/"
            Task {
                do {
                    let result = try await Self.call(handle: handle, target: target)
                    replyHandler(result, nil)
                } catch let error as BridgeError {
                    replyHandler(nil, error.message)
                } catch {
                    replyHandler(nil, String(describing: error))
                }
            }
        case "download":
            download(path: body["path"] as? String ?? "")
            replyHandler(nil, nil)
        default:
            replyHandler(nil, "Unknown message kind: \(kind)")
        }
    }

    private func download(path: String) {
        guard let handle, let window = webView?.window, !path.isEmpty else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = (path as NSString).lastPathComponent
        panel.beginSheetModal(for: window) { response in
            guard response == .OK, let url = panel.url else { return }
            Task {
                do {
                    try await Task.detached {
                        try Bridge.browseDownload(handle: handle, path: path, destPath: url.path)
                    }.value
                } catch let error as BridgeError {
                    self.showDownloadError(error.message)
                } catch {
                    self.showDownloadError(String(describing: error))
                }
            }
        }
    }

    private static func open(_ localPath: String, passphrase: String?, tmpDir: String) async throws -> Int {
        try await Task.detached {
            try Bridge.browseOpen(workspacePath: localPath, passphrase: passphrase, tmpDir: tmpDir)
        }.value
    }

    private static func call(handle: Int, target: String) async throws -> String {
        try await Task.detached {
            try Bridge.browseCall(handle: handle, target: target)
        }.value
    }

    private static func browseTmpDir() throws -> String {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("browse", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    // A download canceled by closing the window is not worth an alert.
    private func showDownloadError(_ message: String) {
        guard !isShutdown, let window = webView?.window else { return }
        let alert = NSAlert()
        alert.messageText = "Download failed"
        alert.informativeText = message
        alert.beginSheetModal(for: window)
    }

    private static func messagePage(_ message: String) -> String {
        let escaped =
            message
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return "<!doctype html><html><body><p>\(escaped)</p></body></html>"
    }
}
