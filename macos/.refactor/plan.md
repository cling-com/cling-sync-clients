# macOS MVP overhaul — plan

Goal: bring `macos/` to the same MVP/MVI shape as the rewritten iOS/Android apps. The
AppKit/SwiftUI layer becomes a pure projection of an immutable `AppState` that emits
events; all logic lives in pure `reduce` functions + gateways + a thin store; backed by a
large real-bridge + pure test suite. Mirror the iOS SHAPE, not its code. Unify the three
near-identical progress windows. No abstraction monsters.

Source of the detailed analysis: 5-agent workflow (bridge surface, logic-vs-view
inventory, coverage gaps, harness feasibility, iOS template). Findings saved under
`/tmp/macos-analysis/*.md` during the analysis session.

Tests ALWAYS run via `./build.sh macos test --remote` (runner VM; REMOTE_RUNNER_HOST/USER
in .env which must NOT be read). Baseline is GREEN; one XCUI test was flaky (see A1).

The current app is a menu-bar accessory managing N workspaces (folder <-> repo), each with
Merge / Status / Sync-Repository ops, plus timer-driven auto-merge, staleness
notifications, and network backoff. Everything lives in `AppController.swift` (1838 lines,
NSApplicationDelegate + ObservableObject + NSWindowDelegate) + the `AutoMerge.swift`
extension. Only `AutoMergePolicy` is pure/unit-tested.

## Phase A — Harden + expand the safety net FIRST (before any rewrite)

The iOS port proved the safety net is what makes the rewrite fearless. Build it first.

- A1. Fix the flaky XCUI waiter. `waitForFirstMatch` (ClingSyncMacUITests.swift:566-586)
  calls `NSPredicate.evaluate(with:)` on XCUIElements; a transient "Failed to get matching
  snapshot" throws and fails the test. Make predicate evaluation snapshot-resilient
  (treat a thrown snapshot miss as not-yet-matched, keep polling). Root cause of the
  observed baseline flake.
