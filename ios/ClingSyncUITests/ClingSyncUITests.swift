import XCTest

final class ClingSyncUITests: XCTestCase {
    private static let passphrase = "testpassphrase"
    private static let hostURL = "s3+http://127.0.0.1:9124"
    private static let embeddedHostURL =
        ProcessInfo.processInfo.environment["TEST_HOST_URL_EMBEDDED"] ?? ""
    private static let s3AccessKeyId =
        ProcessInfo.processInfo.environment["TEST_S3_ACCESS_KEY_ID"] ?? "minioadmin"
    private static let s3AccessKey =
        ProcessInfo.processInfo.environment["TEST_S3_ACCESS_KEY"] ?? "minioadmin"

    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    private func launchApp(hostURL: String) {
        app.launchArguments = ["--reset", "--ui-test-mode"]
        app.launchEnvironment["CLING_SYNC_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CLING_SYNC_UI_TEST_HOST_URL"] = hostURL
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
        launchApp(hostURL: Self.hostURL)

        waitForMainScreen()
        openSettingsFromMainScreen()
        rejectInvalidHostURL()
        // Cancel dismisses the in-memory invalid URL. Re-open settings so the
        // field reloads from @AppStorage (the valid launch-time URL).
        app.navigationBars["Repository Settings"].buttons["Cancel"].tap()
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

        // Change path prefix — connection stays open (prefix is client-side only).
        openSettingsFromMainScreen()
        changeRepoPathPrefix("uitest/sub")
        app.navigationBars["Repository Settings"].buttons["Save"].tap()
        waitForMainScreen()

        // Upload second photo — no re-authentication needed.
        selectPhoto("IMG_0004.JPG")
        app.buttons["Upload"].tap()
        waitForUploadSuccess(fileCount: 1)
    }

    // A URL with the encrypted S3 credentials already embedded in its userinfo
    // should connect without ever showing the S3 credentials prompt.
    @MainActor
    func testEmbeddedCredentialsURLSkipsS3Prompt() async throws {
        guard !Self.embeddedHostURL.isEmpty else {
            throw XCTSkip("TEST_HOST_URL_EMBEDDED not set. Run via go test harness.")
        }
        launchApp(hostURL: Self.embeddedHostURL)

        waitForMainScreen()
        openSettingsFromMainScreen()
        app.buttons["Test Connection"].tap()
        XCTAssertTrue(app.navigationBars["Repository Passphrase"].waitForExistence(timeout: 5))
        enterPassphrase(saveToKeychain: false)

        // No S3 dialog should appear. Connection should succeed directly.
        let s3Nav = app.navigationBars["S3 Credentials"]
        XCTAssertFalse(
            s3Nav.waitForExistence(timeout: 3),
            "S3 credentials prompt unexpectedly appeared for an embedded-credentials URL")
        XCTAssertTrue(app.alerts["Connection Succeeded"].waitForExistence(timeout: 10))
        app.alerts["Connection Succeeded"].buttons["OK"].tap()
    }

    private func openSettingsFromMainScreen() {
        app.navigationBars["Cling Sync"].buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Repository Settings"].waitForExistence(timeout: 3))
    }

    // Replaces the Host URL with a non-S3 value and verifies that Test
    // Connection surfaces the validation alert. The caller is responsible for
    // restoring the URL (typically by dismissing and re-opening settings).
    private func rejectInvalidHostURL() {
        let field = app.textFields["Host URL"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        replaceText(in: field, with: "https://wrong.example.com")
        app.buttons["Test Connection"].tap()
        let alert = app.alerts["Settings Error"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["OK"].tap()
    }

    private func replaceText(in field: XCUIElement, with value: String) {
        field.tap()
        if let current = field.value as? String, !current.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(value)
    }

    private func verifyConnectionWithoutSavingPassphrase() {
        app.buttons["Test Connection"].tap()
        XCTAssertTrue(app.navigationBars["Repository Passphrase"].waitForExistence(timeout: 5))
        enterPassphrase(saveToKeychain: false)
        enterS3CredentialsIfPrompted()
        XCTAssertTrue(app.alerts["Connection Succeeded"].waitForExistence(timeout: 10))
        app.alerts["Connection Succeeded"].buttons["OK"].tap()
    }

    private func enterS3CredentialsIfPrompted() {
        let s3Nav = app.navigationBars["S3 Credentials"]
        guard s3Nav.waitForExistence(timeout: 5) else {
            return
        }
        let keyIdField = app.textFields["S3 Key ID"]
        XCTAssertTrue(keyIdField.waitForExistence(timeout: 3))
        keyIdField.tap()
        keyIdField.typeText(Self.s3AccessKeyId)

        let accessKeyField = app.secureTextFields["S3 Access Key"]
        accessKeyField.tap()
        accessKeyField.typeText(Self.s3AccessKey)

        s3Nav.buttons["Continue"].tap()
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
        replaceText(in: field, with: newPrefix)
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
