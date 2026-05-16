import XCTest

final class ClingSyncMacUITests: XCTestCase {
    struct UITestConfig: Decodable {
        let defaultsSuite: String
        let serverUrl: String
        let passphrase: String
        let localDir: String
        let secondLocalDir: String
        let author: String
        let newRepoPath: String?
    }

    private static let configPath = "/tmp/cling-sync-macos-ui-test-config.json"

    override func setUpWithError() throws {
        continueAfterFailure = false
        executionTimeAllowance = 90
    }

    func testConfigureSingleWorkspaceMenuAndMerge() throws {
        let config = loadConfig()
        let app = launchApp(defaultsSuiteSuffix: "configure")

        // Settings auto-creates a workspace when empty.
        let localFolderField = app.textFields["localFolderField"]
        XCTAssertTrue(localFolderField.waitForExistence(timeout: 5))

        replaceText(in: localFolderField, with: config.localDir)
        replaceText(in: app.textFields["serverURLField"], with: config.serverUrl)
        replaceText(in: app.textFields["authorField"], with: config.author)

        let testButton = app.buttons["testWorkspaceButton"]
        XCTAssertTrue(testButton.isEnabled)
        testButton.tap()
        enterPassphraseIfNeeded(in: app, saveToKeychain: false)
        assertNoPreferencesError(in: app, context: "after testWorkspace")

        let saveButton = app.buttons["saveWorkspaceButton"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
        waitForButtonToEnable(saveButton)
        saveButton.tap()
        waitForElementToDisappear(saveButton)

        openTrayMenu(app, expecting: "Settings")
        XCTAssertTrue(app.menuItems[config.localDir].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Merge"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Status"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Open Local Folder"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Settings"].firstMatch.waitForExistence(timeout: 5))

        // Run status first.
        clickWorkspaceStatusMenuItem(for: config.localDir, in: app)
        enterPassphraseIfNeeded(in: app, saveToKeychain: true)
        waitForStatusToFinish(in: app)
        closeStatusProgressWindow(in: app)

        clickWorkspaceMerge(app, localDir: config.localDir)
        assertNoPassphrasePrompt(in: app)
        waitForMergeToFinish(in: app)
        closeMergeProgressWindow(in: app)

        clickWorkspaceMerge(app, localDir: config.localDir)
        assertNoPassphrasePrompt(in: app)
        waitForMergeToFinish(in: app)
        closeMergeProgressWindow(in: app)
    }

