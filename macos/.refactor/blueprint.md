All citations are verified. I have everything needed to produce the final merged blueprint. The key conflicts to resolve:

1. **OperationState modeling**: All four designs converge on the enum (idle/running/finished(Outcome)). Conflict in `Outcome.completed`: Design 1/3 use `revisionId: String?`, Design 2/4 use `revisionId: String`; Design 2 adds `errorText` to `.failed`. I'll resolve to a single canonical shape.
2. **Tracking state location**: Design 1/3/4 put tracking per-`WorkspaceState`; Design 2 keeps top-level `[String: Date]` dicts. I'll resolve to per-workspace (the stated "collapse the 8 dicts" goal).
3. **Prompts**: Design 1/3/4 use async `Prompter`; Design 2 same. Converged.
4. **autoMergePaths**: resolve to in-AppState `isAutoMerge` per workspace.

Now I'll write the final blueprint as my response.

# macOS MVP Rewrite — Final Implementation Blueprint

Lead-architect merge of the four designs into one ready-to-implement spec. All four were verified against the actual sources (AppController.swift, AutoMerge.swift, AppMenuBuilder.swift, the three ProgressViews, PreferencesView, Bridge.swift, WorkspaceConfig.swift, AutoMergePolicy.swift, the iOS template, build.sh, ios/go/unit_test.go). Every cited line:number was confirmed. Conflicts are resolved with the decision called out inline.

---

## CONFLICTS RESOLVED (read first)

