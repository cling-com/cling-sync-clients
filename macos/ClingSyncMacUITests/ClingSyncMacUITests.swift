import XCTest

final class ClingSyncMacUITests: XCTestCase {
    struct UITestConfig: Decodable {
        let defaultsSuite: String
        let serverUrl: String
        let secondServerUrl: String?
        let syncTargetUrl: String?
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
        let cancelButton = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancelButton.waitToAppear(timeout: 5))
        cancelButton.tap()
        XCTAssertTrue(localFolderField.waitToAppear(timeout: 2))
        XCTAssertFalse(app.secureTextFields["newRepositoryPassphraseField"].exists)

        // Second attempt: accept the prompt, supply a passphrase, and confirm
        // that no "save in keychain" option is offered for the new repository.
        testButton.tap()
        let createButton = app.buttons["Create"].firstMatch
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
        let confirmCreate = app.buttons["Create"].firstMatch
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
        // real age, which happens only after the auto-merge records a success,
        // and confirm it did not leave the merge item in the failed state.
        let deadline = Date().addingTimeInterval(30)
        var recordedMerge = false
        while Date() < deadline {
            openTrayMenu(app, expecting: "Settings")
            let lastText = lastMergeText(for: localDir, in: app)
            if let lastText, lastText.hasPrefix("Last Merge: "), lastText != "Last Merge: never" {
                XCTAssertNotEqual(
                    mergeItemText(for: localDir, in: app), "Merge (failed)",
                    "auto-merge finished in a failed state")
                recordedMerge = true
                dismissMenuBarMenu(in: app)
                break
            }
            dismissMenuBarMenu(in: app)
            RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        }
        XCTAssertTrue(recordedMerge, "auto-merge did not record a successful merge within 30s")
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
        if !element.title.isEmpty {
            return element.title
        }
        if let value = element.value as? String, !value.isEmpty {
            return value
        }
        return element.label
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

        let successPredicate = NSPredicate(
            format: "value CONTAINS[c] %@ OR label CONTAINS[c] %@",
            "synced",
            "synced",
        )
        let errorLabel = app.staticTexts["syncErrorMessage"]
        let result = waitForFirstMatch(
            success: successPredicate,
            successObject: status,
            failure: terminalErrorPredicate(),
            failureObject: errorLabel,
            timeout: 30,
        )
        switch result {
        case .success:
            return
        case .failure:
            XCTFail("sync failed with error: \(errorLabel.value as? String ?? errorLabel.label)")
        case .timeout:
            XCTFail("sync did not finish in time; last status: \(status.value as? String ?? status.label)")
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

        // Race the success predicate against the error label so a failure
        // surfaces with the actual error text instead of timing out.
        let successPredicate = NSPredicate(
            format: "value CONTAINS[c] %@ OR value CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@",
            "added",
            "No changes",
            "added",
            "No changes",
        )
        let errorLabel = app.staticTexts["statusErrorMessage"]
        let result = waitForFirstMatch(
            success: successPredicate,
            successObject: status,
            failure: terminalErrorPredicate(),
            failureObject: errorLabel,
            timeout: 30,
        )
        switch result {
        case .success:
            return
        case .failure:
            XCTFail("status failed with error: \(errorLabel.value as? String ?? errorLabel.label)")
        case .timeout:
            XCTFail("status did not finish in time; last status: \(status.value as? String ?? status.label)")
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

        let successPredicate = NSPredicate(
            format: "value CONTAINS[c] %@ OR value CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@",
            "merged",
            "up to date",
            "merged",
            "up to date",
        )
        let errorLabel = app.staticTexts["mergeErrorMessage"]
        let result = waitForFirstMatch(
            success: successPredicate,
            successObject: status,
            failure: terminalErrorPredicate(),
            failureObject: errorLabel,
            timeout: 30,
        )
        switch result {
        case .success:
            return
        case .failure:
            XCTFail("merge failed with error: \(errorLabel.value as? String ?? errorLabel.label)")
        case .timeout:
            XCTFail("merge did not finish in time; last status: \(status.value as? String ?? status.label)")
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
            let remember = app.checkBoxes["passphrasePromptRemember"]
            if remember.waitToAppear(timeout: 1), remember.value as? Int != 1 {
                remember.tap()
            }
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
            let message = (errorLabel.value as? String) ?? errorLabel.label
            XCTFail("preferences error \(context): \(message)")
        }
    }

    private func assertPreferencesError(in app: XCUIApplication, contains needle: String) {
        let errorLabel = app.staticTexts["preferencesErrorMessage"]
        XCTAssertTrue(errorLabel.waitToAppear(timeout: 5), "expected preferencesErrorMessage to appear")
        let message = (errorLabel.value as? String) ?? errorLabel.label
        XCTAssertTrue(
            message.localizedCaseInsensitiveContains(needle),
            "expected error to contain \"\(needle)\", got: \(message)")
    }

    private enum WaitOutcome {
        case success
        case failure
        case timeout
    }

    // Polls both predicates roughly every 200ms and returns on the first hit.
    // XCTWaiter has no native race; it only completes when ALL expectations
    // are fulfilled, which would mask an error path entirely.
    private func waitForFirstMatch(
        success: NSPredicate,
        successObject: Any,
        failure: NSPredicate,
        failureObject: Any,
        timeout: TimeInterval,
    ) -> WaitOutcome {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if success.evaluate(with: successObject) {
                return .success
            }
            if failure.evaluate(with: failureObject) {
                return .failure
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return success.evaluate(with: successObject)
            ? .success
            : (failure.evaluate(with: failureObject) ? .failure : .timeout)
    }

    private func terminalErrorPredicate() -> NSPredicate {
        // A "passphrase required" error is transient here: the test answers the
        // prompt and the operation re-runs, clearing it a beat later (after the
        // optional keychain store). Don't latch onto it as a terminal failure.
        NSPredicate(
            format: "exists == true AND NOT (value CONTAINS[c] %@ OR label CONTAINS[c] %@)",
            "passphrase",
            "passphrase"
        )
    }

    private func replaceText(in element: XCUIElement, with value: String) {
        XCTAssertTrue(element.waitToAppear(timeout: 5))
        element.click()
        let current = (element.value as? String) ?? ""
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
