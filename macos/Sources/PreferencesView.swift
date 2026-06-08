import SwiftUI

struct PreferencesView: View {
    @ObservedObject var store: AppStore

    var body: some View {
        TabView(selection: tabBinding) {
            workspacesTab
                .tabItem { Label("Workspaces", systemImage: "folder") }
                .tag(0)
            optionsTab
                .tabItem { Label("Options", systemImage: "gearshape") }
                .tag(1)
        }
        .frame(minWidth: 820, minHeight: 480)
    }

    private var workspacesTab: some View {
        HSplitView {
            workspaceListPane
            if store.state.selectedWorkspaceID != nil {
                workspaceEditorPane
            }
        }
    }

    private var optionsTab: some View {
        Form {
            Section("Sync") {
                LabeledContent("Sync workers") {
                    Stepper(value: syncWorkersBinding, in: 1...64) {
                        Text("\(store.state.syncWorkers)").monospacedDigit()
                    }
                    .fixedSize()
                    .accessibilityIdentifier("syncWorkersStepper")
                }
                Text(
                    "Number of blocks copied in parallel when syncing a repository to a backup target. "
                        + "Higher values can speed up large syncs over a fast connection."
                )
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Section("Automatic Merge") {
                LabeledContent("Automatically merge") {
                    Picker("Automatically merge", selection: autoMergeIntervalBinding) {
                        Text("Off").tag(0)
                        ForEach(AutoMergePolicy.intervalChoices, id: \.self) { hours in
                            Text(AutoMergePolicy.intervalLabel(hours)).tag(hours)
                        }
                    }
                    .labelsHidden().fixedSize()
                    .accessibilityIdentifier("autoMergeIntervalPicker")
                }
                Text(
                    "Periodically merges every configured folder with its repository in the background, "
                        + "so remote changes arrive without opening the menu. Cling Sync notifies you when "
                        + "changes are merged or if a merge fails, and clicking the notification opens its "
                        + "merge window. A connection problem is retried more often without alerts, and the "
                        + "menu shows \"Merge (failed)\" so you can open the error."
                )
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                Button("Schedule auto merge in 5s") { store.scheduleAutoMergeSoon() }
                    .accessibilityIdentifier("scheduleAutoMergeButton")
                Text("Runs an automatic merge for every folder after a few seconds, to try it out on demand.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }

            Section("Health") {
                LabeledContent("Warn if no merge for") {
                    Picker("Warn if no merge for", selection: notifyStaleDaysBinding) {
                        Text("Off").tag(0)
                        ForEach(AutoMergePolicy.staleDayChoices, id: \.self) { days in
                            Text(AutoMergePolicy.staleDaysLabel(days)).tag(days)
                        }
                    }
                    .labelsHidden().fixedSize()
                    .accessibilityIdentifier("notifyStaleDaysPicker")
                }
                Text(
                    "Sends a notification when a folder has not merged successfully for this long, "
                        + "so a folder that silently stops working does not go unnoticed for days."
                )
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

                Button("Test reminder in 5s") { store.scheduleReminderSoon() }
                    .accessibilityIdentifier("testReminderButton")
                Text("Forces a reminder notification for every configured folder after a few seconds, to test it.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
    }

    private var workspaceListPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Folders").font(.headline).padding(.bottom, 8)

            List(selection: selectedWorkspaceBinding) {
                ForEach(store.state.workspaces) { workspace in
                    WorkspaceRow(config: workspace.config).tag(workspace.id)
                }
            }
            .accessibilityIdentifier("workspaceList")
            .frame(minWidth: 240)

            Divider()

            HStack(spacing: 0) {
                Button {
                    store.dispatch(.addWorkspaceClicked)
                } label: {
                    Image(systemName: "plus").frame(width: 24, height: 24)
                }
                .accessibilityIdentifier("addFolderButton")
                .buttonStyle(.borderless)

                Button {
                    if let id = store.state.selectedWorkspaceID { store.dispatch(.removeWorkspaceClicked(id: id)) }
                } label: {
                    Image(systemName: "minus").frame(width: 24, height: 24)
                }
                .accessibilityIdentifier("removeFolderButton")
                .buttonStyle(.borderless)
                .disabled(store.state.selectedWorkspaceID == nil)

                Spacer()
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
        }
        .padding(18)
    }

    private var workspaceEditorPane: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text("Workspace").font(.headline)

            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 12) {
                GridRow {
                    Text("Local Folder")
                    HStack {
                        TextField("Local folder", text: accessBinding(\.localDirectory))
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("localFolderField")
                        Button("Browse...") { store.dispatch(.chooseLocalDirectoryClicked) }
                            .accessibilityIdentifier("browseFolderButton")
                    }
                }
                GridRow {
                    Text("Repository")
                    TextField("Repository URL or path", text: accessBinding(\.hostURL))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("serverURLField")
                }
                GridRow {
                    Text("Remote Path")
                    TextField("Remote path prefix", text: accessBinding(\.repoPathPrefix))
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("remotePathField")
                }
                GridRow {
                    Text("Author")
                    TextField("Commit author", text: authorBinding)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityIdentifier("authorField")
                }
            }

            if !store.state.errorMessage.isEmpty {
                Text(store.state.errorMessage)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("preferencesErrorMessage")
            }

            if let workspace = store.state.selectedSavedWorkspace, workspace.isConfigured {
                Divider()
                syncTargetsSection(for: workspace)
            }

            Spacer()

            HStack {
                Spacer()
                Button("Cancel") { store.dispatch(.closePreferencesClicked) }
                Button(store.state.isTesting ? "Testing..." : "Test") { store.dispatch(.testDraftClicked) }
                    .accessibilityIdentifier("testWorkspaceButton")
                    .buttonStyle(.borderedProminent)
                    .tint(store.state.draftNeedsTest ? .blue : .gray)
                    .disabled(!store.state.canTestDraft)
                Button("Save") { store.dispatch(.saveDraftClicked(now: Date())) }
                    .accessibilityIdentifier("saveWorkspaceButton")
                    .keyboardShortcut(.defaultAction)
                    .disabled(!store.state.canSaveDraft)
            }
        }
        .padding(18)
        .frame(minWidth: 560)
    }

    private func syncTargetsSection(for workspace: WorkspaceState) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sync Targets").font(.headline)

            Text(
                "Mirror this workspace's repository to one or more backup repositories. "
                    + "Use \"Sync Repository\" from the menu bar to copy it to every target. "
                    + "A target can be a local folder or an s3+https URL that includes its encrypted credentials."
            )
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)

            List(selection: selectedSyncTargetBinding) {
                ForEach(workspace.syncTargets ?? []) { target in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(target.name)
                        Text(target.displayURI).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .tag(target.name)
                }
            }
            .accessibilityIdentifier("syncTargetsList")
            .frame(minHeight: 90, maxHeight: 150)

            HStack(spacing: 0) {
                Button {
                    store.dispatch(.addSyncTargetClicked)
                } label: {
                    Image(systemName: "plus").frame(width: 24, height: 24)
                }
                .accessibilityIdentifier("addSyncTargetButton")
                .buttonStyle(.borderless)

                Button {
                    store.dispatch(.removeSyncTargetClicked)
                } label: {
                    Image(systemName: "minus").frame(width: 24, height: 24)
                }
                .accessibilityIdentifier("removeSyncTargetButton")
                .buttonStyle(.borderless)
                .disabled(store.state.selectedSyncTargetName == nil)

                Spacer()
            }
        }
    }

    // MARK: - Bindings

    private var tabBinding: Binding<Int> {
        Binding(get: { store.state.selectedSettingsTab }, set: { store.dispatch(.settingsTabSelected($0)) })
    }

    private var selectedWorkspaceBinding: Binding<UUID?> {
        Binding(get: { store.state.selectedWorkspaceID }, set: { store.dispatch(.workspaceSelected(id: $0)) })
    }

    private var selectedSyncTargetBinding: Binding<String?> {
        Binding(get: { store.state.selectedSyncTargetName }, set: { store.dispatch(.syncTargetSelected(name: $0)) })
    }

    private var syncWorkersBinding: Binding<Int> {
        Binding(get: { store.state.syncWorkers }, set: { store.dispatch(.syncWorkersChanged($0)) })
    }

    private var autoMergeIntervalBinding: Binding<Int> {
        Binding(get: { store.state.autoMergeIntervalHours }, set: { store.dispatch(.autoMergeIntervalChanged($0)) })
    }

    private var notifyStaleDaysBinding: Binding<Int> {
        Binding(get: { store.state.notifyStaleDays }, set: { store.dispatch(.notifyStaleDaysChanged($0)) })
    }

    // Host/folder/prefix edits invalidate a prior test; author edits do too but via
    // a different event (matching the old handleDraftAccessChange/MetadataChange split).
    private func accessBinding(_ keyPath: WritableKeyPath<WorkspaceConfig, String>) -> Binding<String> {
        Binding(
            get: { store.state.draftConfig[keyPath: keyPath] },
            set: {
                var draft = store.state.draftConfig
                draft[keyPath: keyPath] = $0
                store.dispatch(.draftAccessEdited(draft, now: Date()))
            })
    }

    private var authorBinding: Binding<String> {
        Binding(
            get: { store.state.draftConfig.author },
            set: {
                var draft = store.state.draftConfig
                draft.author = $0
                store.dispatch(.draftMetadataEdited(draft, now: Date()))
            })
    }
}

private struct WorkspaceRow: View {
    let config: WorkspaceConfig

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(config.displayName)
                if !config.isComplete {
                    Text("Invalid").foregroundStyle(.red)
                } else if !config.isAccessVerified {
                    Text("Needs Test").foregroundStyle(.orange)
                }
            }
            Text(config.detailText)
                .font(.caption)
                .foregroundColor(config.isComplete ? .secondary : .red)
                .lineLimit(1)
        }
    }
}
