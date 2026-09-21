import SwiftUI
import UIKit
import WebKit

// Full-screen browser for the repository content. There is no HTTP server:
// the page's JS sends every request through window.__cling (one script
// message handler), and the reply is the HTML rendered by the browse Go
// module. Downloads are streamed to a temp file by Go and handed to the
// share sheet, so file bytes never cross the JS bridge.
struct BrowseScreen: View {
    let configuration: RepositoryConfiguration
    let onClose: () -> Void
    @StateObject private var controller = BrowseController()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button(action: onClose) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                }
                .accessibilityLabel("Back")
                Spacer()
                Text("Browse").font(.headline)
                Spacer()
                // Mirrors the back button so the title stays centered.
                Image(systemName: "chevron.left").opacity(0)
            }
            .padding()
            Divider()
            BrowseWebView(controller: controller, configuration: configuration)
        }
        .onDisappear { controller.shutdown() }
        .sheet(item: $controller.downloadedFile, onDismiss: controller.removeSharedDownload) { file in
            ShareSheet(url: file.url)
        }
        .alert("Download failed", isPresented: showDownloadError) {
            Button("OK", role: .cancel) { controller.downloadErrorMessage = nil }
        } message: {
            Text(controller.downloadErrorMessage ?? "")
        }
    }

    private var showDownloadError: Binding<Bool> {
        Binding(
            get: { controller.downloadErrorMessage != nil },
            set: { if !$0 { controller.downloadErrorMessage = nil } })
    }
}

private struct BrowseWebView: UIViewRepresentable {
    let controller: BrowseController
    let configuration: RepositoryConfiguration

    func makeUIView(context: Context) -> WKWebView {
        let webView = controller.makeWebView()
        controller.open(configuration: configuration)
        return webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

struct DownloadedFile: Identifiable {
    let id = UUID()
    let url: URL
}

private struct ShareSheet: UIViewControllerRepresentable {
    let url: URL

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: [url], applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

@MainActor
final class BrowseController: NSObject, ObservableObject, WKScriptMessageHandlerWithReply, WKNavigationDelegate {
    @Published var downloadedFile: DownloadedFile?
    @Published var downloadErrorMessage: String?
    private var handle: Int?
    private var isShutdown = false
    private var isDownloading = false
    // The decrypted file handed to the share sheet, deleted once the sheet is gone.
    private var sharedDownload: DownloadedFile?
    private weak var webView: WKWebView?

    func makeWebView() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.userContentController.addScriptMessageHandler(self, contentWorld: .page, name: "cling")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = self
        webView.allowsLinkPreview = false
        self.webView = webView
        return webView
    }

    // The message handler is attached to every document the web view loads,
    // so the only document it may ever show is the one handed over by
    // loadHTMLString (baseURL nil, hence about:blank). Everything else
    // (links, redirects, anything a page might try) is refused.
    func webView(
        _ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        let isInitialLoad =
            navigationAction.navigationType == .other && navigationAction.targetFrame?.isMainFrame == true
            && navigationAction.request.url?.absoluteString == "about:blank"
        return isInitialLoad ? .allow : .cancel
    }

    // Deletes all browse temp files: session snapshots and downloads. Only
    // valid before any browse session is open, i.e. at launch.
    nonisolated static func removeTempFiles() {
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("browse", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }

    func removeSharedDownload() {
        guard let sharedDownload else { return }
        self.sharedDownload = nil
        try? FileManager.default.removeItem(at: sharedDownload.url.deletingLastPathComponent())
    }

    func open(configuration: RepositoryConfiguration) {
        guard handle == nil, let webView else { return }
        // The app stores the prefix like "/uitest"; the browse session takes
        // cling-sync's canonical form ("uitest/").
        var prefix = configuration.repoPathPrefix.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if !prefix.isEmpty {
            prefix += "/"
        }
        Task {
            do {
                let tmpDir = try Self.browseTmpDir()
                let handle = try await Task.detached { () throws -> Int? in
                    // Only the in-memory session passphrase is used: opening
                    // browse is gated on an established connection, which is
                    // what fills the cache, so browse itself never prompts.
                    guard let passphrase = SessionPassphrase.get(repositoryID: configuration.repositoryID)
                    else { return nil }
                    let uri = RepositoryURIStore.get(for: configuration.hostURL) ?? configuration.hostURL
                    return try Bridge.browseOpen(
                        repositoryUri: uri, passphrase: passphrase, pathPrefix: prefix, tmpDir: tmpDir)
                }.value
                guard let handle else {
                    webView.loadHTMLString(
                        Self.errorPage("The connection was lost. Reconnect and try again."),
                        baseURL: nil)
                    return
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
                webView.loadHTMLString(Self.errorPage(error.message), baseURL: nil)
            } catch {
                webView.loadHTMLString(Self.errorPage(String(describing: error)), baseURL: nil)
            }
        }
    }

    // Closing the session is fire-and-forget: the screen is already gone.
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
        // One at a time: every tap decrypts the whole file again.
        guard let handle, !path.isEmpty, !isDownloading else { return }
        isDownloading = true
        Task {
            defer { isDownloading = false }
            do {
                let dir = try Self.browseTmpDir() + "/download-\(UUID().uuidString)"
                try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
                let destPath = dir + "/" + ((path as NSString).lastPathComponent)
                try await Task.detached {
                    try Bridge.browseDownload(handle: handle, path: path, destPath: destPath)
                }.value
                let file = DownloadedFile(url: URL(fileURLWithPath: destPath))
                sharedDownload = file
                downloadedFile = file
            } catch let error as BridgeError {
                downloadErrorMessage = error.message
            } catch {
                downloadErrorMessage = String(describing: error)
            }
        }
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

    private static func errorPage(_ message: String) -> String {
        let escaped =
            message
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        return "<!doctype html><html><body><p>\(escaped)</p></body></html>"
    }
}
