import XCTest

final class ClingSyncUITests: XCTestCase {
    private static let passphrase = "testpassphrase"
    private static let hostURL = "http://127.0.0.1:9124"

    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments = ["--reset", "--ui-test-mode"]
        app.launchEnvironment["CLING_SYNC_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CLING_SYNC_UI_TEST_HOST_URL"] = Self.hostURL
        app.launchEnvironment["CLING_SYNC_UI_TEST_REPO_PATH_PREFIX"] = "/uitest"
        app.launchEnvironment["CLING_SYNC_UI_TEST_AUTHOR"] = "Testinger"
        app.resetAuthorizationStatus(for: .photos)
        app.launch()

        addUIInterruptionMonitor(withDescription: "Photo Library Permission") { alert in
            let allowButton = alert.buttons.element(boundBy: 1)
            if allowButton.exists {
                allowButton.tap()
                return true
            }
            return false
        }
    }

    @MainActor
    func testHappyPath() async throws {
        waitForMainScreen()
        openSettingsFromMainScreen()
        verifyConnectionWithoutSavingPassphrase()
        app.navigationBars["Repository Settings"].buttons["Cancel"].tap()
        waitForMainScreen()

        // Upload first photo — repository is already open from test connection.
        selectPhoto("IMG_0001.JPG")
        app.buttons["Upload"].tap()
        waitForUploadSuccess(fileCount: 1)
        app.buttons["OK"].tap()

        // Change path prefix — this invalidates the open repository.
        openSettingsFromMainScreen()
        changeRepoPathPrefix("uitest/sub")
        app.navigationBars["Repository Settings"].buttons["Save"].tap()
        waitForMainScreen()

        // Upload second photo — needs re-authentication due to path prefix change.
        selectPhoto("IMG_0004.JPG")
        app.buttons["Upload"].tap()
        XCTAssertTrue(app.navigationBars["Repository Passphrase"].waitForExistence(timeout: 5))
        enterPassphrase(saveToKeychain: false)
        waitForUploadSuccess(fileCount: 1)
    }

    private func openSettingsFromMainScreen() {
        app.navigationBars["Cling Sync"].buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Repository Settings"].waitForExistence(timeout: 3))
    }

    private func verifyConnectionWithoutSavingPassphrase() {
        app.buttons["Test Connection"].tap()
        XCTAssertTrue(app.navigationBars["Repository Passphrase"].waitForExistence(timeout: 5))
        enterPassphrase(saveToKeychain: false)
        XCTAssertTrue(app.alerts["Connection Succeeded"].waitForExistence(timeout: 10))
        app.alerts["Connection Succeeded"].buttons["OK"].tap()
    }
    private func waitForMainScreen() {
        let mainNavBar = app.navigationBars["Cling Sync"]
        XCTAssertTrue(mainNavBar.waitForExistence(timeout: 20))
        mainNavBar.tap()
    }

    private func selectPhoto(_ name: String) {
        let photo = app.staticTexts[name]
        XCTAssertTrue(photo.waitForExistence(timeout: 20))
        photo.tap()

        let selectedText = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS '1 selected'")
        ).firstMatch
        XCTAssertTrue(selectedText.waitForExistence(timeout: 10))
    }

    private func waitForUploadSuccess(fileCount: Int) {
        let successMessage = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'Success! \(fileCount) file'")
        ).firstMatch
        XCTAssertTrue(successMessage.waitForExistence(timeout: 40))
    }

    private func changeRepoPathPrefix(_ newPrefix: String) {
        let field = app.textFields["Destination path"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        // Select all and replace.
        field.press(forDuration: 1.0)
        if app.menuItems["Select All"].waitForExistence(timeout: 2) {
            app.menuItems["Select All"].tap()
        }
        field.typeText(newPrefix)
    }

    private func enterPassphrase(saveToKeychain: Bool) {
        let passphraseField = app.secureTextFields["Passphrase"]
        XCTAssertTrue(passphraseField.waitForExistence(timeout: 5))
        passphraseField.tap()
        passphraseField.typeText(Self.passphrase)

        let saveToggle = app.switches["Save in iPhone Keychain"]
        if saveToggle.exists {
            let isOn = (saveToggle.value as? String) == "1"
            if saveToKeychain != isOn {
                saveToggle.tap()
            }
        }

        app.navigationBars["Repository Passphrase"].buttons["Continue"].tap()
    }
}
