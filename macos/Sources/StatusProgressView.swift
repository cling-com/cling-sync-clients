import SwiftUI

struct StatusProgressView: View {
    @ObservedObject var controller: AppController
    let workspace: WorkspaceConfig

    private let bottomAnchorID = "status-output-bottom"

    var body: some View {
        let status = controller.statusStatus(for: workspace)
        let showsDetails = controller.statusShowsDetails(for: workspace)
        let isRunning = status.running

        VStack(alignment: .leading, spacing: 16) {
            Text(workspace.displayName)
                .font(.title3)
                .fontWeight(.semibold)

            Text(workspace.normalizedLocalDirectory)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Toggle(
                "Detailed Output",
                isOn: Binding(
                    get: { controller.statusShowsDetails(for: workspace) },
                    set: { controller.setStatusShowsDetails($0, for: workspace) }
                ))

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        if showsDetails {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Output")
                                    .font(.headline)
                                Text(
                                    status.detailedOutput.isEmpty
                                        ? "No detailed output yet." : status.detailedOutput
                                )
                                .font(.system(.body, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Status")
                                    .font(.headline)
                                Text(status.statusMessage.isEmpty ? "Scanning..." : status.statusMessage)
                                    .font(.body.monospacedDigit())
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        if !status.errorMessage.isEmpty {
                            VStack(alignment: .leading, spacing: 6) {
                                Text("Error")
                                    .font(.headline)
                                Text(status.errorMessage)
                                    .foregroundStyle(.red)
                                    .textSelection(.enabled)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }

                        Color.clear
                            .frame(height: 1)
                            .id(bottomAnchorID)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onAppear {
                    scrollToBottom(proxy)
                }
                .onChange(of: status.detailedOutput) { _ in
                    guard showsDetails, status.running else { return }
                    scrollToBottom(proxy)
                }
                .onChange(of: showsDetails) { isShowingDetails in
                    guard isShowingDetails, status.running else { return }
                    scrollToBottom(proxy)
                }
            }

            HStack {
                if isRunning {
                    ProgressView()
                        .controlSize(.small)
                }
                Spacer()
                if status.completed && !controller.mergeStatus(for: workspace).running {
                    Button("Merge") {
                        controller.closeStatusProgressWindow()
                        Task { await controller.startMergeFromMenu(workspace) }
                    }
                }
                Button("Close") {
                    controller.closeStatusProgressWindow()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 640, minHeight: 320)
    }

    private func scrollToBottom(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.15)) {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        }
    }
}
