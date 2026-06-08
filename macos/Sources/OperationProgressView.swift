import SwiftUI

// One progress window for all three operations, projected from the store. The
// per-kind differences (error-label identifier, cancel-button label/id, the
// Status-only Merge button, the empty-state placeholder) are a small switch, not
// a type hierarchy.
struct OperationProgressView: View {
    @ObservedObject var store: AppStore
    let workspaceID: UUID
    let kind: OperationKind

    private var bottomAnchorID: String { "\(kind.rawValue)-output-bottom" }

    var body: some View {
        let workspace = store.state.workspace(workspaceID)
        let operation = workspace?.operation(kind) ?? .idle
        let showsDetails = workspace?.showsDetails(kind) ?? false
        let statusText = operation.statusMessage.isEmpty ? fallbackText(workspace) : operation.statusMessage

        VStack(alignment: .leading, spacing: 16) {
            Text(workspace?.config.displayName ?? "")
                .font(.title3)
                .fontWeight(.semibold)

            Text(workspace?.localPath ?? "")
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Toggle(
                "Detailed Output",
                isOn: Binding(
                    get: { showsDetails },
                    set: { store.dispatch(.detailsToggled(id: workspaceID, kind: kind, show: $0)) }))

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if showsDetails {
                            section(
                                "Output",
                                operation.detailedOutput.isEmpty ? "No detailed output yet." : operation.detailedOutput,
                                monospaced: true)
                        } else {
                            section("Status", statusText, monospaced: false)
                        }
                        if !operation.errorMessage.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Error").font(.headline)
                                Text(operation.errorMessage)
                                    .foregroundStyle(.red)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .accessibilityIdentifier(errorAccessibilityID)
                            }
                        }
                        Color.clear.frame(height: 1).id(bottomAnchorID)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear { scrollToBottom(proxy) }
                .onChange(of: operation.detailedOutput) { _ in
                    guard showsDetails, operation.isRunning else { return }
                    scrollToBottom(proxy)
                }
                .onChange(of: showsDetails) { isShowing in
                    guard isShowing, operation.isRunning else { return }
                    scrollToBottom(proxy)
                }
            }

            HStack {
                if operation.isRunning {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                cancelButton(operation)
                if kind == .status { mergeButton(operation) }
                Button("Close") { store.dispatch(.progressWindowClosed(id: workspaceID, kind: kind)) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 320)
    }

    private func section(_ title: String, _ text: String, monospaced: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            Text(text)
                .font(monospaced ? .system(.body, design: .monospaced) : .body.monospacedDigit())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private func cancelButton(_ operation: OperationState) -> some View {
        Button(cancelTitle) { store.dispatch(.cancelClicked(id: workspaceID, kind: kind)) }
            .accessibilityIdentifier(cancelAccessibilityID)
            .disabled(!operation.isRunning || !operation.canCancel)
    }

    @ViewBuilder
    private func mergeButton(_ operation: OperationState) -> some View {
        let mergeRunning = store.state.workspace(workspaceID)?.merge.isRunning ?? false
        Button("Merge") {
            store.dispatch(.progressWindowClosed(id: workspaceID, kind: .status))
            // Start a merge (don't route through operationClicked, which would re-open
            // a prior failed-merge window instead of starting a new run).
            store.dispatch(
                .operationStartRequested(id: workspaceID, kind: .merge, presentWindow: true, isAutoMerge: false))
        }
        .disabled(!operation.ranSuccessfully || mergeRunning)
    }

    private func fallbackText(_ workspace: WorkspaceState?) -> String {
        switch kind {
        case .merge: return workspace.map { store.state.lastMergeText($0) } ?? "Last Merge: never"
        case .status: return "Scanning..."
        case .sync: return "Preparing sync..."
        }
    }

    private var cancelTitle: String {
        switch kind {
        case .merge: return "Cancel Merge"
        case .status: return "Cancel Status"
        case .sync: return "Abort"
        }
    }

    private var cancelAccessibilityID: String {
        switch kind {
        case .merge: return "cancelMergeButton"
        case .status: return "cancelStatusButton"
        case .sync: return "abortSyncButton"
        }
    }

    private var errorAccessibilityID: String {
        switch kind {
        case .merge: return "mergeErrorMessage"
        case .status: return "statusErrorMessage"
        case .sync: return "syncErrorMessage"
        }
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        }
    }
}
