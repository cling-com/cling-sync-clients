import Darwin
import XCTest

final class ClingSyncMacUITests: XCTestCase {
    struct UITestConfig: Decodable {
        let defaultsSuite: String
        let serverUrl: String
        let secondServerUrl: String?
        let syncTargetUrl: String?
        let controlUrl: String?
        let s3AccessKeyId: String?
        let s3AccessKey: String?
        let passphrase: String
        let localDir: String
        let secondLocalDir: String
        let author: String
        let newRepoPath: String?
    }

    private static let configPath = "/tmp/cling-sync-macos-ui-test-config.json"

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 150
    }

    // Covers both URL flows in a single xcodebuild run to save startup time.
    //
    // Workspace 1 is configured with a plain S3 URL, so we exercise the full
    // prompt flow: passphrase prompt followed by the S3 credentials prompt.
    // Workspace 2 is added later with a URL that already carries the encrypted
    // credentials in its userinfo, so the bridge connects without ever
    // surfacing the S3 prompt.
    func testConfigureAndMergeTwoWorkspaces() throws {
        let config = loadConfig()
        let app = launchApp(defaultsSuiteSuffix: "configure")

        // --- Workspace 1: plain S3 URL → passphrase prompt → S3 prompt. ---
        let localFolderField = app.textFields["localFolderField"]
        XCTAssertTrue(localFolderField.waitToAppear(timeout: 5))

        replaceText(in: localFolderField, with: config.localDir)
        replaceText(in: app.textFields["authorField"], with: config.author)

        // First try a non-S3 remote URL and verify the validation message.
        let serverURLField = app.textFields["serverURLField"]
        replaceText(in: serverURLField, with: "https://wrong.example.com")
        let testButton = app.buttons["testWorkspaceButton"]
        XCTAssertTrue(testButton.isEnabled)
        testButton.tap()
        assertPreferencesError(in: app, contains: "s3+http")
        replaceText(in: serverURLField, with: config.serverUrl)

        XCTAssertTrue(testButton.isEnabled)
        testButton.tap()
        enterPassphraseIfNeeded(in: app, saveToKeychain: false)
        enterS3CredentialsIfNeeded(in: app)
        assertNoPreferencesError(in: app, context: "after testWorkspace")

        let saveButton = app.buttons["saveWorkspaceButton"]
        XCTAssertTrue(saveButton.waitToAppear(timeout: 5))
        waitForButtonToEnable(saveButton)
        saveButton.tap()
        waitForElementToDisappear(saveButton)

        openTrayMenu(app, expecting: "Settings")
        XCTAssertTrue(app.menuItems[config.localDir].firstMatch.waitToAppear(timeout: 5))
        XCTAssertTrue(app.menuItems["Merge"].firstMatch.waitToAppear(timeout: 5))
        XCTAssertTrue(app.menuItems["Status"].firstMatch.waitToAppear(timeout: 5))
        XCTAssertTrue(app.menuItems["Open Local Folder"].firstMatch.waitToAppear(timeout: 5))
        XCTAssertTrue(app.menuItems["Settings"].firstMatch.waitToAppear(timeout: 5))

        // Run status first.
        clickWorkspaceStatusMenuItem(for: config.localDir, in: app)
        enterPassphraseIfNeeded(in: app, saveToKeychain: true)
        waitForStatusToFinish(in: app)
        closeStatusProgressWindow(in: app)

        // --- Workspace 1: exercise the background auto-merge before any manual
        // merge, while the keychain already holds the passphrase, so its first
        // recorded success is unambiguous. ---
        exerciseAutoMerge(app, localDir: config.localDir)

        clickWorkspaceMerge(app, localDir: config.localDir)
        assertNoPassphrasePrompt(in: app)
        waitForMergeToFinish(in: app)
        closeMergeProgressWindow(in: app)

        clickWorkspaceMerge(app, localDir: config.localDir)
        assertNoPassphrasePrompt(in: app)
        waitForMergeToFinish(in: app)
        closeMergeProgressWindow(in: app)

        // --- Workspace 1: register a sync target and run "Sync Repository". ---
        // The target is a second server (S3 backup) whose URL embeds the
        // encrypted credentials, so no prompts appear here.
        if let syncTargetUrl = config.syncTargetUrl, !syncTargetUrl.isEmpty {
            openTrayMenu(app, expecting: "Settings")
            app.menuItems["Settings"].firstMatch.click()

            let addTargetButton = app.buttons["addSyncTargetButton"]
            XCTAssertTrue(addTargetButton.waitToAppear(timeout: 5), "addSyncTargetButton not found")
            addTargetButton.tap()

            replaceText(in: app.textFields["syncTargetNameField"], with: "backup")
            replaceText(in: app.textFields["syncTargetRepositoryField"], with: syncTargetUrl)
            app.buttons["Add"].firstMatch.tap()

            XCTAssertTrue(
                app.staticTexts["backup"].waitToAppear(timeout: 5), "sync target not listed after adding")

            closePreferences(in: app)

            openTrayMenu(app, expecting: "Sync Repository")
            clickWorkspaceSyncMenuItem(for: config.localDir, in: app)
            enterPassphraseIfNeeded(in: app, saveToKeychain: false)
            waitForSyncToFinish(in: app)
            closeSyncProgressWindow(in: app)
        }

        // --- Workspace 2: URL with embedded credentials → no S3 prompt. ---
        guard let secondServerUrl = config.secondServerUrl, !secondServerUrl.isEmpty else {
            XCTFail("secondServerUrl missing from UI test config")
            return
        }
        openTrayMenu(app, expecting: "Settings")
        let settingsItem = app.menuItems["Settings"].firstMatch
        XCTAssertTrue(settingsItem.waitToAppear(timeout: 5))
        settingsItem.click()

        app.buttons["addFolderButton"].tap()
        replaceText(in: app.textFields["localFolderField"], with: config.secondLocalDir)
        replaceText(in: app.textFields["serverURLField"], with: secondServerUrl)
        replaceText(in: app.textFields["authorField"], with: config.author)

        XCTAssertTrue(testButton.isEnabled)
        testButton.tap()
        enterPassphraseIfNeeded(in: app, saveToKeychain: false)
        assertNoS3Prompt(in: app)
        assertNoPreferencesError(in: app, context: "after testWorkspace (second workspace)")

        waitForButtonToEnable(saveButton)
        saveButton.tap()
        waitForElementToDisappear(saveButton)

        openTrayMenu(app, expecting: "Settings")
        XCTAssertTrue(app.menuItems[displayName(for: config.localDir)].firstMatch.waitToAppear(timeout: 5))
        XCTAssertTrue(app.menuItems[displayName(for: config.secondLocalDir)].firstMatch.waitToAppear(timeout: 5))
        XCTAssertTrue(app.menuItems["Settings"].firstMatch.waitToAppear(timeout: 5))
        dismissMenuBarMenu(in: app)

        openTrayMenu(app, expecting: displayName(for: config.secondLocalDir))
        openSubmenu(named: displayName(for: config.secondLocalDir), in: app)
        clickWorkspaceMergeMenuItem(for: config.secondLocalDir, in: app)
        enterPassphraseIfNeeded(in: app, saveToKeychain: false)
        waitForMergeToFinish(in: app)
        closeMergeProgressWindow(in: app)
    }

    func testCreateNewRepositoryFromMissingPath() throws {
        let config = loadConfig()
        guard let newRepoPath = config.newRepoPath else {
            XCTFail("newRepoPath missing from UI test config")
            return
        }
        let app = launchApp(defaultsSuiteSuffix: "createnewrepo")

        let localFolderField = app.textFields["localFolderField"]
        XCTAssertTrue(localFolderField.waitToAppear(timeout: 5))
        replaceText(in: localFolderField, with: config.localDir)
        replaceText(in: app.textFields["serverURLField"], with: newRepoPath)
        replaceText(in: app.textFields["authorField"], with: config.author)

        // First attempt: decline the create-new-repository prompt and verify the
        // dialog stays open so the user can adjust the path.
        let testButton = app.buttons["testWorkspaceButton"]
        XCTAssertTrue(testButton.isEnabled)
        testButton.tap()
        let cancelButton = app.buttons["confirmCreateRepositoryCancelButton"]
        XCTAssertTrue(cancelButton.waitToAppear(timeout: 5))
        cancelButton.tap()
        XCTAssertTrue(localFolderField.waitToAppear(timeout: 2))
        XCTAssertFalse(app.secureTextFields["newRepositoryPassphraseField"].exists)

        // Second attempt: accept the prompt, supply a passphrase, and confirm
        // that no "save in keychain" option is offered for the new repository.
        testButton.tap()
        let createButton = app.buttons["confirmCreateRepositoryButton"]
        XCTAssertTrue(createButton.waitToAppear(timeout: 5))
        createButton.tap()

        let newPassphraseField = app.secureTextFields["newRepositoryPassphraseField"]
        XCTAssertTrue(newPassphraseField.waitToAppear(timeout: 5))
        XCTAssertFalse(
            app.checkBoxes["passphrasePromptRemember"].exists,
            "save-to-keychain checkbox should not appear when initializing a new repository",
        )
        newPassphraseField.tap()
        newPassphraseField.typeText(config.passphrase)
        let confirmCreate = app.buttons["newRepositoryPassphraseCreateButton"]
        XCTAssertTrue(confirmCreate.waitToAppear(timeout: 5))
        confirmCreate.tap()

        assertNoPreferencesError(in: app, context: "after creating new repository")

        let saveButton = app.buttons["saveWorkspaceButton"]
        XCTAssertTrue(saveButton.waitToAppear(timeout: 5))
        waitForButtonToEnable(saveButton)
        saveButton.tap()
        waitForElementToDisappear(saveButton)

        // Run an initial merge to push a seeded local file into the newly
        // created repository. The passphrase was not stored in the keychain so
        // the merge prompt should appear.
        clickWorkspaceMerge(app, localDir: config.localDir)
        enterPassphraseIfNeeded(in: app, saveToKeychain: false)
        waitForMergeToFinish(in: app)
        closeMergeProgressWindow(in: app)
    }

    // Drives a background auto-merge against a repository whose S3 server rejects
    // writes, asserts the menu surfaces "Merge (failed)" without recording a
    // success, then clears the fault and asserts the next auto-merge recovers.
    func testAutoMergeErrorThenRecovers() throws {
        let config = loadConfig()
        guard let controlURL = config.controlUrl, !controlURL.isEmpty else {
            XCTFail("controlUrl missing from UI test config")
            return
        }
        let app = launchApp(defaultsSuiteSuffix: "automergeerror")

        // Configure a workspace pointing at the fault-injecting repository. The
        // URL already embeds the credentials, so only the passphrase is prompted;
        // saving it to the keychain lets the background auto-merges run unattended.
        let localFolderField = app.textFields["localFolderField"]
        XCTAssertTrue(localFolderField.waitToAppear(timeout: 5))
        replaceText(in: localFolderField, with: config.localDir)
        replaceText(in: app.textFields["authorField"], with: config.author)
        replaceText(in: app.textFields["serverURLField"], with: config.serverUrl)

        let testButton = app.buttons["testWorkspaceButton"]
        XCTAssertTrue(testButton.isEnabled)
        testButton.tap()
        enterPassphraseIfNeeded(in: app, saveToKeychain: true)
        assertNoS3Prompt(in: app)
        assertNoPreferencesError(in: app, context: "after test (auto-merge error)")

        let saveButton = app.buttons["saveWorkspaceButton"]
        XCTAssertTrue(saveButton.waitToAppear(timeout: 5))
        waitForButtonToEnable(saveButton)
        saveButton.tap()
        waitForElementToDisappear(saveButton)

        // Fault on: the scheduled auto-merge's push fails, so the menu surfaces
        // "Merge (failed)". Auto-merge failures route to a notification
        // (suppressed in test mode), not a modal alert, so the menu is the signal.
        injectFault(controlURL: controlURL, "fail-writes?on=true")
        triggerAutoMerge(app)
        XCTAssertTrue(
            pollTrayMenu(app, timeout: 40) {
                mergeItemText(for: config.localDir, in: app) == "Merge (failed)"
            },
            "auto-merge did not reach the failed state")
        XCTAssertEqual(
            lastMergeText(for: config.localDir, in: app), "Last Merge: never",
            "a failed merge must not record a successful merge")
        dismissMenuBarMenu(in: app)

        // Recover: clear the fault and let the next auto-merge succeed, which
        // records a real "Last Merge" age and clears the failed state.
        injectFault(controlURL: controlURL, "reset")
        triggerAutoMerge(app)
        XCTAssertTrue(
            pollTrayMenu(app, timeout: 40) {
                let last = lastMergeText(for: config.localDir, in: app)
                return last != nil && last != "Last Merge: never"
            },
            "auto-merge did not recover and record a successful merge")
        XCTAssertNotEqual(
            mergeItemText(for: config.localDir, in: app), "Merge (failed)",
            "merge item stayed failed after recovery")
        dismissMenuBarMenu(in: app)
    }

    // A running operation must disable the workspace's other operations so they
    // cannot overlap, and they must re-enable once it finishes.
    func testRunningMergeDisablesSiblings() throws {
        let config = loadConfig()
        guard let controlURL = config.controlUrl, !controlURL.isEmpty else {
            XCTFail("controlUrl missing from UI test config")
            return
        }
        let app = launchApp(defaultsSuiteSuffix: "mutualexclusion")

        let localFolderField = app.textFields["localFolderField"]
        XCTAssertTrue(localFolderField.waitToAppear(timeout: 5))
        replaceText(in: localFolderField, with: config.localDir)
        replaceText(in: app.textFields["authorField"], with: config.author)
        replaceText(in: app.textFields["serverURLField"], with: config.serverUrl)

        let testButton = app.buttons["testWorkspaceButton"]
        XCTAssertTrue(testButton.isEnabled)
        testButton.tap()
        enterPassphraseIfNeeded(in: app, saveToKeychain: true)
        assertNoS3Prompt(in: app)
        assertNoPreferencesError(in: app, context: "after test (mutual exclusion)")

        let saveButton = app.buttons["saveWorkspaceButton"]
        XCTAssertTrue(saveButton.waitToAppear(timeout: 5))
        waitForButtonToEnable(saveButton)
        saveButton.tap()
        waitForElementToDisappear(saveButton)

        // Slow the repository so the background merge stays running while we
        // inspect the menu, then kick off an auto-merge (no progress window to
        // contend with the menu host button).
        injectFault(controlURL: controlURL, "latency?ms=4000")
        triggerAutoMerge(app)

        let statusIdentifier = "workspace.status.\(config.localDir)"
        XCTAssertTrue(
            pollTrayMenu(app, timeout: 40) {
                mergeItemText(for: config.localDir, in: app) == "Merge (in progress)"
            },
            "merge did not reach the in-progress state")
        let statusItem = app.menuItems[statusIdentifier].firstMatch
        XCTAssertTrue(statusItem.waitToAppear(timeout: 5))
        XCTAssertFalse(statusItem.isEnabled, "Status must be disabled while a merge runs")
        dismissMenuBarMenu(in: app)

        // Let the merge finish and confirm the siblings re-enable.
        injectFault(controlURL: controlURL, "reset")
        XCTAssertTrue(
            pollTrayMenu(app, timeout: 40) {
                mergeItemText(for: config.localDir, in: app) == "Merge"
            },
            "merge did not return to idle after finishing")
        let statusAfter = app.menuItems[statusIdentifier].firstMatch
        XCTAssertTrue(statusAfter.waitToAppear(timeout: 5))
        XCTAssertTrue(statusAfter.isEnabled, "Status must re-enable after the merge finishes")
        dismissMenuBarMenu(in: app)
    }

    private func launchApp(defaultsSuiteSuffix: String) -> XCUIApplication {
        let config = tryLoadConfig()
        let app = XCUIApplication()
        let defaultsSuite =
            config?.defaultsSuite
            ?? "com.cling.ClingSyncMac.ui.\(defaultsSuiteSuffix).\(UUID().uuidString)"
        app.launchEnvironment["CLING_SYNC_TEST_DEFAULTS_SUITE"] = defaultsSuite
        app.launchEnvironment["CLING_SYNC_TEST_MENU_HOST"] = "1"
        app.launch()
        return app
    }

    private func openTrayMenu(_ app: XCUIApplication, expecting expectedMenuItem: String) {
        app.activate()
        let button = app.buttons["testAppMenuHostButton"]
        XCTAssertTrue(button.waitToAppear(timeout: 5), "testAppMenuHostButton not found")
        let expectedItem = app.menuItems[expectedMenuItem].firstMatch
        for _ in 0..<3 {
            button.click()
            if expectedItem.waitToAppear(timeout: 2) {
                return
            }
            dismissMenuBarMenu(in: app)
        }
        XCTFail("\(expectedMenuItem) menu item not found")
    }

    private func dismissMenuBarMenu(in app: XCUIApplication) {
        if app.menuItems["Settings"].exists {
            app.typeKey(XCUIKeyboardKey.escape.rawValue, modifierFlags: [])
        }
    }

    private func clickWorkspaceMerge(_ app: XCUIApplication, localDir: String) {
        openTrayMenu(app, expecting: "Merge")
        clickWorkspaceMergeMenuItem(for: localDir, in: app)
    }

    // Drives the background auto-merge from the Options debug button and proves
    // it ran. The workspace has not merged yet, so the menu's "Last Merge:" line can
    // only turn from "never" into a real age once the scheduled merge records a
    // success. Auto-merges present no progress window, so there is nothing to
    // wait on except the menu.
    private func exerciseAutoMerge(_ app: XCUIApplication, localDir: String) {
        openTrayMenu(app, expecting: "Settings")
        XCTAssertEqual(
            lastMergeText(for: localDir, in: app), "Last Merge: never",
            "expected no recorded merge before exercising auto-merge")
        app.menuItems["Settings"].firstMatch.click()
        selectSettingsTab("Options", in: app)
        let scheduleButton = app.buttons["scheduleAutoMergeButton"]
        XCTAssertTrue(scheduleButton.waitForExistence(timeout: 5), "schedule auto merge button not found")
        scheduleButton.tap()
        // Restore the default tab so later steps find the workspace editor.
        selectSettingsTab("Workspaces", in: app)
        closeSettingsWindow(in: app)

        // The timer fires after 5s. Poll the menu until the "Last Merge:" line shows a
        // real age, which happens only after the auto-merge records a success.
        // Both menu lines are read every round so a run that never records a merge
        // reports what the menu actually showed: on its own, "no success within 30s"
        // does not say whether the merge failed, is still running, or never started.
        let deadline = Date().addingTimeInterval(30)
        var recordedMerge = false
        var lastSeen = "menu never read"
        while Date() < deadline {
            openTrayMenu(app, expecting: "Settings")
            let lastText = lastMergeText(for: localDir, in: app)
            let mergeText = mergeItemText(for: localDir, in: app)
            lastSeen = "last=\(lastText ?? "<missing>"), merge=\(mergeText ?? "<missing>")"
            if mergeText == "Merge (failed)" {
                // An auto-merge presents no progress window, so the bridge's error text
                // is only reachable by opening the failed merge from the menu.
                clickWorkspaceMergeMenuItem(for: localDir, in: app)
                let errorLabel = app.staticTexts["mergeErrorMessage"]
                let detail =
                    errorLabel.waitToAppear(timeout: 5)
                    ? elementText(errorLabel) : "no error message shown"
                XCTFail("auto-merge finished in a failed state: \(detail)")
                return
            }
            if let lastText, lastText.hasPrefix("Last Merge: "), lastText != "Last Merge: never" {
                recordedMerge = true
                dismissMenuBarMenu(in: app)
                break
            }
            dismissMenuBarMenu(in: app)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertTrue(recordedMerge, "auto-merge did not record a successful merge within 30s (\(lastSeen))")
    }

    private func lastMergeText(for localDir: String, in app: XCUIApplication) -> String? {
        let item = app.menuItems["workspace.last.\(localDir)"].firstMatch
        guard item.waitToAppear(timeout: 5) else { return nil }
        return menuItemTitle(item)
    }

    private func mergeItemText(for localDir: String, in app: XCUIApplication) -> String? {
        let item = app.menuItems[workspaceMergeIdentifier(for: localDir)].firstMatch
        guard item.exists else { return nil }
        return menuItemTitle(item)
    }

    // A menu item exposes its display text as the accessibility title, not the
    // label (which is empty once an identifier is set).
    private func menuItemTitle(_ element: XCUIElement) -> String {
        guard let snapshot = try? element.snapshot() else { return "" }
        if !snapshot.title.isEmpty {
            return snapshot.title
        }
        if let value = snapshot.value as? String, !value.isEmpty {
            return value
        }
        return snapshot.label
    }

    // Triggers a background auto-merge for every folder via the Options debug
    // button (the 5s "Schedule auto merge" timer), leaving the menu closed.
    private func triggerAutoMerge(_ app: XCUIApplication) {
        openTrayMenu(app, expecting: "Settings")
        app.menuItems["Settings"].firstMatch.click()
        selectSettingsTab("Options", in: app)
        let scheduleButton = app.buttons["scheduleAutoMergeButton"]
        XCTAssertTrue(scheduleButton.waitToAppear(timeout: 5), "schedule auto merge button not found")
        scheduleButton.tap()
        // Restore the default tab so later steps find the workspace editor.
        selectSettingsTab("Workspaces", in: app)
        closeSettingsWindow(in: app)
    }

    // Opens the tray menu and evaluates `check` with it open, polling until it
    // returns true (menu left OPEN for follow-up reads, caller dismisses) or the
    // timeout elapses (menu dismissed). Mirrors the loop in exerciseAutoMerge.
    private func pollTrayMenu(_ app: XCUIApplication, timeout: TimeInterval, check: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            openTrayMenu(app, expecting: "Settings")
            if check() {
                return true
            }
            dismissMenuBarMenu(in: app)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        return false
    }

    // Toggles fault injection on the repository's S3 server (e.g.
    // "fail-writes?on=true", "reset") via a raw socket. App Transport Security
    // blocks a URLSession cleartext request to localhost from the test runner.
    private func injectFault(controlURL: String, _ query: String) {
        guard let url = URL(string: controlURL), let host = url.host, let port = url.port else {
            XCTFail("invalid controlURL: \(controlURL)")
            return
        }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            XCTFail("socket() failed")
            return
        }
        defer { close(descriptor) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        addr.sin_addr.s_addr = inet_addr(host)
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            XCTFail("connect() to \(controlURL) failed")
            return
        }
        let request =
            "POST /__test/\(query) HTTP/1.1\r\nHost: \(host):\(port)\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
        _ = request.withCString { send(descriptor, $0, strlen($0), 0) }
        // Drain the response so the toggle is applied before we return.
        var buffer = [UInt8](repeating: 0, count: 256)
        _ = recv(descriptor, &buffer, buffer.count, 0)
    }

    private func selectSettingsTab(_ name: String, in app: XCUIApplication) {
        let candidates = [app.radioButtons[name], app.buttons[name], app.tabs[name]]
        for element in candidates where element.waitForExistence(timeout: 2) {
            element.click()
            return
        }
        XCTFail("\(name) settings tab not found")
    }

    private func closeSettingsWindow(in app: XCUIApplication) {
        let window = app.windows["Cling Sync Settings"]
        if window.waitForExistence(timeout: 2) {
            window.buttons[XCUIIdentifierCloseWindow].firstMatch.click()
        }
    }

    private func openSubmenu(named name: String, in app: XCUIApplication) {
        let item = app.menuItems[name].firstMatch
        XCTAssertTrue(item.waitToAppear(timeout: 5), "\(name) menu item not found")
        item.click()
    }

    private func clickWorkspaceStatusMenuItem(for localDir: String, in app: XCUIApplication) {
        let item = app.menuItems[workspaceStatusIdentifier(for: localDir)].firstMatch
        XCTAssertTrue(item.waitToAppear(timeout: 5), "status menu item not found for \(localDir)")
        item.click()
    }

    private func clickWorkspaceMergeMenuItem(for localDir: String, in app: XCUIApplication) {
        let item = app.menuItems[workspaceMergeIdentifier(for: localDir)].firstMatch
        XCTAssertTrue(item.waitToAppear(timeout: 5), "merge menu item not found for \(localDir)")
        item.click()
    }

    private func clickWorkspaceSyncMenuItem(for localDir: String, in app: XCUIApplication) {
        let item = app.menuItems[workspaceSyncIdentifier(for: localDir)].firstMatch
        XCTAssertTrue(item.waitToAppear(timeout: 5), "sync menu item not found for \(localDir)")
        item.click()
    }

    private func closePreferences(in app: XCUIApplication) {
        let cancelButton = app.buttons["Cancel"].firstMatch
        if cancelButton.waitToAppear(timeout: 3) {
            cancelButton.tap()
        }
    }

    private func waitForSyncToFinish(in app: XCUIApplication) {
        let status = app.staticTexts["testStatusLabel"]
        XCTAssertTrue(status.waitToAppear(timeout: 5), "testStatusLabel not found")

        let errorLabel = app.staticTexts["syncErrorMessage"]
        let result = waitForFirstMatch(
            success: { statusContains(status, ["synced"]) },
            failure: { terminalError(errorLabel) },
            timeout: 30,
        )
        switch result {
        case .success:
            return
        case .failure:
            XCTFail("sync failed with error: \(elementText(errorLabel))")
        case .timeout:
            XCTFail("sync did not finish in time; last status: \(elementText(status))")
        }
    }

    private func closeSyncProgressWindow(in app: XCUIApplication) {
        let closeButton = app.buttons["Close"]
        XCTAssertTrue(closeButton.waitToAppear(timeout: 5), "Close button not found in sync progress window")
        closeButton.tap()
    }

    private func waitForStatusToFinish(in app: XCUIApplication) {
        let status = app.staticTexts["testStatusLabel"]
        XCTAssertTrue(status.waitToAppear(timeout: 5), "testStatusLabel not found")

        // Race the success check against the error label so a failure surfaces
        // with the actual error text instead of timing out.
        let errorLabel = app.staticTexts["statusErrorMessage"]
        let result = waitForFirstMatch(
            success: { statusContains(status, ["added", "No changes"]) },
            failure: { terminalError(errorLabel) },
            timeout: 30,
        )
        switch result {
        case .success:
            return
        case .failure:
            XCTFail("status failed with error: \(elementText(errorLabel))")
        case .timeout:
            XCTFail("status did not finish in time; last status: \(elementText(status))")
        }
    }

    private func closeStatusProgressWindow(in app: XCUIApplication) {
        let closeButton = app.buttons["Close"]
        XCTAssertTrue(closeButton.waitToAppear(timeout: 5), "Close button not found in status progress window")
        closeButton.tap()
    }

    private func waitForMergeToFinish(in app: XCUIApplication) {
        let status = app.staticTexts["testStatusLabel"]
        XCTAssertTrue(status.waitToAppear(timeout: 5), "testStatusLabel not found")

        let errorLabel = app.staticTexts["mergeErrorMessage"]
        let result = waitForFirstMatch(
            success: { statusContains(status, ["merged", "up to date"]) },
            failure: { terminalError(errorLabel) },
            timeout: 30,
        )
        switch result {
        case .success:
            return
        case .failure:
            XCTFail("merge failed with error: \(elementText(errorLabel))")
        case .timeout:
            XCTFail("merge did not finish in time; last status: \(elementText(status))")
        }
    }

    private func closeMergeProgressWindow(in app: XCUIApplication) {
        let closeButton = app.buttons["Close"]
        XCTAssertTrue(closeButton.waitToAppear(timeout: 5), "Close button not found in merge progress window")
        closeButton.tap()
    }

    private func waitForButtonToEnable(_ button: XCUIElement) {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline, !button.isEnabled {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertTrue(button.isEnabled)
    }

    private func waitForElementToDisappear(_ element: XCUIElement) {
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, element.exists {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        XCTAssertFalse(element.exists)
    }

    private func enterPassphraseIfNeeded(in app: XCUIApplication, saveToKeychain: Bool) {
        let config = loadConfig()
        let field = app.secureTextFields["passphrasePromptField"]
        guard field.waitToAppear(timeout: 5) else {
            return
        }
        field.tap()
        field.typeText(config.passphrase)

        if saveToKeychain {
            // An auto-merge cannot prompt, so it only succeeds if this box is ticked.
            // The box can take a moment to appear on a loaded machine, and a tick that
            // never happens surfaces much later as a failed background merge.
            let remember = app.checkBoxes["passphrasePromptRemember"]
            XCTAssertTrue(remember.waitToAppear(timeout: 5), "save-to-keychain checkbox not found")
            // The prompt drops any floating window to the normal level while it is up,
            // so a click aimed here reaches the box instead of the progress window that
            // would otherwise cover it and eat it. The retry is for a box that has not
            // finished being presented, and is only ever taken while the box reads off,
            // since clicking one that is already ticked would clear it.
            let isChecked = { "\(remember.value ?? "")" == "1" }
            var attempts = 0
            while attempts < 4, !isChecked() {
                remember.click()
                attempts += 1
                let settle = Date().addingTimeInterval(2)
                while Date() < settle, !isChecked() {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                }
            }
            // Fails here, while the prompt is still up, instead of eight seconds later
            // as an unexplained merge failure. The window frames go into the message
            // because the failure worth telling apart is a covered box, and that is
            // only visible as another window overlapping this one.
            let windows = (0..<app.windows.count)
                .map { app.windows.element(boundBy: $0) }
                .map { "\($0.title.isEmpty ? "<untitled>" : $0.title)@\($0.frame)" }
                .joined(separator: " ")
            XCTAssertTrue(
                isChecked(),
                "save-to-keychain did not register after \(attempts) attempts "
                    + "(value=\(String(describing: remember.value)), enabled=\(remember.isEnabled), "
                    + "hittable=\(remember.isHittable), frame=\(remember.frame), "
                    + "dialogs=\(app.dialogs.count), windows=[\(windows)])")
        }

        field.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
    }

    private func assertNoPassphrasePrompt(in app: XCUIApplication) {
        let field = app.secureTextFields["passphrasePromptField"]
        XCTAssertFalse(field.waitToAppear(timeout: 2), "passphrase prompt unexpectedly appeared")
    }

    private func enterS3CredentialsIfNeeded(in app: XCUIApplication) {
        let config = loadConfig()
        let keyIdField = app.textFields["s3KeyIdField"]
        guard keyIdField.waitToAppear(timeout: 5) else {
            return
        }
        keyIdField.tap()
        keyIdField.typeText(config.s3AccessKeyId ?? "minioadmin")

        let accessKeyField = app.secureTextFields["s3AccessKeyField"]
        accessKeyField.tap()
        accessKeyField.typeText(config.s3AccessKey ?? "minioadmin")

        let continueButton = app.buttons["Continue"].firstMatch
        XCTAssertTrue(continueButton.waitToAppear(timeout: 2))
        continueButton.tap()
    }

    private func assertNoS3Prompt(in app: XCUIApplication) {
        let keyIdField = app.textFields["s3KeyIdField"]
        XCTAssertFalse(
            keyIdField.waitToAppear(timeout: 2),
            "S3 credentials prompt unexpectedly appeared for an embedded-credentials URL")
    }

    private func assertNoPreferencesError(in app: XCUIApplication, context: String) {
        let errorLabel = app.staticTexts["preferencesErrorMessage"]
        // Give SwiftUI a brief moment to bind the error message before asserting.
        if errorLabel.waitToAppear(timeout: 2) {
            XCTFail("preferences error \(context): \(elementText(errorLabel))")
        }
    }

    private func assertPreferencesError(in app: XCUIApplication, contains needle: String) {
        let errorLabel = app.staticTexts["preferencesErrorMessage"]
        XCTAssertTrue(errorLabel.waitToAppear(timeout: 5), "expected preferencesErrorMessage to appear")
        let message = elementText(errorLabel)
        XCTAssertTrue(
            message.localizedCaseInsensitiveContains(needle),
            "expected error to contain \"\(needle)\", got: \(message)")
    }

    private enum WaitOutcome {
        case success
        case failure
        case timeout
    }

    // Polls both checks roughly every 200ms and returns on the first hit.
    // XCTWaiter has no native race; it only completes when ALL expectations are
    // fulfilled, which would mask an error path entirely. The checks read element
    // state directly instead of via NSPredicate.evaluate(with: anXCUIElement):
    // evaluating a predicate forces attribute resolution that throws "Failed to
    // get matching snapshot" when the accessibility tree is momentarily empty
    // mid-transition, aborting the test instead of retrying. A guarded .exists
    // read returns false in that window rather than throwing.
    private func waitForFirstMatch(
        success: () -> Bool,
        failure: () -> Bool,
        timeout: TimeInterval,
    ) -> WaitOutcome {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if success() {
                return .success
            }
            if failure() {
                return .failure
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        if success() {
            return .success
        }
        return failure() ? .failure : .timeout
    }

    // The visible text of an element. Reads from a throwing snapshot() rather than
    // the element's properties directly: a bare `.value`/`.label` access raises
    // "Failed to get matching snapshot" when the accessibility tree is momentarily
    // empty mid-transition (even right after `.exists` returned true), which aborts
    // the test (continueAfterFailure=false). snapshot() surfaces that as a Swift
    // throw we swallow, so a transient failure returns "" and the polling caller
    // simply retries on the next pass.
    private func elementText(_ element: XCUIElement) -> String {
        guard let snapshot = try? element.snapshot() else { return "" }
        if let value = snapshot.value as? String, !value.isEmpty {
            return value
        }
        if !snapshot.label.isEmpty {
            return snapshot.label
        }
        return snapshot.title
    }

    private func statusContains(_ status: XCUIElement, _ needles: [String]) -> Bool {
        let text = elementText(status).lowercased()
        return needles.contains { text.contains($0.lowercased()) }
    }

    // A real status/merge/sync error always carries non-empty text. The error
    // label can briefly exist with empty text while SwiftUI inserts or removes it
    // (e.g. as the transient passphrase-required error clears), so an empty label
    // is a transition artifact, not a terminal failure. The "passphrase required"
    // error itself is also transient: the test answers the prompt and the
    // operation re-runs. Treat only a non-empty, non-passphrase error as terminal.
    private func terminalError(_ errorLabel: XCUIElement) -> Bool {
        let text = elementText(errorLabel)
        guard !text.isEmpty else { return false }
        return !text.lowercased().contains("passphrase")
    }

    private func replaceText(in element: XCUIElement, with value: String) {
        XCTAssertTrue(element.waitToAppear(timeout: 5))
        element.click()
        let current = elementText(element)
        if !current.isEmpty {
            element.typeKey(XCUIKeyboardKey.end, modifierFlags: [])
            for _ in 0..<current.count {
                element.typeKey(XCUIKeyboardKey.delete, modifierFlags: [])
            }
        }
        element.typeText(value)
    }

    private func displayName(for path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    private func workspaceStatusIdentifier(for path: String) -> String {
        "workspace.status.\(path)"
    }

    private func workspaceMergeIdentifier(for path: String) -> String {
        "workspace.merge.\(path)"
    }

    private func workspaceSyncIdentifier(for path: String) -> String {
        "workspace.sync.\(path)"
    }

    private func loadConfig() -> UITestConfig {
        guard let config = tryLoadConfig() else {
            XCTFail("Failed to load UI test config: missing file")
            fatalError("Failed to load UI test config: missing file")
        }
        return config
    }

    private func tryLoadConfig() -> UITestConfig? {
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: Self.configPath))
            return try JSONDecoder().decode(UITestConfig.self, from: data)
        } catch CocoaError.fileReadNoSuchFile {
            return nil
        } catch {
            XCTFail("Failed to load UI test config: \(error)")
            fatalError("Failed to load UI test config: \(error)")
        }
    }
}

extension XCUIElement {
    // waitForExistence re-evaluates its predicate on a fixed ~1s timer, so on the
    // CI VM it costs ~1s per call even though the snapshot is instant and the
    // element usually appears within a few ms. Poll fast instead.
    func waitToAppear(timeout: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if exists {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }
        return exists
    }
}
