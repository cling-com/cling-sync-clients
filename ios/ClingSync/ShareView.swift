import SwiftUI

// The screen shown when files are shared into the app. It reuses the main backup
// machinery (a MainStore over a shared-files source) and its file list, so shared
// files are scanned, already-synced ones are marked and excluded, and the user can
// (de)select before uploading. The only additions are the target-directory picker
// and the "abort the running upload first" guard.
struct ShareScreen: View {
    @ObservedObject private var passphraseController: PassphrasePromptController
    @ObservedObject private var s3Controller: S3CredentialsPromptController
    @ObservedObject private var store: MainStore

    private let uploadGuard: ActiveUploadGuard
    private let onFinished: () -> Void
    private let targetOptions: [String]

    @State private var target: String
    @State private var showAbortConfirm = false

    // The store arrives from the main store's `pendingShare` (it owns the share
    // store so the background grace close can see it), already wired to its own
    // prompt controllers.
    init(
        store: MainStore,
        uploadGuard: ActiveUploadGuard,
        onFinished: @escaping () -> Void
    ) {
        let settings = UserDefaultsSettingsGateway()
        let options = ShareTargetOptions(settingsPrefix: settings.load().repoPathPrefix, recent: RecentTargets.load())
        _store = ObservedObject(wrappedValue: store)
        _passphraseController = ObservedObject(wrappedValue: store.passphraseController)
        _s3Controller = ObservedObject(wrappedValue: store.s3Controller)
        self.uploadGuard = uploadGuard
        self.onFinished = onFinished
        targetOptions = options.options
        _target = State(initialValue: options.defaultTarget)
    }

    var body: some View {
        NavigationView {
            VStack(spacing: 0) {
                targetField
                Divider()
                MediaSelectionList(store: store, onUpload: uploadTapped, onUploadFinished: onFinished)
            }
            .navigationTitle("Share with Cling Sync")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    SelectAllButton(store: store)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    // Disabled while uploading so dismissal can't delete the staged
                    // files mid-transfer; the bottom bar's Abort stops the upload first.
                    Button("Cancel") { onFinished() }
                        .disabled(store.state.isBusy)
                }
            }
        }
        .task {
            store.shareTarget = target
            store.onStartShare()
        }
        .onChange(of: target) { _, newValue in store.shareTarget = newValue }
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
        .alert("Upload in Progress", isPresented: $showAbortConfirm) {
            Button("Abort & Continue", role: .destructive) {
                Task {
                    await uploadGuard.abortActiveUpload()
                    startUpload()
                }
            }
            Button("Keep Running", role: .cancel) {}
        } message: {
            Text("A background upload is currently running. Abort it to upload the shared files?")
        }
    }

    private var targetField: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Target directory")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                TextField("Repository root", text: $target)
                    .textInputAutocapitalization(.never)
                    .disableAutocorrection(true)
                    .accessibilityIdentifier("Target directory")
                Menu {
                    ForEach(targetOptions, id: \.self) { option in
                        Button(option.isEmpty ? "Repository root" : option) { target = option }
                    }
                } label: {
                    Image(systemName: "chevron.down.circle")
                        .imageScale(.large)
                }
                .disabled(targetOptions.isEmpty)
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.3)))
        }
        .padding([.horizontal, .top])
    }

    private func uploadTapped() {
        if uploadGuard.hasActiveUpload {
            showAbortConfirm = true
        } else {
            startUpload()
        }
    }

    private func startUpload() {
        RecentTargets.record(target)
        store.shareTarget = target
        store.dispatch(.uploadClicked)
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
