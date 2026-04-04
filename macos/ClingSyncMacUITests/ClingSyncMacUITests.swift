import XCTest

final class ClingSyncMacUITests: XCTestCase {
    struct UITestConfig: Decodable {
        let defaultsSuite: String
        let serverUrl: String
        let passphrase: String
        let localDir: String
        let secondLocalDir: String
        let author: String
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

        let predicate = NSPredicate(
            format: "value CONTAINS[c] %@ OR value CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@",
            "added",
            "No changes",
            "added",
            "No changes",
        )
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: status)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 30), .completed)
    }

    private func closeStatusProgressWindow(in app: XCUIApplication) {
        let closeButton = app.buttons["Close"]
        XCTAssertTrue(closeButton.waitForExistence(timeout: 5), "Close button not found in status progress window")
        closeButton.tap()
    }

    private func waitForMergeToFinish(in app: XCUIApplication) {
        let status = app.staticTexts["testStatusLabel"]
        XCTAssertTrue(status.waitForExistence(timeout: 5), "testStatusLabel not found")

        let predicate = NSPredicate(
            format: "value CONTAINS[c] %@ OR value CONTAINS[c] %@ OR label CONTAINS[c] %@ OR label CONTAINS[c] %@",
            "merged",
            "up to date",
            "merged",
            "up to date",
        )
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: status)
        XCTAssertEqual(XCTWaiter().wait(for: [expectation], timeout: 30), .completed)
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