    func testAddSecondWorkspaceAndMergeIt() throws {
        let config = loadConfig()
        let app = launchApp(defaultsSuiteSuffix: "merge")

        openTrayMenu(app, expecting: "Settings")
        let settingsItem = app.menuItems["Settings"].firstMatch
        XCTAssertTrue(settingsItem.waitForExistence(timeout: 5))
        settingsItem.click()

        app.buttons["addFolderButton"].tap()
        replaceText(in: app.textFields["localFolderField"], with: config.secondLocalDir)
        replaceText(in: app.textFields["serverURLField"], with: config.serverUrl)
        replaceText(in: app.textFields["authorField"], with: config.author)

        let testButton = app.buttons["testWorkspaceButton"]
        XCTAssertTrue(testButton.isEnabled)
        testButton.tap()
        enterPassphraseIfNeeded(in: app, saveToKeychain: false)
        assertNoPreferencesError(in: app, context: "after testWorkspace (second workspace)")

        let saveButton = app.buttons["saveWorkspaceButton"]
        waitForButtonToEnable(saveButton)
        saveButton.tap()
        waitForElementToDisappear(saveButton)

        openTrayMenu(app, expecting: "Settings")
        XCTAssertTrue(app.menuItems[displayName(for: config.localDir)].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems[displayName(for: config.secondLocalDir)].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.menuItems["Settings"].firstMatch.waitForExistence(timeout: 5))
        dismissMenuBarMenu(in: app)

        openTrayMenu(app, expecting: displayName(for: config.secondLocalDir))
        openSubmenu(named: displayName(for: config.secondLocalDir), in: app)
        clickWorkspaceMergeMenuItem(for: config.secondLocalDir, in: app)
        enterPassphraseIfNeeded(in: app, saveToKeychain: true)
        waitForMergeToFinish(in: app)
        closeMergeProgressWindow(in: app)

        openTrayMenu(app, expecting: displayName(for: config.secondLocalDir))
        openSubmenu(named: displayName(for: config.secondLocalDir), in: app)
        clickWorkspaceMergeMenuItem(for: config.secondLocalDir, in: app)
        assertNoPassphrasePrompt(in: app)
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
        XCTAssertTrue(localFolderField.waitForExistence(timeout: 5))
        replaceText(in: localFolderField, with: config.localDir)
        replaceText(in: app.textFields["serverURLField"], with: newRepoPath)
        replaceText(in: app.textFields["authorField"], with: config.author)

        // First attempt: decline the create-new-repository prompt and verify the
        // dialog stays open so the user can adjust the path.
        let testButton = app.buttons["testWorkspaceButton"]
        XCTAssertTrue(testButton.isEnabled)
        testButton.tap()
        let cancelButton = app.buttons["Cancel"].firstMatch
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5))
        cancelButton.tap()
        XCTAssertTrue(localFolderField.waitForExistence(timeout: 2))
        XCTAssertFalse(app.secureTextFields["newRepositoryPassphraseField"].exists)

        // Second attempt: accept the prompt, supply a passphrase, and confirm
        // that no "save in keychain" option is offered for the new repository.
        testButton.tap()
        let createButton = app.buttons["Create"].firstMatch
        XCTAssertTrue(createButton.waitForExistence(timeout: 5))
        createButton.tap()

        let newPassphraseField = app.secureTextFields["newRepositoryPassphraseField"]
        XCTAssertTrue(newPassphraseField.waitForExistence(timeout: 5))
        XCTAssertFalse(
            app.checkBoxes["passphrasePromptRemember"].exists,
            "save-to-keychain checkbox should not appear when initializing a new repository",
        )
        newPassphraseField.tap()
        newPassphraseField.typeText(config.passphrase)
        let confirmCreate = app.buttons["Create"].firstMatch
        XCTAssertTrue(confirmCreate.waitForExistence(timeout: 5))
        confirmCreate.tap()

        assertNoPreferencesError(in: app, context: "after creating new repository")

        let saveButton = app.buttons["saveWorkspaceButton"]
        XCTAssertTrue(saveButton.waitForExistence(timeout: 5))
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
        XCTAssertTrue(button.waitForExistence(timeout: 5), "testAppMenuHostButton not found")
        let expectedItem = app.menuItems[expectedMenuItem].firstMatch
        for _ in 0..<3 {
            button.click()
            if expectedItem.waitForExistence(timeout: 2) {
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

    private func openSubmenu(named name: String, in app: XCUIApplication) {
        let item = app.menuItems[name].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "\(name) menu item not found")
        item.click()
    }

    private func clickWorkspaceStatusMenuItem(for localDir: String, in app: XCUIApplication) {
        let item = app.menuItems[workspaceStatusIdentifier(for: localDir)].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "status menu item not found for \(localDir)")
        item.click()
    }

    private func clickWorkspaceMergeMenuItem(for localDir: String, in app: XCUIApplication) {
        let item = app.menuItems[workspaceMergeIdentifier(for: localDir)].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "merge menu item not found for \(localDir)")
        item.click()
    }

    private func waitForStatusToFinish(in app: XCUIApplication) {
        let status = app.staticTexts["testStatusLabel"]
        XCTAssertTrue(status.waitForExistence(timeout: 5), "testStatusLabel not found")

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
            failure: existsPredicate(),
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
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5), "Close button not found in status progress window")
        closeButton.tap()
    }

    private func waitForMergeToFinish(in app: XCUIApplication) {
        let status = app.staticTexts["testStatusLabel"]
        XCTAssertTrue(status.waitForExistence(timeout: 5), "testStatusLabel not found")

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
            failure: existsPredicate(),
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
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5), "Close button not found in merge progress window")
        closeButton.tap()
    }

    private func waitForButtonToEnable(_ button: XCUIElement) {
        let predicate = NSPredicate(format: "enabled == true")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: button)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 30), .completed)
    }

    private func waitForElementToDisappear(_ element: XCUIElement) {
        let predicate = NSPredicate(format: "exists == false")
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 10), .completed)
    }

    private func enterPassphraseIfNeeded(in app: XCUIApplication, saveToKeychain: Bool) {
        let config = loadConfig()
        let field = app.secureTextFields["passphrasePromptField"]
        guard field.waitForExistence(timeout: 5) else {
            return
        }
        field.tap()
        field.typeText(config.passphrase)

        if saveToKeychain {
            let remember = app.checkBoxes["passphrasePromptRemember"]
            if remember.waitForExistence(timeout: 1), remember.value as? Int != 1 {
                remember.tap()
            }
        }

        field.typeKey(XCUIKeyboardKey.return.rawValue, modifierFlags: [])
    }

    private func assertNoPassphrasePrompt(in app: XCUIApplication) {
        let field = app.secureTextFields["passphrasePromptField"]
        XCTAssertFalse(field.waitForExistence(timeout: 2), "passphrase prompt unexpectedly appeared")
    }

    private func assertNoPreferencesError(in app: XCUIApplication, context: String) {
        let errorLabel = app.staticTexts["preferencesErrorMessage"]
        // Give SwiftUI a brief moment to bind the error message before asserting.
        if errorLabel.waitForExistence(timeout: 2) {
            let message = (errorLabel.value as? String) ?? errorLabel.label
            XCTFail("preferences error \(context): \(message)")
        }
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

    private func existsPredicate() -> NSPredicate {
        NSPredicate(format: "exists == true")
    }

    private func replaceText(in element: XCUIElement, with value: String) {
        XCTAssertTrue(element.waitForExistence(timeout: 5))
        element.tap()
        element.typeKey("a", modifierFlags: .command)
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