- A2. Fault-injection harness (T0.1). Port iOS `faultControl` mux + `/__test/{reset,
  fail-writes,latency}` wrapping `serveRepository`'s mux (go/main_test.go:455), thread a
  `controlUrl` through the JSON config + `UITestConfig`, add a Swift raw-socket
  `injectFault` helper (URLSession can't do cleartext localhost). Unblocks ~10 error/abort/
  cancel/backoff/concurrency tests.
- A3. Test hooks / accessibility ids: add ids to the merge/status Cancel buttons
  (`cancelMergeButton`/`cancelStatusButton`), to the WorkspaceRow "Invalid"/"Needs Test"
  badges, mirror `trayTooltip` into the hosted test window; read the mock-keychain file
  from the Go driver for remember/remove assertions.
- A4. New Swift unit-test target `ClingSyncMacTests` (host-loaded, Swift Testing, mirrors
  ios/ClingSyncTests). pbxproj: new PBXNativeTarget product-type bundle.unit-test +
  synchronized group + BUNDLE_LOADER/TEST_HOST (symbols resolve against the host that
  already links gobridge.a — do NOT re-link the archive) + scheme Testable. Add
  `macos/go/unit_test.go` provisioning server (`/new-repo`, fresh repo + ephemeral S3 port
  passed via env — macOS runs native, no fixed-port/launchd dance) + build.sh `unit_xcode`
  (no simulator; CLING_SYNC_GO_BUILD_TAGS=mock + CLING_SYNC_MOCK_KEYCHAIN_FILE) and a Go
  `TestMacOSUnit` driver. Port AutoMergePolicyTests into it; retire the swiftc path + delete
  macos/UnitTests/. Add BridgeSmokeTest (Swift Bridge.swift wrapper coverage — currently
  zero). Serialized BridgeSuite (bridge holds process-global open-repo state).
- A5. Tier-1 characterization XCUI tests (pin the invariants the rewrite will move into
  reducers): optimistic-in-progress-then-start-fails clearing (merge/status/sync),
  mid-op Cancel/Abort, poller-restart handshake under overlapping ops, mutual exclusion
  (a running op disables siblings), test-invalidation on edit, remove-workspace side
  effects.
- A6. Tier-2 pure unit tests: WorkspaceConfig derived state, validateHostURL,
  userFacingMessage mapping, network-backoff + runStaleCheck orchestration.
- A7. Tier-3 e2e fills: existing file-repo Test flow, Status->in-window Merge button,
  remove sync target via UI, sync-workers stepper reaches sync, keychain-remember=false
  re-prompts, single-vs-multi menu layout + running-summary section.

## Phase B — MVP rewrite (view-layer-only), behind the green safety net

Mirror iOS file layout (one type per file):
- `AppState.swift`: `struct AppState: Equatable` + `[WorkspaceState]` keyed by id/path +
  `OperationState` enum (idle | running(msg,detail,canCancel) | finished(Outcome) where
  Outcome = completed(msg,revisionId?,upToDate) | cancelled | failed(msg,isNetwork)).
  Replaces the 8 `…ByPath` dicts + the flag-combo "state machine". Derived values
  (statusMessage, trayTooltip, isBusy, can*, has*, anyOperationRunning) become computed.
- `AppEvent.swift`: flat enum, workspace-scoped cases carry an id. Prompts are NOT events
  (resolved via an injected Prompter).
- `Effect.swift`: `enum Effect: Equatable` + `struct Reduction`. Settings didSet ->
  reschedule become emitted effects.
- `AppReducer.swift`: pure `reduce(state, event) -> Reduction`. `OperationReducer.swift` +
  `WorkUpdate.swift`: the per-op state machine folding normalized progress.
- `AppStore.swift`: `@MainActor ObservableObject`, `dispatch -> reduce -> apply ->
  run(effect)`, heavy bridge work off-main then hop back; owns timers/pollers/windows.
- Gateways: `WorkspaceGateway` (async wrappers over synchronous Bridge), `SettingsGateway`
  (UserDefaults) as protocols. `Prompter` protocol (AppKitPrompter real + ScriptedPrompter
  test) for the 5 NSAlert prompts — keep the exact accessibility ids.
- `AppMenuBuilder(state:)` pure projection (no more reaching into the controller) +
  a `WindowCoordinator` diffing requested (workspaceID, kind) windows against open NSWindows.
- One `OperationProgressView(kind:)` replacing Merge/Status/SyncProgressView — concrete,
  driven by OperationKind switch + one `if kind == .status` for the extra Merge button;
  pass error-accessibility-id and cancel label per kind; NO protocol/strategy hierarchy.
- Timers: pure decisions (AutoMergePolicy + reducer) + a store-owned scheduler.

Bugs to fix during the rewrite (re-verify against the characterization tests):
- Bug A analog: a failed Test must persist nothing bad (verify keychain not written on a
  passphrase the bridge later rejects; verify editing a path doesn't wipe a valid passphrase).
- Bug B analog: terminal OperationState must win over a late/empty poll (pollers currently
  wholesale-replace the map and filter empties -> a terminal "failed" row can be dropped).
- Bug C analog: reattach a still-running bridge op on relaunch (currently pollers only start
  after a start* call); and closing a RUNNING Status/Sync window removes its only state
  holder -> poller stops -> op continues unobserved (strand risk). Decide intended behavior.
- Data races: preserve the drivePoller MainActor TOCTOU handshake; keep nonisolated
  notification delegates hopping to MainActor.
- Two sources of truth for "last merge": WorkspaceConfig.lastMergeDate (FS mtime) vs
  lastSuccessfulMergeByPath — pick one.

## Phase C — Adversarial multi-agent review vs pre-rewrite behavior; verify each finding; fix; converge.

## Status log
- 2026-06-06: analysis done; baseline green (one flaky XCUI test, root-caused = A1).
- 2026-06-06: A1 DONE + verified green (full precommit: fmt+lint+all integration/XCUI passed).
  Replaced the throwing NSPredicate.evaluate(with: XCUIElement) waiters with .exists-guarded
  reads (elementText/statusContains/terminalError) in ClingSyncMacUITests.swift.
- 2026-06-06: A2 (fault injection) IMPLEMENTED, locally verified (fmt + lint + compile-only
  `build-for-testing` = TEST BUILD SUCCEEDED). NOT yet run on the runner (user asked to hold
  test runs while CI uses the runner). Added to macos/go/main_test.go: faultControl + wrap +
  serveFaultRepository (returns s3 url + http controlURL on the same port) + controlURL in
  uiTestConfig/writeXCUITestConfig + driver TestMacOSXCUITestAutoMergeError. Added to
  ClingSyncMacUITests.swift: `import Darwin`, UITestConfig.controlUrl, injectFault (raw socket),
  triggerAutoMerge, pollTrayMenu, and test testAutoMergeErrorThenRecovers (fail-writes -> menu
  shows "Merge (failed)" w/o recording success -> reset -> recovery records a real Last Merge +
  commits the seeded local file, Go-verified). exerciseAutoMerge left untouched (can later dedup
  its trigger via triggerAutoMerge once tests are runnable).
- 2026-06-06: A1 + A2 VERIFIED GREEN on the dedicated VM (ci@192.168.64.5) via
  `build.sh macos precommit`: fmt/lint 0 issues; all 6 Go tests PASS incl.
  testConfigureAndMergeTwoWorkspaces (the flaky one) and the new TestMacOSXCUITestAutoMergeError.
  Follow-up fix during verification: terminalError now requires NON-EMPTY error text (an
  existing-but-empty error label is a SwiftUI insert/remove artifact, not a terminal failure)
  — this was the second flake the .exists-based waiter exposed. CWD gotcha: always run
  `./build.sh` from the repo root (a `cd macos` left the shell there and `./build.sh macos ...`
  hit macos/build.sh -> "Unknown command: macos").
- 2026-06-06: A4a DONE + VERIFIED GREEN on the VM. Added the host-loaded Swift unit-test target
  ClingSyncMacTests (Swift Testing, product-type bundle.unit-test, BUNDLE_LOADER/TEST_HOST against
  the app that already links gobridge.a — no archive re-link). pbxproj objects A1000030..A100003A;
  scheme Testables now lists ClingSyncMacTests + ClingSyncMacUITests. Ported AutoMergePolicy tests
  to ClingSyncMacTests/AutoMergePolicyTests.swift (@testable import ClingSyncMac, Swift Testing
  #expect); deleted macos/UnitTests/ + the swiftc unit_test path. build.sh: unit_test now runs
  `xcodebuild -only-testing:ClingSyncMacTests test`; test/precommit restructured so --remote runs
  unit+integration ON THE VM (no local xcodebuild). Verified: local `xcodebuild test
  -only-testing:ClingSyncMacTests` (2 tests pass) AND full VM precommit (fmt/lint 0 issues, VM
  unit + all 6 integration PASS).
- 2026-06-06: A6 DONE + green (local + VM). Added ClingSyncMacTests/WorkspaceConfigTests.swift
  (ValidateHostURLTests + WorkspaceConfigTests) + BridgeErrorTests.swift — 18 pure tests total
  with AutoMergePolicy. Pin the durable data model (validateHostURL; isComplete/isValidForSave/
  isReadyForTest; isS3Host/bridgeRepositoryURI; needsS3Credentials incl. embedded-different-host;
  s3URIHasEmbeddedCredentials; displayURL round-trip; normalizedRepoPathPrefix; accessSignature
  invalidation; displayName/detailText; BridgeError code classifiers).
- 2026-06-06: A5 (focused slice) DONE + green on VM. Added TestMacOSXCUITestMutualExclusion +
  testRunningMergeDisablesSiblings: a latency-slowed auto-merge keeps isBusy true (optimistic
  status), and the menu's sibling Status item is disabled while the merge runs and re-enables
  after — a robust, non-racy architecture-independent guard for the mutual-exclusion invariant.
  Chose mutual-exclusion over cancel because StartMergeWorkspace registers the cancellable state
  only AFTER a synchronous pre-flight open (workspace.go:382-403), so a tapped cancel is racy;
  cancel will instead be covered by clean pure/store tests in the rewrite.
- PHASE A SAFETY NET sufficient: happy-path e2e (existing) + error/recovery e2e (A2) +
  data-model pure tests (A6) + mutual-exclusion e2e (A5) + the unit harness for TDD'ing reducers.
  Deferred (lower ROI / better as new-architecture tests): A4b real-bridge Swift BridgeSmokeTest +
  provisioning server; e2e cancel/poller/optimistic-clear (-> pure reducer + new store tests).
- 2026-06-06: PHASE B BLUEPRINT done (5-agent workflow) -> saved to macos/.refactor/blueprint.md
  (66KB: resolved design decisions, compilable core types, full AppReducer transition table,
  store/gateway/Prompter/projection design, frozen a11y contract, phased migration, bug list
  A/B/C/E). Key decisions: OperationState = enum(idle/running/finished(Outcome)); per-workspace
  tracking (not dicts); Prompter protocol (not events); window/preferences visibility lives in
  AppState (openWindows/preferencesOpen), NOT effects (so WindowCoordinator projects them, and the
  Effect enum drops show/closeProgressWindow+show/closePreferences); Bug C fix = closing a window
  never mutates OperationState; Bug E = delete WorkspaceConfig.lastMergeDate.
- 2026-06-06: PHASE B Step a (part 1) DONE + compiles. Added the pure value types to macos/Sources/:
  OperationKind, OperationState (+from(merge:)/from(status:)), WorkspaceState, AppState (+WindowKey),
  WorkUpdate, Effect (+SettingKey/Reduction), AppEvent, and AppSettings/MergeTracking (in
  SettingsGateway.swift, structs only for now). Additive (old AppController still drives the app).
  Verified: `xcodebuild build` of the app target = BUILD SUCCEEDED. SourceKit per-file "cannot find
  type" diagnostics are false positives (whole-module build disproves them).
- 2026-06-06: PHASE B Step a (part 2) DONE + green locally (53 unit tests). Added AppReducer.swift
  (full §3 transition table, exhaustive switch, dedups identical effects) + OperationReducer.swift
  (the Bug-B-safe workUpdated fold + completion routing). Tests: AppReducerTest.swift (start/fold/
  auto-merge/draft+window/settings/launch suites) + AppStateTest.swift (computed props). Covers
  Bug A (start-fail no tracking; draft-edit/save-same-repo don't clear keychain, save-different-repo
  does), Bug B (terminal survives absent/idle poll), Bug C (closing running window keeps op; finished
  status->idle; failed merge sticky), Bug E (completed/upToDate record, cancelled doesn't),
  mutual-exclusion, auto-merge routing, stale throttle, settings reschedule. swiftlint: disabled
  cyclomatic_complexity on reduce+fold and function_parameter_count on beginOperation (reducer-pattern
  inherent; chose suppress over synthetic structs). DESIGN REFINEMENT vs blueprint: blueprint's
  "never mutate op state on close" regressed status re-run (a finished status stayed .finished ->
  click re-opened stale window). Fix: progressWindowClosed resets a FINISHED status/sync to .idle
  (re-runnable, old behavior) but NEVER a running one (the real Bug C); merge keeps its terminal
  state (old sticky-failed behavior). Verified local `xcodebuild -only-testing:ClingSyncMacTests`
  (53 pass) + fmt + lint clean. NOTE: `./build.sh macos unit_test` is NOT a command (unit_test is an
  internal function); run the xcodebuild -only-testing:ClingSyncMacTests directly, or add a `unit`
  command to macos/build.sh.
- 2026-06-06: XCUI flake (testConfigureAndMergeTwoWorkspaces) recurred on a Step-a VM run, this
  time inside elementText: `element.exists` returned true then `element.value` THREW "Failed to get
  matching snapshot" (a TOCTOU race; .exists can't guard it). DEFINITIVE FIX: read all element text
  via `try? element.snapshot()` (snapshot() is a THROWING Swift API, so the snapshot failure becomes
  a swallowable nil instead of a test-aborting exception) — applied to elementText + menuItemTitle,
  and routed the preferences-error asserts + replaceText through them. terminalError dropped its
  .exists guard (elementText now returns "" for missing/transient/empty). This supersedes the A1
  .exists-guard approach for the throw mechanism. (Reusable lesson: in XCUITests prefer
  `try? snapshot()` reads over bare `.value`/`.label`.) VERIFIED GREEN on the VM: full suite passes
  incl. testConfigureAndMergeTwoWorkspaces + the 53 reducer unit tests. STEP a COMPLETE.
- 2026-06-06: PHASE B Step b (boundary layer) DONE + green locally (57 unit tests, fmt+lint clean).
  Added: WorkspaceGateway.swift (protocol + RealWorkspaceGateway thin async Bridge wrappers +
  OperationProgress with from-MergeWorkspaceStatus/from-StatusWorkspaceStatus inits + isEmptyRow);
  SettingsGateway protocol + UserDefaultsSettingsGateway (ports config JSON blob + 3 int settings
  + 3 date dicts + the CLING_SYNC_TEST_DEFAULTS_SUITE override); PromptRequest.swift (Prompter
  protocol + AppKitPrompter [verbatim NSAlert bodies, all a11y ids preserved] + ScriptedPrompter +
  PassphrasePromptResult/S3CredentialsResult/SyncTargetResult); Notifier.swift (Notifier protocol +
  UserNotificationsNotifier + SilentNotifier). Consolidated OperationState bridge mapping into
  OperationState.from(_ OperationProgress) (removed from(merge:)/from(status:)). Added
  SettingsGatewayTest.swift (round-trips + harvest). DELETED the old `struct PassphrasePromptResult`
  from AppController.swift:5-8 (collided with the new Equatable one; AppController now resolves to the
  new identical-member struct, still compiles+runs). Kept S3CredentialsResult name distinct from the
  old S3CredentialsPromptResult so no collision (old S3CredentialsPrompt.swift still used by
  AppController until step e). VM verify running.
- 2026-06-06: PHASE B Step c1 (AppStore + fake store tests) DONE + green locally (62 unit tests).
  Added AppStore.swift (@MainActor ObservableObject: dispatch->reduce->run(effect); the three
  pollers via drivePoller with the MainActor-atomic restart handshake [no MainActor.run needed since
  Task{} in @MainActor is MainActor-isolated]; auto-merge/stale timers + scheduleAutoMergeSoon; the
  start-flow with passphrase-retry storing the passphrase ONLY after a successful retry [Bug A];
  runTestDraft + the file/S3 test flow via Prompter+gateway; chooseLocalDirectory NSOpenPanel +
  security-scoped bookmarks; loadSyncTargets/promptAndAddSyncTarget/removeSyncTarget; userFacingMessage
  /isNetwork). Init gotcha hit + fixed: @MainActor prompter/notifier can't be default-arg values ->
  defaulted nil, built in the @MainActor init body (the iOS gotcha). swiftlint: disabled
  cyclomatic_complexity on run(_:) (effect dispatch switch). Added AppStoreTest.swift +
  FakeWorkspaceGateway (records calls, queues errors): pins Bug A ordering (store AFTER successful
  start), no-store-on-retry-fail, cancel-passphrase->idle, start->poll->completion records lastMerge,
  test-flow verifies existing file repo. Store is additive (app still on AppController). VERIFIED GREEN
  on the VM (62 unit + all integration). STEPS a+b+c1 COMPLETE: the whole pure+boundary+store
  foundation of the rewrite is done & VM-green; only the view flip (d) + delete (e) remain.
- 2026-06-06: PHASE B Steps d+e (THE FLIP + delete) done locally; app BUILD SUCCEEDED, fmt+lint clean;
  VM acceptance gate (XCUITest must pass with ZERO edits) RUNNING. Did d+e together because
  AppMenuBuilder/PreferencesView/the 3 progress views are shared with AppController (can't coexist).
  ADDED: MenuSnapshot.swift (pure Equatable menu projection + AppState.menuSnapshot()), AppDelegate.swift
  (NSApplicationDelegate + UNUserNotificationCenterDelegate; owns AppStore; renders on store.$state via
  Combine .receive(on:RunLoop.main) [defer needed: @Published fires in willSet before commit]; tray icon
  + animator + test-menu-host port), WindowCoordinator.swift (diffs openWindows/preferencesOpen -> NSWindows;
  titlebar-close folds back through reducer; re-entrancy-safe by nil-ing dict+delegate before close),
  OperationProgressView.swift (unifies the 3 progress views; per-kind error id/cancel label/Status-Merge
  button/placeholder via small switches). REWROTE: AppMenuBuilder.swift -> enum build(snapshot:actions:) +
  @objc MenuActions (running-summary uses operationClicked(runningKind), notification tap uses
  openProgressWindowRequested), PreferencesView.swift -> store-bound (custom Bindings dispatch
  draftAccessEdited/draftMetadataEdited/settings events; all a11y ids preserved). MOVED autoMerge UI picker
  helpers onto AutoMergePolicy. ADDED events openLocalFolderClicked + openProgressWindowRequested.
  Main.swift: AppController()->AppDelegate(). DELETED: AppController.swift, AutoMerge.swift,
  MergeProgressView/StatusProgressView/SyncProgressView.swift, S3CredentialsPrompt.swift. swiftlint: run(_:)
  cyclomatic disabled.
- 2026-06-06: FLIP FIX + VERIFIED GREEN. First VM run failed: all XCUI tests died early waiting for
  localFolderField at launch. Root cause: old launch called showPreferences() which CREATES a starter
  workspace when empty (so the editor shows); my stateLoaded only set preferencesOpen. Fix: onStart
  dispatches .openPreferencesClicked when state.workspaces.isEmpty (the launch-orchestration belongs in
  onStart, not the reducer; the emptyLaunchOpensPreferences reducer test stays valid). Re-ran VM: FULL
  SUITE GREEN - all 5 XCUI tests pass with ZERO test edits + 62 unit + all integration. THE macOS MVP
  REWRITE IS COMPLETE: app runs entirely on AppStore + reducers + gateways + projection views;
  AppController/AutoMerge/3 progress views/S3CredentialsPrompt deleted. Verified the new AppMenuBuilder
  matches the old contract exactly (ids use WorkspaceState.localPath == config.normalizedLocalDirectory;
  lastMergeText strings identical).
- 2026-06-06: Added a "Test reminder in 5s" debug button (Options > Health, id testReminderButton),
  parity with iOS ReminderTestTab + the existing "Schedule auto merge in 5s". macOS's reminder = the
  staleness notification, and neither the old macOS app nor my flip had an on-demand trigger. New
  event .testReminderRequested -> reducer FORCES a "Merge overdue" postNotification for every complete
  workspace (ignores the staleness threshold + throttle, no tracking mutation); store.scheduleReminderSoon()
  (5s timer + requestAuthorization, mirrors scheduleAutoMergeSoon). Suppressed under isTestMode like all
  notifications. 63 unit tests green (added testReminderForcesNotificationForCompleteWorkspacesOnly).
- 2026-06-06: BUG FIX (flip regression, user-found): an already-open but backgrounded window
  (Settings, progress) could not be re-fronted by clicking its menu item again, and accessory apps
  have no window list to reach it. Root cause: re-clicking changes no state (preferencesOpen already
  true / WindowKey already present) -> no render; WindowCoordinator only opened-when-absent, never
  re-fronted. The OLD app's show*() always did NSApp.activate + makeKeyAndOrderFront. Fix: fronting is
  a transient command = an Effect. Added Effect.focusPreferences + .focusProgressWindow(id,kind);
  reducer emits them on openPreferencesClicked + operationClicked(open) + openProgressWindowRequested +
  beginOperation(presentWindow); WindowFronting protocol on WindowCoordinator (NSApp.activate +
  makeKeyAndOrderFront, no-op if window not yet open so render still opens+fronts first-time); AppStore
  weak windowFronter set by AppDelegate; store.run forwards the effects. 64 unit tests green (added
  reopeningPreferencesEmitsFocus; updated 2 effect-list assertions). Launched an adversarial review
  workflow to hunt sibling window/lifecycle regressions XCUI misses.
- 2026-06-06: ADVERSARIAL REVIEW (15-agent workflow, old AppController vs flipped layer, XCUI-blind
  paths) found 7 confirmed regressions; FIXED 6, 1 is intended. 66 unit tests green; VM verifying.
  [7 FIXED] Status-window "Merge" button routed through operationClicked -> re-opened a prior
  failed-merge window instead of starting; now dispatches operationStartRequested (always starts).
  [6 FIXED] passphrase-cancel / no-sync-targets left an empty idle progress window open;
  operationStartCancelled now also removes the WindowKey. [3 FIXED] removing a workspace while its
  progress window was open blanked the header; removeWorkspaceClicked now filters its WindowKeys out
  of openWindows (closes the windows). [2 FIXED] open progress-window titlebar went stale on rename;
  WindowCoordinator.render now refreshes titles. [5 FIXED] cancel-failure alert collapsed to a generic
  "Cancel Failed"; added OperationKind.cancelFailureAlertTitle (Cancel Merge/Status Failed, Abort Sync
  Failed). [4 FIXED/cleanup] AppState.isSaving was never set true (save is synchronous) -> removed the
  dead field + its 5 readers. [1 INTENDED, not changed] merge-window "Last Merge" now reads the
  app-recorded lastSuccessfulMerge (matches the menu) instead of the old window's FS refs/head mtime;
  this is the deliberate Bug E single-source decision (so a fresh setup pointing at an already-synced
  folder shows "Last Merge: never" in BOTH menu and window). Offer to the user: switch the source to
  on-disk mtime for both if they want external-merge recency.
- 2026-06-06: Tried the FS-mtime switch (user asked "read refs/head mtime"); REVERTED - local-FS can't
  work. Traced cling-sync: refs/head is written to the REPOSITORY storage (WriteRef(ws.Storage,"head")),
  REMOTE for S3 (no local file) -> stays "never" after merge (VM caught it: age never appeared). The
  WORKSPACE head (.cling/workspace/refs/head) IS local but created at config time (empty rev) -> breaks
  the never-before-merge XCUI assertion. No local file gives both never-until-merged AND real recency.
  Repo's true last-merge time (incl. other devices / S3) needs a bridge call reading the head revision
  timestamp, but storage exposes no modtime and the revision is encrypted (needs saved passphrase);
  cling-sync is read-only. Reverted to app-recorded (66 tests green). DECISION PENDING with user.
- 2026-06-07: RESOLVED (user pointed to the WORKSPACE refs/head, not repository). "Last Merge" now
  reads <localDir>/.cling/workspace/refs/head: LOCAL for all repo types, written by a merge
  (WriteRef(ws.Storage,"head",newHead) in merge.go). CreateWorkspace writes the ROOT revision
  (RevisionId{} = all-zero hex, plaintext via hex.EncodeToString) at config; refs are plaintext so no
  passphrase. Gateway.lastMergeDate reads the file, treats all-zero content as "never" (nil), else
  returns the file mtime. So: brand-new folder -> root -> "never" (XCUI passes); after merge -> real
  rev + mtime -> "X ago"; pointing at an EXISTING workspace folder (synced from another device) ->
  CreateWorkspace sees it exists (ErrStorageAlreadyExists), doesn't reset -> real head + mtime ->
  "X ago" (the user's goal). lastMergeMtime field (transient, store-refreshed via .refreshMergeMtimes
  on stateLoaded/upsert/recordSuccessfulMerge -> mergeMtimesRefreshed event); lastSuccessfulMerge kept
  for staleness only. 67 unit tests green. VERIFIED GREEN on the VM (all XCUI pass): brand-new folder
  reads "never", a successful merge turns it into a real age. "Last Merge" now reflects real recency.
- REMAINING (optional): A4b real-bridge store tests (fakes already cover the logic) + an adversarial
  review of paths XCUI doesn't exercise (notification tap, stale notifications, Browse NSOpenPanel,
  removeWorkspace - all ported faithfully + reducer-unit-tested, low risk).
- DEFERRED/OPTIONAL: A4b (real-bridge store tests: go/unit_test.go provisioning server + TestRepo.swift +
  StoreConnect/BridgeSmoke; fake tests already cover the logic, so A4b is added confidence + the
  mock-keychain-file assertion). Then adversarial review of the whole rewrite.
