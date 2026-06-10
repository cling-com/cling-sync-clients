import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var passphraseController: PassphrasePromptController
    @StateObject private var s3Controller: S3CredentialsPromptController
    @StateObject private var store: MainStore

    init() {
        let passphrase = PassphrasePromptController()
        let s3Prompt = S3CredentialsPromptController()
        _passphraseController = StateObject(wrappedValue: passphrase)
        _s3Controller = StateObject(wrappedValue: s3Prompt)
        _store = StateObject(wrappedValue: MainStore(passphraseController: passphrase, s3Controller: s3Prompt))
    }

    var body: some View {
        Group {
            switch store.state.phase {
            case .initializing:
                ProgressView("Loading...")
            case .needsSettings:
                WelcomeStateView(isBusy: store.state.isBusy, showSettings: showSettings)
            case .connectingToServer:
                ConnectingStateView()
            case .connectionFailed(let message):
                ConnectionFailedStateView(
                    message: message,
                    isBusy: store.state.isBusy,
                    retry: { store.dispatch(.connectClicked) },
                    showSettings: showSettings)
            case .ready:
                readyView
            }
        }
        .task {
            store.onStart()
            if ProcessInfo.processInfo.arguments.contains("--share-test-mode") {
                store.receiveSharedURLs(shareTestFixtureURLs())
            }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: store.enterBackground()
            case .active: store.enterForeground()
            default: break
            }
        }
        .onOpenURL { url in store.receiveSharedURLs([url]) }
        .fullScreenCover(item: $store.pendingShare) { share in
            ShareScreen(store: share.store, uploadGuard: store, onFinished: { store.dismissShare() })
        }
        .sheet(isPresented: showSettings) {
            SettingsView(store: store, isPresented: showSettings)
        }
        .sheet(item: $passphraseController.request) { request in
            PassphrasePromptView(controller: passphraseController, request: request)
        }
        .sheet(item: $s3Controller.request) { request in
            S3CredentialsPromptView(controller: s3Controller, request: request)
        }
        .alert(overlayTitle, isPresented: showOverlay) {
            Button("OK", role: .cancel) { store.dispatch(.errorDismissed) }
        } message: {
            Text(overlayMessage)
        }
    }

    private var readyView: some View {
        NavigationView {
            MediaSelectionList(store: store, onUpload: { store.dispatch(.uploadClicked) })
                .navigationTitle("Cling Sync")
                .toolbar {
                    ToolbarItem(placement: .navigationBarLeading) {
                        SelectAllButton(store: store)
                    }
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button("Settings") { store.dispatch(.settingsClicked) }
                            .disabled(store.state.isBusy)
                    }
                }
        }
    }

    private var showSettings: Binding<Bool> {
        Binding(
            get: { store.state.showSettings },
            set: { store.dispatch($0 ? .settingsClicked : .settingsDismissed) })
    }

    private var showOverlay: Binding<Bool> {
        Binding(
            get: {
                if case .error = store.state.overlay { return true }
                return false
            },
            set: { if !$0 { store.dispatch(.errorDismissed) } })
    }

    private var overlayTitle: String {
        if case .error(let title, _) = store.state.overlay { return title }
        return ""
    }

    private var overlayMessage: String {
        if case .error(_, let message) = store.state.overlay { return message }
        return ""
    }
}

#Preview {
    ContentView()
}