1. **`OperationState.Outcome.completed` shape.** Canonical: `completed(message: String, detail: String, revisionId: String, upToDate: Bool)`. Use `revisionId: String` (empty-string for none, matching Bridge.swift:177 default) not `String?` — the bridge never returns nil, only "", and no call site distinguishes. Status ops set `revisionId: "", upToDate: false`.
2. **`OperationState.Outcome.failed` shape.** Canonical: `failed(message: String, detail: String, isNetwork: Bool)`. Reject Design 2's separate `errorText`: the old code's two strings (a fixed `statusMessage` "Merge failed" + the bridge `errorMessage`) collapse to ONE `message` that carries the user-facing error. The progress window's red error label and the menu's "(failed)" suffix both read `message`/`errorMessage`. For the optimistic-clear path (§Reducer 4.2) the message is the user-facing error text directly (not the fixed "Merge failed"), so the window shows the real reason. The menu suffix "(failed)" is computed from `isFinished(.failed)`, not from the string.
3. **Merge tracking location.** Canonical: per-`WorkspaceState` fields (`lastSuccessfulMerge`, `firstTracked`, `lastStaleNotified`, `inNetworkBackoff`, `isAutoMerge`). Reject Design 2's top-level `[String: Date]` dicts — they reintroduce the exact "8 parallel dicts keyed by path" the rewrite removes. The `SettingsGateway` still serializes them AS path-keyed dicts (the persisted format is unchanged for back-compat), assembling/disassembling at the launch/persist boundary only.
4. **`autoMergePaths` ownership.** Canonical: `WorkspaceState.isAutoMerge: Bool`, written only by the reducer. No store-side set.
5. **`WorkspaceConfig.lastMergeDate` (FS mtime).** Canonical: DELETE it (Bug E). Single source of truth = `WorkspaceState.lastSuccessfulMerge`. NOTE: this is a Metall-free Swift value type, safe to edit. (It is NOT a `.met` file.)
6. **Prompts.** Canonical: async `Prompter` protocol, NOT events. Synchronous `NSAlert.runModal` wrapped in `async` methods (the `async` is a formality on macOS since runModal blocks; it lets the store `await` uniformly).
7. **Window-close on a running op (Bug C).** Canonical: closing a window NEVER mutates `OperationState`; it only removes the `WindowKey` from `state.openWindows`. This fixes the strand for status/sync and aligns all three kinds (merge already didn't purge).

---

## 1. FINAL FILE LAYOUT (one type per file)

New under `/Users/pero/src/pero/cling-sync-clients/macos/Sources/`:

| File | Type(s) | Pure? |
|---|---|---|
| `OperationKind.swift` | `enum OperationKind` | pure |
| `OperationState.swift` | `enum OperationState` + `Outcome` + `from(merge:)`/`from(status:)` | pure |
| `WorkspaceState.swift` | `struct WorkspaceState` | pure |
| `AppState.swift` | `struct AppState` + `DraftState`? (inlined — see note) + `WindowKey` | pure |
| `AppEvent.swift` | `enum AppEvent` | pure |
| `Effect.swift` | `enum Effect`, `enum SettingKey`, `struct Reduction` | pure |
| `WorkUpdate.swift` | `enum WorkUpdate` | pure |
| `AppReducer.swift` | `enum AppReducer` (the big switch) | pure |
| `OperationReducer.swift` | `enum OperationReducer` (per-op fold) | pure |
| `PromptRequest.swift` | `Prompter` protocol + `PromptRequest`/`PromptResult` + result structs | boundary |
| `WorkspaceGateway.swift` | `WorkspaceGateway` protocol + `RealWorkspaceGateway` + `OperationProgress` | boundary |
| `SettingsGateway.swift` | `SettingsGateway` protocol + `UserDefaultsSettingsGateway` + `AppSettings` + `MergeTracking` | boundary |
| `Notifier.swift` | `Notifier` protocol + `UserNotificationsNotifier` + `SilentNotifier` + `NotificationRequest` | boundary |
| `AppStore.swift` | `@MainActor final class AppStore: ObservableObject` + private `Poller` | impure |
| `AppDelegate.swift` | `AppDelegate` (NSApplicationDelegate, UNUserNotificationCenterDelegate) | impure |
| `MenuController.swift` | `MenuController` + `@objc final class MenuActions: NSObject` | impure |
| `MenuSnapshot.swift` | `struct MenuSnapshot` (+ nested `RunningRow`/`WorkspaceMenu`/`ItemState`/`Layout`) | pure |
| `WindowCoordinator.swift` | `WindowCoordinator: NSObject, NSWindowDelegate` | impure |
| `OperationProgressView.swift` | `struct OperationProgressView: View` (replaces all 3) | view |

Rewritten in place:
- `AppMenuBuilder.swift` → `enum AppMenuBuilder { static func build(_ snapshot: MenuSnapshot, actions: MenuActions) -> NSMenu }` (pure projection from a `MenuSnapshot`; no `unowned controller`).
- `PreferencesView.swift` → binds to `store`, dispatches events.
- `Main.swift` → swap `AppController()` for `AppDelegate()` (line 10).

Survive unchanged: `Bridge.swift`, `validateHostURL`+`loginAuthorName` (WorkspaceConfig.swift:3-23), `BridgeError`/`SyncTargetInfo`/`MergeWorkspaceStatus`/`StatusWorkspaceStatus`/`WorkspaceInspection` (Bridge.swift), `AutoMergePolicy.swift`, `TrayIconAnimator.swift`.

Edited: `WorkspaceConfig.swift` (delete `lastMergeDate`, WorkspaceConfig.swift:166-172).

Deleted in the final step: `AppController.swift`, `AutoMerge.swift`, `MergeProgressView.swift`, `StatusProgressView.swift`, `SyncProgressView.swift`, `S3CredentialsPrompt.swift` (its body folds into `AppKitPrompter.s3Credentials`). NOTE: the existing `struct PassphrasePromptResult` at AppController.swift:5-8 must be deleted when its `Equatable` twin lands in `PromptRequest.swift`.

**Decision on `DraftState`:** Design 4 proposed a `DraftState` sub-struct; Designs 1/2/3 inline draft fields on `AppState`. Canonical: INLINE on `AppState` (`draftConfig`, `isSaving`, `isTesting`, `errorMessage`) — matches the old controller and iOS, and `canSave`/`canTest`/`draftNeedsTest` need both `draftConfig` and `isSaving`/`isTesting` so a sub-struct would split the inputs.

---

## 2. COMPILABLE CORE TYPES

### `OperationKind.swift`
```swift
import Foundation

enum OperationKind: String, CaseIterable, Equatable {
    case merge, status, sync

    // The progress-window title suffix: "<name> Merge" etc. (AppController.swift:360/457/1639).
    var windowTitleSuffix: String {
        switch self {
        case .merge: return "Merge"
        case .status: return "Status"
        case .sync: return "Sync"
        }
    }

    // The running-tooltip label and menu running-row label (AppController.swift:268-270).
    var label: String {
        switch self {
        case .merge: return "Merge"
        case .status: return "Status"
        case .sync: return "Sync"
        }
    }

    // "Merge (in progress)" etc. (AppController.swift:215/219/221).
    var runningLabel: String { "\(label) (in progress)" }

    // The NSAlert title for a manual terminal failure (AppController.swift:1006/1194/1506).
    var failureAlertTitle: String { "\(label) Failed" }
}
```

### `OperationState.swift`
```swift
import Foundation

// One workspace operation's lifecycle, unifying the two bridge flag-structs
// (MergeWorkspaceStatus / StatusWorkspaceStatus, Bridge.swift:35-57). An enum so
// illegal combos (running AND completed) are unrepresentable and a terminal phase
// can be made sticky against a late empty poll (Bug B).
enum OperationState: Equatable {
    case idle
    case running(message: String, detail: String, canCancel: Bool)
    case finished(Outcome)

    enum Outcome: Equatable {
        case completed(message: String, detail: String, revisionId: String, upToDate: Bool)
        case cancelled(message: String, detail: String)
        case failed(message: String, detail: String, isNetwork: Bool)
    }

    var isRunning: Bool { if case .running = self { return true }; return false }
    var isFinished: Bool { if case .finished = self { return true }; return false }
    var isTerminalFailure: Bool { if case .finished(.failed) = self { return true }; return false }
    var canCancel: Bool { if case .running(_, _, let c) = self { return c }; return false }

    // The live one-liner for menu/window header/testStatusLabel. Empty for idle.
    var statusMessage: String {
        switch self {
        case .idle: return ""
        case .running(let m, _, _): return m
        case .finished(.completed(let m, _, _, _)): return m
        case .finished(.cancelled(let m, _)): return m
        case .finished(.failed(let m, _, _)): return m
        }
    }

    var detailedOutput: String {
        switch self {
        case .idle: return ""
        case .running(_, let d, _): return d
        case .finished(.completed(_, let d, _, _)): return d
        case .finished(.cancelled(_, let d)): return d
        case .finished(.failed(_, let d, _)): return d
        }
    }

    // Non-empty only in the terminal failed state; drives the red error label
    // and the "(failed)" menu suffix.
    var errorMessage: String {
        if case .finished(.failed(let m, _, _)) = self { return m }
        return ""
    }
}

extension OperationState {
    // Maps a merge/sync bridge snapshot (Bridge.swift:35-47). running wins over
    // completed; completed+error -> .failed, completed+cancelled -> .cancelled.
    static func from(merge s: MergeWorkspaceStatus) -> OperationState {
        if s.running {
            return .running(message: s.statusMessage, detail: s.detailedOutput, canCancel: s.canCancel)
        }
        if s.completed {
            if !s.errorMessage.isEmpty {
                return .finished(.failed(message: s.errorMessage, detail: s.detailedOutput, isNetwork: s.errorIsNetwork))
            }
            if s.cancelled {
                return .finished(.cancelled(message: s.statusMessage, detail: s.detailedOutput))
            }
            return .finished(.completed(
                message: s.statusMessage, detail: s.detailedOutput, revisionId: s.revisionId, upToDate: s.upToDate))
        }
        return .idle
    }

    // Status snapshots have no revisionId/upToDate and no errorIsNetwork
    // (Bridge.swift:49-57), so failures are isNetwork:false.
    static func from(status s: StatusWorkspaceStatus) -> OperationState {
        if s.running {
            return .running(message: s.statusMessage, detail: s.detailedOutput, canCancel: s.canCancel)
        }
        if s.completed {
            if !s.errorMessage.isEmpty {
                return .finished(.failed(message: s.errorMessage, detail: s.detailedOutput, isNetwork: false))
            }
            if s.cancelled {
                return .finished(.cancelled(message: s.statusMessage, detail: s.detailedOutput))
            }
            return .finished(.completed(message: s.statusMessage, detail: s.detailedOutput, revisionId: "", upToDate: false))
        }
        return .idle
    }
}
```

### `WorkspaceState.swift`
```swift
import Foundation

// All state for one folder<->repo workspace, collapsing the 8 per-path dicts
// (AppController.swift:30-37,70-74,77) into one Equatable value keyed inside
// AppState by `id`.
struct WorkspaceState: Equatable, Identifiable {
    var config: WorkspaceConfig
    var id: UUID { config.id }

    var merge: OperationState = .idle
    var status: OperationState = .idle
    var sync: OperationState = .idle

    var mergeShowsDetails: Bool = false
    var statusShowsDetails: Bool = false
    var syncShowsDetails: Bool = false

    // nil = sync targets not yet read (the old isWorkspaceConfigured nil-vs-present
    // sentinel, AppController.swift:1346-1348). [] = read, configured, no targets.
    var syncTargets: [SyncTargetInfo]?

    // Single source of truth for "last merge" (replaces the FS-mtime lastMergeDate
    // AND lastSuccessfulMergeByPath, Bug E).
    var lastSuccessfulMerge: Date?
    var firstTracked: Date?          // staleness clock for a never-merged folder
    var lastStaleNotified: Date?

    var inNetworkBackoff: Bool = false   // last auto-merge hit a connectivity error
    var isAutoMerge: Bool = false        // current merge was scheduler-started -> notify, not alert

    var localPath: String { config.normalizedLocalDirectory }

    func operation(_ kind: OperationKind) -> OperationState {
        switch kind {
        case .merge: return merge
        case .status: return status
        case .sync: return sync
        }
    }

    func showsDetails(_ kind: OperationKind) -> Bool {
        switch kind {
        case .merge: return mergeShowsDetails
        case .status: return statusShowsDetails
        case .sync: return syncShowsDetails
        }
    }

    mutating func setOperation(_ kind: OperationKind, _ value: OperationState) {
        switch kind {
        case .merge: merge = value
        case .status: status = value
        case .sync: sync = value
        }
    }

    mutating func setShowsDetails(_ kind: OperationKind, _ value: Bool) {
        switch kind {
        case .merge: mergeShowsDetails = value
        case .status: statusShowsDetails = value
        case .sync: syncShowsDetails = value
        }
    }

    var isBusy: Bool { merge.isRunning || status.isRunning || sync.isRunning }

    // merge > sync > status priority (AppController.swift:214-222).
    var runningKind: OperationKind? {
        if merge.isRunning { return .merge }
        if sync.isRunning { return .sync }
        if status.isRunning { return .status }
        return nil
    }

    var activeOperationLabel: String? { runningKind?.runningLabel }
    var isConfigured: Bool { syncTargets != nil }
    var lastMergeReference: Date? { lastSuccessfulMerge ?? firstTracked }
}
```

### `AppState.swift`
```swift
import Foundation

// A window the projection should keep open. Closing one removes the key but
// NEVER touches OperationState (Bug C fix).
struct WindowKey: Hashable, Equatable {
    let workspaceID: UUID
    let kind: OperationKind
}

// The whole menu-bar app as one immutable Equatable value. No AppKit, no bridge,
// no clock. Every menu/tray/window/preferences value is stored here or computed.
struct AppState: Equatable {
    var workspaces: [WorkspaceState] = []
    var selectedWorkspaceID: UUID?
    var draftConfig: WorkspaceConfig = WorkspaceConfig()
    var selectedSyncTargetName: String?

    var syncWorkers: Int = 2
    var autoMergeIntervalHours: Int = 0
    var notifyStaleDays: Int = 0
    var selectedSettingsTab: Int = 0

    var isSaving: Bool = false
    var isTesting: Bool = false
    var lastResultMessage: String = ""
    var errorMessage: String = ""

    // The projection's desired-open set (drives WindowCoordinator) + whether the
    // preferences window is open.
    var openWindows: Set<WindowKey> = []
    var preferencesOpen: Bool = false

    // MARK: - Lookup
    func workspace(_ id: UUID) -> WorkspaceState? { workspaces.first { $0.id == id } }
    func index(_ id: UUID) -> Int? { workspaces.firstIndex { $0.id == id } }
    var selectedSavedWorkspace: WorkspaceState? {
        guard let selectedWorkspaceID else { return nil }
        return workspace(selectedWorkspaceID)
    }

    // MARK: - Running (AppController.swift:198-282)
    var hasActiveMerges: Bool { workspaces.contains { $0.merge.isRunning } }
    var hasActiveStatuses: Bool { workspaces.contains { $0.status.isRunning } }
    var hasActiveSyncs: Bool { workspaces.contains { $0.sync.isRunning } }
    var anyOperationRunning: Bool { workspaces.contains { $0.isBusy } }
    func hasRunning(_ kind: OperationKind) -> Bool { workspaces.contains { $0.operation(kind).isRunning } }

    var runningOperationLabels: [String] {
        var labels: [String] = []
        for ws in workspaces {
            if ws.merge.isRunning { labels.append(OperationKind.merge.label) }
            if ws.sync.isRunning { labels.append(OperationKind.sync.label) }
            if ws.status.isRunning { labels.append(OperationKind.status.label) }
        }
        return labels
    }

    var trayTooltip: String {
        let labels = runningOperationLabels
        switch labels.count {
        case 0: return "Cling Sync"
        case 1: return "\(labels[0]) in progress"
        default: return "\(labels.count) operations in progress"
        }
    }

    // Mirrors updateStatusMessage precedence exactly (AppController.swift:325-345).
    // hasActiveMerges replaces the old stored isMerging (which was always = hasActiveMerges).
    var statusMessage: String {
        if let ws = workspaces.first(where: { $0.merge.isRunning }) {
            let text = ws.merge.statusMessage.isEmpty ? lastMergeText(ws) : ws.merge.statusMessage
            return "\(ws.config.displayName): \(text)"
        }
        if hasActiveMerges { return "Merging..." }
        if isTesting { return "Testing..." }
        if isSaving { return "Saving workspace..." }
        if !lastResultMessage.isEmpty { return lastResultMessage }
        if workspaces.isEmpty { return "Setup required" }
        if workspaces.count == 1, let ws = workspaces.first { return ws.config.displayName }
        return "\(workspaces.count) folders"
    }

    // The "Last Merge: 5m ago"/"never" text (AppMenuBuilder.swift:127-131,
    // MergeProgressView.swift:14). Reads lastSuccessfulMerge only (Bug E).
    func lastMergeText(_ ws: WorkspaceState) -> String {
        guard let date = ws.lastSuccessfulMerge else { return "Last Merge: never" }
        return "Last Merge: \(AutoMergePolicy.coarseAge(Date().timeIntervalSince(date))) ago"
    }

    // MARK: - Draft gates (AppController.swift:186-196)
    var canSaveDraft: Bool {
        selectedWorkspaceID != nil && draftConfig.isValidForSave && !isSaving && !isTesting
    }
    var canTestDraft: Bool {
        selectedWorkspaceID != nil && draftConfig.isReadyForTest && !isSaving && !isTesting
    }
    var draftNeedsTest: Bool {
        selectedWorkspaceID != nil && draftConfig.isReadyForTest && !draftConfig.isAccessVerified
    }

    // MARK: - Auto-merge
    var autoMergeBackoffActive: Bool { workspaces.contains { $0.inNetworkBackoff } }
}
```
> `lastMergeText` uses `Date()` — acceptable because it's a *display* helper read by the projection, never by the reducer. The reducer never calls it. (The pure-purity invariant only constrains `reduce`.) If a test needs determinism on this label it asserts on `ws.lastSuccessfulMerge` directly.

### `WorkUpdate.swift`
```swift
import Foundation

// A normalized poll/start signal. The store maps a bridge poll (via
// OperationState.from) into one of these so the reducer never sees the transport
// flag-structs. `absent` is the old "filtered out / empty row" case
// (AppController.swift:1137/1282/1598); the reducer keeps a terminal state on it (Bug B).
enum WorkUpdate: Equatable {
    case snapshot(OperationState)
    case absent
}
```

### `Effect.swift`
```swift
import Foundation

enum SettingKey: String, Equatable {
    case syncWorkers, autoMergeIntervalHours, notifyStaleDays, selectedSettingsTab
}

// A side effect the reducer requests and the store performs. Data, not calls, so
// the reducer is pure and assertable (test inspects reduction.effects, no IO runs).
// Workspace-scoped effects carry the id.
enum Effect: Equatable {
    // Persistence
    case persistWorkspaces
    case persistMergeTracking
    case persistSetting(SettingKey, Int)

    // Operations (store runs the bridge start incl. passphrase prompts, then polls)
    case startOperation(id: UUID, kind: OperationKind, isAutoMerge: Bool)
    case cancelOperation(id: UUID, kind: OperationKind)
    case beginPolling(OperationKind)

    // Test / save flow (store orchestrates Prompter + gateway, dispatches terminal events)
    case runTestDraft(WorkspaceConfig)
    case chooseLocalDirectory

    // Sync targets
    case loadSyncTargets(id: UUID)
    case promptAndAddSyncTarget(id: UUID)
    case removeSyncTarget(id: UUID, name: String)

    // Repository/keychain teardown + directory access
    case clearWorkspacePassphrase(uri: String)
    case activateDirectoryAccess(WorkspaceConfig)
    case deactivateDirectoryAccess(path: String)

    // Timers (store owns the Timer handles; the decision is pure)
    case rescheduleAutoMerge
    case rescheduleStaleCheck

    // UI side effects
    case postNotification(id: UUID, title: String, body: String)
    case showAlert(title: String, message: String)
    case showProgressWindow(id: UUID, kind: OperationKind)
    case closeProgressWindow(id: UUID, kind: OperationKind)
    case showPreferences
    case closePreferences
    case openLocalFolder(path: String)
    case quit
}

struct Reduction: Equatable {
    var state: AppState
    var effects: [Effect] = []
    static func only(_ state: AppState) -> Reduction { Reduction(state: state) }
}
```

### `AppEvent.swift`
```swift
import Foundation

// Flat enum; workspace-scoped cases carry the id (store resolves it before reducing).
// Prompts are NOT events: the store runs the Prompter, then dispatches the
// resulting completion event. Events that write a timestamp carry `now: Date`
// (keeps the reducer clock-free).
enum AppEvent: Equatable {
    // Launch
    case stateLoaded(workspaces: [WorkspaceConfig], tracking: MergeTracking, settings: AppSettings, now: Date)

    // Workspace list
    case addWorkspaceClicked
    case workspaceSelected(id: UUID?)
    case removeWorkspaceClicked(id: UUID)

    // Preferences / draft
    case draftAccessEdited(WorkspaceConfig, now: Date)     // host/path/prefix edited (912-917)
    case draftMetadataEdited(WorkspaceConfig, now: Date)   // author edited (919-922)
    case chooseLocalDirectoryClicked
    case chooseLocalDirectoryCompleted(draft: WorkspaceConfig, inspectionError: String?, now: Date)
    case settingsTabSelected(Int)
    case syncTargetSelected(name: String?)
    case openPreferencesClicked
    case closePreferencesClicked

    // Test / save
    case testDraftClicked
    case testDraftStarted
    case testDraftSucceeded(verified: WorkspaceConfig, now: Date)
    case testDraftCancelled
    case testDraftFailed(message: String)
    case saveDraftClicked(now: Date)

    // Operations
    case operationClicked(id: UUID, kind: OperationKind)       // menu/host: open-window-or-start
    case operationStartRequested(id: UUID, kind: OperationKind, presentWindow: Bool)  // optimistic running
    case operationStartFailed(id: UUID, kind: OperationKind, message: String, isNetwork: Bool, isAutoMerge: Bool)
    case cancelClicked(id: UUID, kind: OperationKind)
    case workUpdated(id: UUID, kind: OperationKind, update: WorkUpdate, now: Date)
    case detailsToggled(id: UUID, kind: OperationKind, show: Bool)
    case progressWindowClosed(id: UUID, kind: OperationKind)

    // Sync targets
    case syncTargetsLoaded(id: UUID, targets: [SyncTargetInfo]?)
    case addSyncTargetClicked
    case syncTargetAdded(id: UUID)
    case removeSyncTargetClicked
    case syncTargetRemoved(id: UUID)
    case syncTargetActionFailed(title: String, message: String)

    // Settings
    case syncWorkersChanged(Int)
    case autoMergeIntervalChanged(Int)
    case notifyStaleDaysChanged(Int)

    // Timers
    case autoMergeTimerFired(now: Date)
    case staleCheckTimerFired(now: Date)

    // App
    case quitClicked
}
```

---

## 3. AppReducer TRANSITION TABLE

`AppReducer.reduce(_ state: AppState, _ event: AppEvent) -> Reduction` — pure, no IO/AppKit/clock. The store resolves `id -> WorkspaceState` and threads `now`. Group helpers (`upsert`, `recordSuccessfulMerge`, `forgetMergeTracking`, `ensureMergeTracking`, `setNetworkBackoff`) are private static funcs returning `(AppState, [Effect])`. Each row cites the AppController/AutoMerge line(s) it replaces.

### Launch / preferences
| Event | State change | Effects | Cites |
|---|---|---|---|
| `stateLoaded` | build `workspaces` from configs; apply `tracking` per-workspace; set settings ints; run `ensureMergeTracking(now)`; run `selectInitialWorkspace` then `updateDraftFromSelection` | `[loadSyncTargets per ws], rescheduleAutoMerge, rescheduleStaleCheck` + `showPreferences` if empty + persistMergeTracking if ensure changed | 105-124, 236-238, 242-244 |
| `openPreferencesClicked` | if `workspaces.isEmpty`: append fresh `WorkspaceState(config: WorkspaceConfig())`, select it, set draft; else run `updateDraftFromSelection`; `preferencesOpen = true` | `persistWorkspaces` (only if seeded) + `loadSyncTargets(selected)` + `showPreferences` | 378-407 |
| `closePreferencesClicked` | run `updateDraftFromSelection`; `preferencesOpen = false` | `closePreferences` | 409-416 |
| `settingsTabSelected(t)` | `selectedSettingsTab = t` | `persistSetting(.selectedSettingsTab, t)` | 57 |

`selectInitialWorkspace`: keep current selection if still present, else `workspaces.first?.id` (894-899). `updateDraftFromSelection`: draft = selected config, backfilling empty author with `loginAuthorName`; else `WorkspaceConfig()` (901-910).

### Selection / draft
| Event | State change | Effects | Cites |
|---|---|---|---|
| `workspaceSelected(id)` | `selectedWorkspaceID = id`; `selectedSyncTargetName = nil`; `updateDraftFromSelection`; `errorMessage = ""` | `loadSyncTargets(id)` if a saved ws with id exists | 539-547 |
| `draftAccessEdited(d, now)` | `draftConfig = d`; if `d.verifiedAccessSignature != d.accessSignature` then clear it; run `updateDraftInList(now)` | `persistWorkspaces` + persistMergeTracking if ensure changed | 912-917, 924-934 |
| `draftMetadataEdited(d, now)` | `draftConfig = d`; clear `verifiedAccessSignature`; run `updateDraftInList(now)` | same | 919-922 |
| `chooseLocalDirectoryClicked` | none | `chooseLocalDirectory` | 488 (store-side panel+inspect) |
| `chooseLocalDirectoryCompleted(d, err, now)` | `draftConfig = d`; `errorMessage = err ?? ""`; run `updateDraftInList(now)` | `persistWorkspaces`; `loadSyncTargets(d.id)` if inspection found a repo | 488-526 |
| `syncTargetSelected(name)` | `selectedSyncTargetName = name` | — | view binding |

`updateDraftInList(now)`: if selected ws matches `draftConfig.id`, replace its `config`, run `ensureMergeTracking(now)`, emit `persistWorkspaces`; else no-op (924-934). **Bug A2: this NEVER clears keychain/tracking** — only `removeWorkspaceClicked` and `upsert`-on-identity-change do.

### Add / remove / upsert
| Event | State change | Effects | Cites |
|---|---|---|---|
| `addWorkspaceClicked` | `errorMessage=""`; append fresh ws; select it; `draftConfig=`it | `persistWorkspaces, showPreferences` | 528-537 |
| `removeWorkspaceClicked(id)` | if ws found: `forgetMergeTracking(path)` in-state; remove the `WorkspaceState`; if it was selected run `selectInitialWorkspace`+`updateDraftFromSelection`; `lastResultMessage="Folder removed"` | `clearWorkspacePassphrase(removed.config.bridgeRepositoryURI)`, `deactivateDirectoryAccess(path)`, `persistMergeTracking`, `rescheduleAutoMerge` (only if backoff flag flipped), `persistWorkspaces`, `showPreferences` if now empty | 554-576 |

`upsert(config, now)` (private; called by `testDraftSucceeded` and `saveDraftClicked`): if a ws with `config.id` exists and `previous.normalizedLocalDirectory != config.normalizedLocalDirectory || previous.bridgeRepositoryURI != config.bridgeRepositoryURI`, then `forgetMergeTracking(previous.path)` + emit `clearWorkspacePassphrase(previous.bridgeRepositoryURI)` + reset that ws's `merge=.idle, mergeShowsDetails=false` (only merge, matching 957-958); set `config`. Else if new id append. Then `ensureMergeTracking(now)`, `selectedWorkspaceID=config.id`, `draftConfig=config`, emit `persistWorkspaces`. (949-968)

### Test / save
| Event | State change | Effects | Cites |
|---|---|---|---|
| `testDraftClicked` | guard `canTestDraft` else no-op; `errorMessage=""`; `config=normalizedDraftConfig`; if `validateHostURL(config.normalizedHostURL) != nil` set `errorMessage`+stop; else `isTesting=true` | `runTestDraft(config)` (the store runs the file/S3 + Prompter flow) | 578-607 |
| `testDraftSucceeded(verified, now)` | `var v=verified; v.verifiedAccessSignature=v.accessSignature`; `upsert(v, now)`; `draftConfig=v`; `isTesting=false`; `lastResultMessage="Tested \(v.displayName)"` | upsert effects + `loadSyncTargets(v.id)` | 741-750 |
| `testDraftCancelled` | `isTesting=false` | — | 597-600 |
| `testDraftFailed(msg)` | `isTesting=false`; `errorMessage=msg` | — | 601-605 |
| `saveDraftClicked(now)` | guard `!isSaving`; `errorMessage=""`; `config=normalizedDraftConfig`; if `validateHostURL != nil` set err+stop; else `upsert(config, now)` inline; `lastResultMessage="Saved \(config.displayName)"` | upsert effects + `closePreferences` | 752-770 |

> **`isSaving` transient dropped** (Design 2/4 §10 resolution): old `Task { upsert; isSaving=false }` never showed `true` to the user. `saveDraftClicked` does upsert synchronously. No two-phase split.
> `normalizedDraftConfig` (936-947) is pure; compute it inside the reducer from `draftConfig`.

### Operations (the heart — parameterized by kind)
| Event | State change | Effects | Cites |
|---|---|---|---|
| `operationClicked(id, kind)` | none (routing only) | the store/MenuActions decides open-vs-start; see §4. (This event exists so the host menu can dispatch it; for direct in-window starts the store calls `beginOperation`.) | 1739-1772 |
| `operationStartRequested(id, kind, presentWindow)` | guard `ws.isBusy` -> no-op (mutual exclusion); else `lastResultMessage=""` (merge/sync only, 1019/1521); set `ws.op(kind)=.running(prepMessage(kind), "", canCancel:true)`; if auto-merge mark `ws.isAutoMerge=true` (carried via `startOperation` isAutoMerge); add `WindowKey` to `openWindows` if `presentWindow` | `startOperation(id, kind, isAutoMerge)`; `showProgressWindow(id,kind)` if presentWindow | 992-993,1018-1036; 1180-1218; 1488-1535 |
| `operationStartFailed(id, kind, message, isNetwork, isAutoMerge)` | set `ws.op(kind)=.finished(.failed(message, "", isNetwork))`; if `isAutoMerge`: `ws.isAutoMerge=false`, run `setNetworkBackoff(isNetwork, ws)`; | if `isAutoMerge && !isNetwork` -> `postNotification(id, "Automatic merge failed", message)`; if `isAutoMerge` and backoff flag flipped -> `rescheduleAutoMerge`; if `!isAutoMerge` -> `showAlert(kind.failureAlertTitle, message)` | 1046-1063,1226-1240,1544-1559; AutoMerge:73-75,98-104 |
| `cancelClicked(id, kind)` | none (cancel is async; terminal `.cancelled` arrives via poll) | `cancelOperation(id, kind)` | 1067-1081,1244-1258,1564-1578 |
| `workUpdated(id, kind, update, now)` | **see fold rule below (Bug B)** | see routing below | 1127-1176,1272-1313,1588-1631 |
| `detailsToggled(id, kind, show)` | `ws.setShowsDetails(kind, show)` | — | 802-804,823-825,1480-1482 |
| `progressWindowClosed(id, kind)` | remove `WindowKey(id,kind)` from `openWindows`. **NEVER touch `ws.op(kind)`** (Bug C fix) | `closeProgressWindow(id, kind)` | 445-449 (merge model, now applied to all 3) |

`prepMessage`: merge `"Preparing merge..."` (1026), status `"Scanning workspace..."` (1212), sync `"Preparing sync..."` (1528).

**`workUpdated` fold (Bug B + completion routing):** let `prev = ws.op(kind)`.
1. If `update == .absent`: if `prev.isFinished` KEEP `prev` (return `.only(state)`, no routing); else set `ws.op(kind)=.idle`. (Fixes the dropped terminal-row bug, 1137-1156.)
2. Else `update == .snapshot(next)`. If `next == .idle && prev.isTerminalFailure`: keep `prev`. Else set `ws.op(kind)=next`.
3. **Routing** fires only on transition into terminal: `prev.isRunning || prev.statusMessage != next.statusMessage` AND `next.isFinished` (1162/1304/1622). When it fires:
   - **merge**: if `next` is `.completed` (any `upToDate`) -> `recordSuccessfulMerge(ws, now)` (sets `lastSuccessfulMerge=now`, clears `lastStaleNotified`, `setNetworkBackoff(false)`; emit `persistMergeTracking` + reschedule-if-flipped) (1163-1165). Then if `ws.isAutoMerge`: set `ws.isAutoMerge=false` and run `handleAutoMergeCompletion`: `.failed` -> `reportAutoMergeFailure`; `.cancelled` or `.completed(upToDate:true)` -> silent; `.completed(upToDate:false)` -> `postNotification(id,"Automatic merge complete","\(name): \(message)")` (AutoMerge:81-93). Else if `next` is `.failed` -> `showAlert("Merge Failed", next.errorMessage)` (1168-1169). `lastResultMessage="\(name): \(next.statusMessage)"` (1171).
   - **status**: if `next` is `.failed` -> `showAlert("Status Failed", errorMessage)` (1305-1306). `lastResultMessage=...` (1308). No merge tracking.
   - **sync**: if `next` is `.failed` -> `showAlert("Sync Failed", errorMessage)` (1623-1624). `lastResultMessage=...` (1626). No merge tracking.

`reportAutoMergeFailure(ws, message, isNetwork)` (AutoMerge:98-104): `setNetworkBackoff(isNetwork, ws)`; if `isNetwork` silent; else `postNotification(id,"Automatic merge failed",message)`.

`setNetworkBackoff(active, ws)` (AutoMerge:27-37): `wasActive = state.autoMergeBackoffActive`; set `ws.inNetworkBackoff=active`; if `state.autoMergeBackoffActive != wasActive` emit `rescheduleAutoMerge`.

### Sync targets
| Event | State change | Effects | Cites |
|---|---|---|---|
| `syncTargetsLoaded(id, targets)` | `ws.syncTargets = targets` (nil on bridge error) | — | 1321-1336 |
| `addSyncTargetClicked` | guard `selectedSavedWorkspace != nil` | `promptAndAddSyncTarget(selected.id)` | 1350-1353 |
| `syncTargetAdded(id)` | none | `loadSyncTargets(id)` | 1363/1372 |
| `removeSyncTargetClicked` | guard selected ws + `selectedSyncTargetName` names an existing target | `removeSyncTarget(selected.id, name)` | 1396-1400 |
| `syncTargetRemoved(id)` | `selectedSyncTargetName = nil` | `loadSyncTargets(id)` | 1408-1409 |
| `syncTargetActionFailed(title, msg)` | none | `showAlert(title, msg)` | 1376-1384,1411-1413 |

### Settings
| Event | State change | Effects | Cites |
|---|---|---|---|
| `syncWorkersChanged(v)` | `syncWorkers=v` | `persistSetting(.syncWorkers, v)` | 38-40 |
| `autoMergeIntervalChanged(v)` | guard `v != autoMergeIntervalHours`; set it; clear all `inNetworkBackoff` | `persistSetting(.autoMergeIntervalHours,v), rescheduleAutoMerge` | 41-49 |
| `notifyStaleDaysChanged(v)` | guard `v != notifyStaleDays`; set it | `persistSetting(.notifyStaleDays,v), rescheduleStaleCheck` | 50-56 |

### Timers
| Event | State change | Effects | Cites |
|---|---|---|---|
| `autoMergeTimerFired(now)` | for each ws with `config.isComplete && !ws.isBusy`: set `ws.isAutoMerge=true` | one `startOperation(id, .merge, isAutoMerge:true)` per picked ws (store starts with presentWindow:false) | AutoMerge:58-77 |
| `staleCheckTimerFired(now)` | guard `notifyStaleDays>0`; for each ws with `config.isComplete && !path.isEmpty`: `reference = lastSuccessfulMerge ?? firstTracked ?? now`; if `AutoMergePolicy.isStale(reference, notifyStaleDays, now)` and not throttled (`lastStaleNotified == nil || now-it >= secondsPerDay`): set `ws.lastStaleNotified=now` | `postNotification(id,"Merge overdue","\(name) has not merged successfully for \(n) day(s) or more.")` per notified ws; `persistMergeTracking` if any | AutoMerge:119-146 |

### App
| Event | Effects | Cites |
|---|---|---|
| `quitClicked` | `quit` | 1787 |

`ensureMergeTracking(now)` (149-161): for each `config.isComplete` ws with empty `firstTracked` and non-empty path, set `firstTracked=now`; emit `persistMergeTracking` if changed.

---

## 4. STORE / GATEWAYS / PROMPTER / PROJECTION

### `AppStore.swift`
```swift
@MainActor
final class AppStore: ObservableObject {
    @Published private(set) var state: AppState

    private let gateway: WorkspaceGateway
    private let settings: SettingsGateway
    private let prompter: Prompter
    private let notifier: Notifier
    private let clock: () -> Date
    private let isTestMode: Bool

    private let mergePoller = Poller()
    private let statusPoller = Poller()
    private let syncPoller = Poller()
    private var autoMergeTimer: Timer?
    private var staleCheckTimer: Timer?
    private var manualAutoMergeTimer: Timer?
    private var directoryAccessURLs: [String: URL] = [:]   // 96-99, 851-880 verbatim
    private var connectTasks: [UUID: Task<Void, Never>] = [:]   // superseding test/connect flows

    init(gateway: WorkspaceGateway = RealWorkspaceGateway(),
         settings: SettingsGateway = UserDefaultsSettingsGateway(),
         prompter: Prompter = AppKitPrompter(),
         notifier: Notifier = UserNotificationsNotifier(),
         clock: @escaping () -> Date = { Date() },
         isTestMode: Bool = ProcessInfo.processInfo.environment["CLING_SYNC_TEST_MENU_HOST"] == "1") { ... }

    func dispatch(_ event: AppEvent) {
        let reduction = AppReducer.reduce(state, event)
        state = reduction.state                 // single assignment -> one objectWillChange -> one projection
        for effect in reduction.effects { run(effect) }
    }

    func onStart() {                            // launch orchestration (NOT a reducer event)
        let configs = settings.loadWorkspaceConfigs()
        for c in configs { activateDirectoryAccess(for: c) }   // 851-855
        dispatch(.stateLoaded(workspaces: configs, tracking: settings.loadTracking(),
                              settings: settings.loadAppSettings(), now: clock()))
        if isTestMode { /* AppDelegate shows the host window */ }
    }

    private func run(_ effect: Effect) { switch effect { /* maps each Effect to a method */ } }
}
```

**`run(_:)` mapping (every case):** `persistWorkspaces` -> `settings.saveWorkspaceConfigs(state.workspaces.map(\.config))`; `persistMergeTracking` -> `settings.saveTracking(MergeTracking(from: state.workspaces))`; `persistSetting` -> `settings.saveSetting`; `startOperation` -> `startOperation(...)`; `cancelOperation` -> async cancel then `beginPolling`; `beginPolling` -> `beginPolling(kind)`; `runTestDraft` -> `runTestDraft(config)`; `chooseLocalDirectory` -> panel+inspect then dispatch `chooseLocalDirectoryCompleted`; `loadSyncTargets` -> async list, dispatch `syncTargetsLoaded`; `promptAndAddSyncTarget`/`removeSyncTarget` -> prompt+bridge then dispatch; `clearWorkspacePassphrase` -> `Task.detached { try? Bridge.clearWorkspacePassphrase }`; `activate/deactivateDirectoryAccess` -> 857-880 verbatim; `rescheduleAutoMerge`/`rescheduleStaleCheck` -> timer scheduling (below); `postNotification` -> `notifier.post`; `showAlert` -> `await prompter.alert`; `showProgressWindow`/`closeProgressWindow`/`showPreferences`/`closePreferences` -> these are *already reflected in `state.openWindows`/`preferencesOpen`*, so the **`WindowCoordinator` handles them off `$state`** — these effects are no-ops in `run` OR (cleaner) are dropped and the coordinator diffs `state.openWindows`. **Decision: drop the four window effects from `Effect`; the coordinator projects `state.openWindows`+`state.preferencesOpen`.** (Keeps a single source of truth.) `openLocalFolder` -> `NSWorkspace.shared.open` (772-774); `quit` -> `NSApp.terminate`.

> Correction to §2's `Effect` enum: remove `showProgressWindow/closeProgressWindow/showPreferences/closePreferences` cases. The reducer instead mutates `openWindows`/`preferencesOpen` directly (already specified in the transition table), and the `WindowCoordinator` projects them. `showAlert`/`postNotification` stay as effects (they are fire-and-forget, not part of declarative window state).

**Start flow (passphrase-retry, off the reducer):** `startOperation(id, kind, isAutoMerge)` runs `gateway.start<kind>(...)`; on `BridgeError.isPassphraseRequired` (and not auto-merge) it `await prompter.passphrase(...)`, then on remember stores the passphrase **only after a successful retry start** (Bug A — store passphrase after success, mirroring iOS RepositoryGateway.swift:37-42, NOT AppController.swift:999-1001's store-before-retry), retries; on final failure dispatches `operationStartFailed(... isAutoMerge:)`. On success dispatches `beginPolling` via the reducer-emitted effect. Sync's `isNoSyncTargets` -> `showAlert("No Sync Targets", ...)` (1493-1496).

**Pollers (Bug B seam):** `Poller` = the verbatim `PollerState` (task + restartRequested). `drivePoller` is the verbatim MainActor TOCTOU handshake (1094-1125), with the poll body now:
```swift
private func pollStatuses(_ kind: OperationKind) async {
    let snaps = state.workspaces.map { (id: $0.id, path: $0.localPath) }
    for s in snaps where !s.path.isEmpty {
        let update: WorkUpdate
        do {
            let progress = try await gateway.poll(kind: kind, localPath: s.path)   // OperationProgress
            let op = OperationState.from(progress, kind: kind)
            update = progress.isEmptyRow ? .absent : .snapshot(op)                 // 1137 filter -> .absent
        } catch {
            update = .snapshot(.finished(.failed(message: userFacingMessage(error), detail: "",
                isNetwork: (error as? BridgeError)?.isNetworkError ?? false)))
        }
        dispatch(.workUpdated(id: s.id, kind: kind, update: update, now: clock()))  // reducer folds per-ws (no map replace)
    }
}
```
`isEmptyRow` = `!running && !completed && statusMessage.isEmpty && errorMessage.isEmpty` (the 1137/1282/1598 condition). `hasActive` for `drivePoller` = `state.hasRunning(kind)`.

**Timers** (scheduling only; decisions are pure): `rescheduleAutoMerge` = AutoMerge.swift:42-56 verbatim but reads `state.autoMergeIntervalHours`/`state.autoMergeBackoffActive`, and the Timer block dispatches `autoMergeTimerFired(now: clock())`. `rescheduleStaleCheck` = AutoMerge.swift:106-117 verbatim reading `state.notifyStaleDays`, the Timer dispatches `staleCheckTimerFired`, and after scheduling it dispatches `staleCheckTimerFired(now:)` once (the 116 immediate run). `isTestMode` guards stay in these methods (AutoMerge:45,109).

**Test flow** (`runTestDraft`, ports 610-669 with prompts via `Prompter`): branches `isFileRepositoryPath` (671-676), runs `confirmCreateRepository`/`newRepositoryPassphrase`/`s3Credentials`/`passphrase` via `prompter`, the bridge via `gateway`, stores passphrase **only after `testWorkspaceAccess` succeeds** (Bug A, 645-647/664-666), dispatches `testDraftSucceeded`/`testDraftCancelled`/`testDraftFailed`. Use `connectTasks[draftConfig.id]?.cancel()` + `Task.isCancelled` guards before terminal dispatch (mirror MainStore.swift:125-129,160-161).

### `WorkspaceGateway.swift`
Protocol over the synchronous `Bridge`, each method one `Task.detached(priority: .userInitiated)`. Unifies the three pollers into `poll(kind:localPath:) -> OperationProgress`. Methods: `inspect`, `checkFileRepositoryExists`, `initNewFileRepository`, `configureWorkspace`, `encodeS3URI`, `testWorkspaceAccess`, `storeWorkspacePassphrase`, `clearWorkspacePassphrase`, `startMerge(localPath:password:author:message:)` (message literal `"Merge from macOS menu bar"` lives here, 1043), `startStatus`, `startSync(workers:)`, `poll(kind:localPath:)`, `cancel(kind:localPath:)`, `listSyncTargets`, `addSyncTarget`, `deleteSyncTarget`.
```swift
struct OperationProgress: Equatable {   // unifies Merge/StatusWorkspaceStatus
    let running, canCancel, completed, cancelled, upToDate: Bool
    let statusMessage, detailedOutput, revisionId, errorMessage: String
    let errorIsNetwork: Bool
    var isEmptyRow: Bool { !running && !completed && statusMessage.isEmpty && errorMessage.isEmpty }
}
extension OperationState {
    static func from(_ p: OperationProgress, kind: OperationKind) -> OperationState { /* reuse from(merge:)/from(status:) shape */ }
}
```
`FakeWorkspaceGateway` (scripted queues) backs fast store tests; `RealWorkspaceGateway` backs the real-bridge suite.

### `SettingsGateway.swift`
Protocol + `UserDefaultsSettingsGateway`. Ports the suite override (106-112), config JSON blob (835-849), the three date dicts (126-145), the three ints (60-66,114-116 with the `max(1,…)`/`max(0,…)` load clamps). `MergeTracking` carries the three `[String: Date]` dicts and converts to/from per-workspace fields at the boundary:
```swift
struct AppSettings: Equatable { var syncWorkers, autoMergeIntervalHours, notifyStaleDays: Int }
struct MergeTracking: Equatable {
    var lastSuccessfulMerge: [String: Date]
    var firstTracked: [String: Date]
    var lastStaleNotified: [String: Date]
    init(from workspaces: [WorkspaceState]) { /* harvest per-ws fields by path */ }
}
protocol SettingsGateway {
    func loadWorkspaceConfigs() -> [WorkspaceConfig]
    func saveWorkspaceConfigs(_ configs: [WorkspaceConfig])
    func loadAppSettings() -> AppSettings
    func saveSetting(_ key: SettingKey, _ value: Int)   // persist one int (didSet -> effect)
    func loadTracking() -> MergeTracking
    func saveTracking(_ tracking: MergeTracking)
}
```
`stateLoaded` applies `MergeTracking` onto each `WorkspaceState` by path.

### `PromptRequest.swift` (the Prompter seam)
```swift
@MainActor protocol Prompter {
    func passphrase(workspaceName: String) async -> PassphrasePromptResult?       // 1679-1719
    func newRepositoryPassphrase(at path: String) async -> String?                // 712-739
    func confirmCreateRepository(at path: String) async -> Bool                   // 702-710
    func s3Credentials(hostURL: String) async -> S3CredentialsResult?             // S3CredentialsPrompt
    func syncTarget() async -> SyncTargetResult?                                  // 1418-1457
    func alert(title: String, message: String) async                             // 1730-1737
}
struct PassphrasePromptResult: Equatable { let passphrase: String; let rememberInKeychain: Bool }
struct S3CredentialsResult: Equatable { let accessKeyId: String; let accessKey: String }
struct SyncTargetResult: Equatable { let name: String; let uri: String }
```
`AppKitPrompter` wraps each `NSAlert.runModal` verbatim (the `async` is a formality; runModal blocks on the MainActor). `ScriptedPrompter` dequeues canned results and records `recordedAlerts` + `passphraseRequests` for tests. **`S3CredentialsPrompt.swift` is deleted**; its body (s3KeyIdField/s3AccessKeyField) moves into `AppKitPrompter.s3Credentials`.

### `Notifier.swift`
```swift
struct NotificationRequest: Equatable { let workspaceID: UUID; let title, body: String }
protocol Notifier { func requestAuthorization(); func post(_ id: UUID, title: String, body: String) }
final class UserNotificationsNotifier: Notifier { /* AutoMerge:158-173 bodies, isTestMode-guarded by store */ }
struct SilentNotifier: Notifier { /* no-ops for tests */ }
```
The `postNotification` effect carries `(id, title, body)`; the store calls `notifier.post`. The `UNUserNotificationCenterDelegate` taps (AutoMerge:176-198) live on `AppDelegate`, hop to MainActor, and `store.dispatch(.operationClicked(id:, kind:.merge))`-equivalent to open the merge window (it adds the `WindowKey` and routes).

### Projection
**`AppDelegate.swift`**: owns one `AppStore`, a `MenuController`, a `WindowCoordinator`, the `NSStatusItem`+`TrayIconAnimator`, the test host. ONE `store.$state` Combine sink (with `removeDuplicates` over `(menuSnapshot, openWindows, preferencesOpen, trayTooltip, statusMessage)`) drives `menuController.render`, `windowCoordinator.render`, tray update, and `refreshTestMenuHostWindow` (testStatusLabel = `state.statusMessage`). `applicationDidFinishLaunching` ports 230-245 (setActivationPolicy, AppIcon, status item) then `store.onStart()`.

**`MenuController` + `AppMenuBuilder(snapshot:)`**: `AppState.menuSnapshot()` (pure) computes `MenuSnapshot` carrying all title/enabled logic from AppMenuBuilder.swift:140-180 (`"Merge (in progress)"`/`"Merge (failed)"`/`"Merge"`, `idle = !ws.isBusy && !isSaving && !isTesting`, `sync enabled iff hasSyncTargets && idle`). `AppMenuBuilder.build(snapshot, actions:)` lays out items, preserving every menu item identifier (§5). `@objc final class MenuActions: NSObject` (held by MenuController, `unowned let store`) has the handlers ported from 1739-1787: each reads `representedObject` UUID and either `store.dispatch(.operationClicked(...))` (which routes open-vs-start) or, for the in-window starts, the open-vs-start decision is in `operationClicked`'s store handler: if `ws.op(kind).isRunning` or (merge-specific) `.isTerminalFailure`, add the `WindowKey` (open window); else dispatch `operationStartRequested`. Status's open-vs-start uses `running || isFinished` (1742); sync uses `running` (1767); merge uses `running || isTerminalFailure` (1751).

**`WindowCoordinator`**: diffs `state.openWindows` (Set<WindowKey>) + `state.preferencesOpen` against currently-open NSWindows. Opens/closes the delta. `makeWindow` ports the shared setup (430-443 etc.): `.floating`, 760×420, min 640×320, `isReleasedWhenClosed=false`, `delegate=self`, title `"\(name) \(kind.windowTitleSuffix)"`, content `NSHostingController(OperationProgressView(store:workspaceID:kind:))`. `windowWillClose` maps the NSWindow back to its `WindowKey`/preferences and `store.dispatch(.progressWindowClosed(...))` / `.closePreferencesClicked` (so close-by-the-titlebar-X folds through the reducer, keeping op state intact — Bug C). The SwiftUI view observes `store` directly, so existing windows self-update; the coordinator only opens/closes/retitles.

---

## 5. UNIFIED `OperationProgressView` + A11Y CONTRACT

### `OperationProgressView.swift` (replaces all three)
```swift
struct OperationProgressView: View {
    @ObservedObject var store: AppStore
    let workspaceID: UUID
    let kind: OperationKind

    var body: some View {
        let ws = store.state.workspace(workspaceID)
        let op = ws?.operation(kind) ?? .idle
        let showsDetails = ws?.showsDetails(kind) ?? false
        let statusText = op.statusMessage.isEmpty ? fallbackText(ws) : op.statusMessage

        VStack(alignment: .leading, spacing: 16) {
            Text(ws?.config.displayName ?? "").font(.title3).fontWeight(.semibold)
            Text(ws?.localPath ?? "").font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            Toggle("Detailed Output", isOn: Binding(
                get: { showsDetails },
                set: { store.dispatch(.detailsToggled(id: workspaceID, kind: kind, show: $0)) }))
            outputScroll(op: op, showsDetails: showsDetails)   // shared; error label id per kind
            HStack {
                if op.isRunning { ProgressView().controlSize(.small) }
                Spacer()
                cancelButton(op: op)
                if kind == .status { mergeButton(op: op) }
                Button("Close") { store.dispatch(.progressWindowClosed(id: workspaceID, kind: kind)) }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20).frame(minWidth: 640, minHeight: 320)
    }
}
```
Per-kind specifics (one concrete switch, NO hierarchy — plan.md:84):
- **error label id** (the red error `Text`): `.merge -> "mergeErrorMessage"` (MergeProgressView.swift:66), `.status -> "statusErrorMessage"` (StatusProgressView.swift:67), `.sync -> "syncErrorMessage"` (SyncProgressView.swift:63).
- **cancel button**: `.merge -> Button("Cancel Merge")` + NEW id `cancelMergeButton`; `.status -> Button("Cancel Status")` + NEW id `cancelStatusButton`; `.sync -> Button("Abort")` + EXISTING id `abortSyncButton` (SyncProgressView.swift:96). All `.disabled(!op.isRunning || !op.canCancel)`. (The two NEW ids are A3 hooks; confirmed absent today in Merge/Status views.)
- **mergeButton** (status only): `Button("Merge")` dispatches `progressWindowClosed(.status)` then `store.beginMerge(id:)`; `.disabled(!ranSuccessfully || mergeRunning)` where `ranSuccessfully = (if case .finished(.completed) = op)` (StatusProgressView.swift:13,101-105).
- **fallbackText** (empty `statusMessage`): `.merge -> state.lastMergeText(ws)` (MergeProgressView.swift:14, now reading `lastSuccessfulMerge`); `.status -> "Scanning..."` (StatusProgressView.swift:52); `.sync -> "Preparing sync..."` (SyncProgressView.swift:12).
- shared: the `ScrollViewReader`+bottom-anchor `"\(kind.rawValue)-output-bottom"`, the Output/Status/Error sections, the `onAppear`/`onChange(detailedOutput)`/`onChange(showsDetails)` auto-scroll guarded by `showsDetails && op.isRunning` — identical across the three.

### Full accessibility-identifier contract (frozen — a rename = a red XCUI run)
**NSMenu items** (AppMenuBuilder.swift:8-35, preserve in `AppMenuBuilder.build`): `workspace.menu.<path>`, `workspace.status.<path>`, `workspace.merge.<path>`, `workspace.sync.<path>`, `workspace.progress.<path>`, `workspace.last.<path>`, `workspace.open-folder.<path>`. Menu **titles** (matched, must not change): `"Settings"`, `"Merge"`, `"Status"`, `"Open Local Folder"`, `"Sync Repository"`, `"Quit Cling Sync"`, the workspace submenu titled `displayName`, and running rows `"\(displayName) - \(label)"`.

**Prompts** (move into `AppKitPrompter` verbatim): `passphrasePromptField` (1692), `passphrasePromptRemember` (1698), `newRepositoryPassphraseField` (721), `s3KeyIdField`/`s3AccessKeyField` (S3CredentialsPrompt.swift), `syncTargetNameField` (1433), `syncTargetRepositoryField` (1436). Prompt button titles: `"Create"`, `"Cancel"`, `"Continue"`, `"Add"`, `"OK"`.

**Progress windows**: `mergeErrorMessage`, `statusErrorMessage`, `syncErrorMessage`; `abortSyncButton` (existing). Button titles: `"Close"`, `"Cancel Merge"`, `"Cancel Status"`, `"Merge"`, `"Abort"`. **NEW (A3)**: `cancelMergeButton`, `cancelStatusButton`.

**PreferencesView** (PreferencesView.swift): `workspaceList` (121), `addFolderButton` (133), `removeFolderButton` (142), `localFolderField` (165), `browseFolderButton` (169), `serverURLField` (176), `remotePathField` (182), `authorField` (188), `preferencesErrorMessage` (196), `syncTargetsList` (261), `addSyncTargetButton` (271), `removeSyncTargetButton` (280), `testWorkspaceButton` (214), `saveWorkspaceButton` (221), `syncWorkersStepper` (40), `autoMergeIntervalPicker` (61), `notifyStaleDaysPicker` (94), `scheduleAutoMergeButton` (77 — load-bearing: the Go side triggers auto-merge through it). Window title `"Cling Sync Settings"` (398). Tab labels `"Workspaces"`/`"Options"` (9/11). `WorkspaceRow` static-text badges `"Invalid"`/`"Needs Test"` (306-310).

**Test host** (AppDelegate): `testStatusLabel` (1792, `.value` == `state.statusMessage`), `testAppMenuHostButton` (1800, pops `AppMenuBuilder.build(state.menuSnapshot())`). Env: `CLING_SYNC_TEST_MENU_HOST=1` (host window + suppress timers/notifications via `isTestMode`), `CLING_SYNC_TEST_DEFAULTS_SUITE` (isolated UserDefaults suite, 106-112). Both survive into `AppStore`/`SettingsGateway`.

> Note `scheduleAutoMergeButton`: in the rewrite its action dispatches a "schedule auto-merge soon" path. Since this is load-bearing for the Go XCUI driver, the store keeps `scheduleAutoMergeSoon` (AutoMerge:148-156): a 5s one-shot Timer that dispatches `autoMergeTimerFired(now:)`.

---

## 6. PHASED MIGRATION ORDER (each step green on both suites)

Run commands (verified against build.sh:229-243, 481-489):
- **Pure/fast (local):** `./build.sh macos unit_test` → `xcodebuild -project … -scheme ClingSyncMac -destination 'platform=macOS' -only-testing:ClingSyncMacTests test`.
- **Full VM suite:** `./build.sh macos test --remote` (runs unit + integration/XCUI on the runner VM).
- **Final gate:** `./build.sh macos precommit` (build_tools + fmt + lint --strict + the full VM suite).

Steps a–c add code without touching the running app (old `AppController` still drives everything via `Main.swift`). Step d flips the view layer behind the frozen XCUI net. Step e deletes dead code.

**Step a — Pure core + reducer tests.** Create `OperationKind/OperationState/WorkspaceState/AppState/AppEvent/Effect/WorkUpdate/AppReducer/OperationReducer.swift`. Delete `WorkspaceConfig.lastMergeDate` (WorkspaceConfig.swift:166-172) — fix its sole readers in old code with a temporary `lastSuccessfulMergeByPath` read OR (simpler) leave the old `AppController.lastMergeLabel` reading the dict it already has and just drop the FS method (no old caller breaks because `mergeStatusText` already prefers the live status). Add `ClingSyncMacTests/AppReducerTest.swift` + `OperationReducerTest.swift` + `AppStateTest.swift`. Required cases: `operationStartRequestedSetsOptimisticRunningAndEmitsStart`, `operationStartFailedClearsRunningToFailedNoTrackingNoPersist` (Bug A), `terminalFailureSurvivesAbsentPoll` + `terminalFailureSurvivesIdleSnapshot` (Bug B), `runningOperationRejectsSiblingStart` (mutual exclusion, A5), `draftAccessEditInvalidatesVerification` + `draftEditDoesNotClearKeychain` (Bug A2), `settingsChangesEmitRescheduleEffects`, `autoMergeUpToDateStaysSilent`/`autoMergeNetworkFailSetsBackoffSilent`/`autoMergeOtherFailPostsNotification`, `removeWorkspaceEmitsClearAndPersist`, `closingWindowKeepsOperationState` (Bug C), `mergeCompletedRecordsLastMerge`/`upToDateAlsoRecords`/`cancelledDoesNotRecord` (Bug E). Run: `./build.sh macos unit_test`. Old app untouched ⇒ `--remote` green.

**Step b — Gateways + Prompter + Notifier.** Create `WorkspaceGateway.swift` (+ `RealWorkspaceGateway` + `OperationProgress`), `SettingsGateway.swift` (+ `UserDefaultsSettingsGateway` + `AppSettings` + `MergeTracking`), `PromptRequest.swift` (+ `AppKitPrompter` + `ScriptedPrompter`), `Notifier.swift`. Add `ClingSyncMacTests/SettingsGatewayTest.swift` (round-trip via `UserDefaults(suiteName:)`). Run: `./build.sh macos unit_test`. ⇒ `--remote` green.

**Step c — AppStore + A4b real-bridge harness (BEFORE the flip).** Create `AppStore.swift`. Build A4b now: copy `ios/go/unit_test.go` → `macos/go/unit_test.go` (provisionServer `/new-repo`, fixed port `47645`, ephemeral per-repo S3), add `TestMacOSUnit` driver. Copy `ios/ClingSyncTests/TestRepo.swift` → `macos/ClingSyncMacTests/TestRepo.swift` verbatim (`@Suite(.serialized) struct BridgeSuite`, `provisionPort=47645`, `canConnect` gate, `waitUntil`), changing `@testable import ClingSync` → `ClingSyncMac`. Split build.sh `unit_test()` into the pure path + a real-bridge path setting `CLING_SYNC_GO_BUILD_TAGS=mock` + `CLING_SYNC_MOCK_KEYCHAIN_FILE` (mirror main_test.go:430-433); wire `TestMacOSUnit` to invoke it (mirror `TestIOSUnit` calling `./build.sh test --unit-xcode`). Add `StoreConnectTest.swift` + `BridgeSmokeTest.swift` (both `extension BridgeSuite`, `.enabled(if: TestRepo.isAvailable)`): `storeTestsThenSavesWorkspace` (ScriptedPrompter answers passphrase+S3; assert `isAccessVerified`; assert mock-keychain written only on remember=true), `failedTestWritesNothingToKeychain` (Bug A), `storeMergeRecordsLastMerge`, `terminalFailedMergeSurvivesAnIdlePoll` (Bug B integration). Run: `./build.sh macos test --remote`. Old app still drives XCUI ⇒ green. **This is the critical milestone: the new store is real-bridge tested before any user sees it.**

**Step d — Flip the view layer.** Create `AppDelegate.swift`, `MenuController.swift`, `MenuSnapshot.swift`, `WindowCoordinator.swift`, `OperationProgressView.swift`; rewrite `AppMenuBuilder.swift` → `build(_ snapshot:actions:)` and `PreferencesView.swift` → store-bound; change `Main.swift:10` `AppController()` → `AppDelegate()`. Delete `MergeProgressView/StatusProgressView/SyncProgressView.swift` + `S3CredentialsPrompt.swift`. Preserve every a11y id/title (§5). Run: `./build.sh macos test --remote`. The WHOLE existing XCUI suite must pass against the new view layer with ZERO test edits — this is the flip's acceptance gate.

**Step e — Delete dead code + precommit.** Delete `AppController.swift` + `AutoMerge.swift`. Run: `./build.sh macos precommit` (lint --strict flags any dangling symbol; green certifies nothing remains).

A4b is built in step c (before the flip) because the store owns the poller TOCTOU, the optimistic-clear, the terminal-vs-poll race, and the keychain-on-success logic — the pure reducer tests prove the decisions, only the real-bridge store test proves the wiring, and the keychain-not-written-on-failure assertion (Bug A) has no other precise home.

---

## 7. BUG LIST WITH FIXES

**Bug A — a failed Test/op persists nothing bad.**
- A1 (keychain written for a later-rejected passphrase): old start flows store the passphrase BEFORE the retry start (AppController.swift:999-1001/1187-1189/1367-1369/1499-1501; test flow 645-647/664-666 is already correct). Fix: store the passphrase ONLY after the bridge call SUCCEEDS, mirroring iOS `RepositoryGateway.open` (RepositoryGateway.swift:37-42 "Open before persisting"). The reducer never touches secrets. Tests: pure `operationStartFailedClearsRunningToFailedNoTracking`; real-bridge `failedTestWritesNothingToKeychain` (reads `CLING_SYNC_MOCK_KEYCHAIN_FILE`).
- A2 (editing a path wipes a valid passphrase): old `updateDraftInList` (924-934) persists the half-typed draft on every keystroke, and `upsert` (949-959) clears keychain on identity change. Fix: `draftAccessEdited`/`draftMetadataEdited` ONLY mutate `draftConfig` + invalidate `verifiedAccessSignature` + persist the config; they NEVER clear secrets. Secrets clear in exactly two places: `removeWorkspaceClicked`, and `upsert` when the SAVED identity actually changed (mirrors MainReducer.swift:175-187 `repositoryChanged`). Tests: `draftEditDoesNotClearKeychain`, `savingSameRepoDoesNotClearSecrets`, `savingDifferentRepoEmitsClear`.

**Bug B — terminal `OperationState` wins over a late/empty poll.** Old pollers wholesale-replace the map and filter empties (1137-1156/1282-1299/1598-1617): a terminal `failed` whose bridge slot was cleared to empty is dropped, and the menu loses "Merge (failed)". Fix: never wholesale-replace. `pollStatuses` dispatches one `workUpdated(id,kind,update)` per workspace; the reducer folds per-workspace and, on `.absent` (or `.snapshot(.idle)` over a terminal failure), KEEPS the terminal state (§Reducer `workUpdated` steps 1-2). Tests: `terminalFailureSurvivesAbsentPoll`, `terminalFailureSurvivesIdleSnapshot`, `secondWorkspacePollDoesNotClearFirst`; integration `terminalFailedMergeSurvivesAnIdlePoll`.

**Bug C — closing a RUNNING status/sync window strands the op.** `closeStatusProgressWindow`/`closeSyncProgressWindow` `removeValue` the running entry (481-485/1660-1666), so `hasActiveStatuses/Syncs` goes false, `drivePoller` stops, the bridge op runs unobserved. (Merge already does NOT purge, 445-449 — the asymmetry is a defensive-mirror smell.) Fix: `progressWindowClosed` removes only the `WindowKey` from `state.openWindows`; it NEVER mutates `ws.op(kind)`. The poller keeps running (`state.hasRunning(kind)` stays true); the menu still shows "in progress"; a terminal failure with no open window routes to `showAlert` (manual) or `postNotification` (auto). All three kinds symmetric. Relaunch reattach (C2): `onStart` (after `stateLoaded`) emits `beginPolling(.merge/.status/.sync)` once; `drivePoller` self-terminates if all idle (1107-1122). Tests: `closingWindowKeepsOperationState`, `reattachEmitsPollEffects`.

**drivePoller MainActor TOCTOU handshake — PRESERVE (not a bug).** Clearing `poller.task=nil` and re-checking `restartRequested` together in one `MainActor.run` (1111-1119) keeps a just-registered op from being stranded. Lift `PollerState`+`drivePoller` into `AppStore` verbatim; only the poll body changes (dispatch `workUpdated` instead of map mutation). Keep the `nonisolated` notification delegates hopping to MainActor (AutoMerge:177-198). No pure test can exercise the actor race; the real-bridge store tests under overlapping ops are the net.

**Bug E — two sources of truth for "last merge".** `WorkspaceConfig.lastMergeDate` (FS mtime, WorkspaceConfig.swift:166-172) feeds `lastMergeLabel`/`mergeStatusText`/MergeProgressView, while `lastSuccessfulMergeByPath` (a persisted dict, 71,126-145,165-170) feeds the menu and the staleness check. A sync touches `refs/head` and advances the mtime without recording a merge, so the two disagree. Fix: DELETE `lastMergeDate`; the single source is `WorkspaceState.lastSuccessfulMerge` (persisted via `MergeTracking`). `AppState.lastMergeText` and the merge window fallback both read it. Also removes a hidden `FileManager` read from a `Codable` value type. Tests: `mergeCompletedRecordsLastMerge`, `upToDateAlsoRecords`, `cancelledMergeDoesNotRecord`; the XCUI A2 test ("Last Merge: never" → real age) is the e2e backstop (menu already reads the tracked value, AppMenuBuilder.swift:127).

---

Relevant source files (all absolute): `/Users/pero/src/pero/cling-sync-clients/macos/Sources/AppController.swift`, `AutoMerge.swift`, `AppMenuBuilder.swift`, `Bridge.swift`, `WorkspaceConfig.swift`, `AutoMergePolicy.swift`, `MergeProgressView.swift`, `StatusProgressView.swift`, `SyncProgressView.swift`, `PreferencesView.swift`, `S3CredentialsPrompt.swift`, `Main.swift`; tests `/Users/pero/src/pero/cling-sync-clients/macos/ClingSyncMacTests/` and `/Users/pero/src/pero/cling-sync-clients/macos/go/main_test.go` (+ new `unit_test.go`); iOS template `/Users/pero/src/pero/cling-sync-clients/ios/ClingSync/{MainStore,MainReducer,Effect,WorkUpdate,RepositoryGateway,PassphrasePrompt,SettingsGateway}.swift` and `/Users/pero/src/pero/cling-sync-clients/ios/ClingSyncTests/{TestRepo,StoreConnectTest}.swift` and `/Users/pero/src/pero/cling-sync-clients/ios/go/unit_test.go`; plan `/Users/pero/src/pero/cling-sync-clients/macos/.refactor/plan.md`.