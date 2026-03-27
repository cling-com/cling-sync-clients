import SwiftUI

struct PreferencesView: View {
    @ObservedObject var controller: AppController

    var body: some View {
        HSplitView {
            workspaceListPane
            if controller.selectedWorkspaceID != nil {
                workspaceEditorPane
            }
        }
        .onChange(of: controller.draftConfig.hostURL) { _ in controller.handleDraftAccessChange() }
        .onChange(of: controller.draftConfig.localDirectory) { _ in controller.handleDraftAccessChange() }
        .onChange(of: controller.draftConfig.repoPathPrefix) { _ in controller.handleDraftAccessChange() }
        .onChange(of: controller.draftConfig.author) { _ in controller.handleDraftMetadataChange() }
    }

    private var workspaceListPane: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Folders")
                .font(.headline)

            List(selection: selectedWorkspaceBinding) {
                ForEach(controller.workspaceConfigs) { workspace in
                    WorkspaceRow(workspace: workspace)
                        .tag(workspace.id)
                }
            }
            .accessibilityIdentifier("workspaceList")
            .frame(minWidth: 240)

            HStack {
                Button("Remove Folder") {
                    controller.removeSelectedWorkspace()
                }
                .accessibilityIdentifier("removeFolderButton")
                .disabled(controller.selectedWorkspaceID == nil)

                Button("Add Folder") {
                    controller.addWorkspace()
                }
                .accessibilityIdentifier("addFolderButton")

                Spacer()
            }
        }
        .padding(18)
    }

    private var workspaceEditorPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Workspace")
                .font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("Local Folder")
                    HStack {
                        TextField("Local folder", text: $controller.draftConfig.localDirectory)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("localFolderField")
                        Button("Browse...") {
                            controller.chooseLocalDirectory()
                        }
                        .accessibilityIdentifier("browseFolderButton")
                    }
                }
                GridRow {
                    Text("Repository")
                    TextField("Repository URL or path", text: $controller.draftConfig.hostURL)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("serverURLField")
                }
                GridRow {
                    Text("Remote Path")
                    TextField("Remote path prefix", text: $controller.draftConfig.repoPathPrefix)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("remotePathField")
                }
                GridRow {
                    Text("Author")
                    TextField("Commit author", text: $controller.draftConfig.author)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("authorField")
                }
                GridRow {
                    Text("Last Merge")
                    Text(controller.lastMergeLabel(for: controller.draftConfig))
                        .foregroundStyle(.secondary)
                }
            }

            if !controller.errorMessage.isEmpty {
                Text(controller.errorMessage)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Cancel") {
                    controller.closePreferences()
                }
                Button(controller.isTesting ? "Testing..." : "Test") {
                    controller.testDraft()
                }
                .accessibilityIdentifier("testWorkspaceButton")
                .buttonStyle(.borderedProminent)
                .tint(controller.draftNeedsTest ? .blue : .gray)
                .disabled(!controller.canTestDraft)
                Button(controller.isSaving ? "Saving..." : "Save") {
                    controller.saveDraft()
                }
                .accessibilityIdentifier("saveWorkspaceButton")
                .keyboardShortcut(.defaultAction)
                .disabled(!controller.canSaveDraft)
            }
        }
        .padding(18)
        .frame(minWidth: 560)
    }

    private var selectedWorkspaceBinding: Binding<UUID?> {
        Binding(get: { controller.selectedWorkspaceID }, set: { controller.selectWorkspace($0) })
    }
}

private struct WorkspaceRow: View {
    let workspace: WorkspaceConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(workspace.displayName)
                if !workspace.isComplete {
                    Text("Invalid")
                        .foregroundStyle(.red)
                } else if !workspace.isAccessVerified {
                    Text("Needs Test")
                        .foregroundStyle(.orange)
                }
            }
            Text(workspace.detailText)
                .font(.caption)
                .foregroundColor(workspace.isComplete ? .secondary : .red)
                .lineLimit(1)
        }
    }
}
