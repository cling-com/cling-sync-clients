import XCTest

final class ClingSyncUITests: XCTestCase {
    static let passphrase = "testpassphrase"
    static let wrongPassphrase = "definitely-the-wrong-passphrase"
    static let hostURL =
        ProcessInfo.processInfo.environment["TEST_HOST_URL"] ?? "s3+http://127.0.0.1:9124"
    static let embeddedHostURL =
        ProcessInfo.processInfo.environment["TEST_HOST_URL_EMBEDDED"] ?? ""
    static let switchURL =
        ProcessInfo.processInfo.environment["TEST_SWITCH_URL"] ?? ""
    static let multiURL =
        ProcessInfo.processInfo.environment["TEST_MULTI_URL"] ?? ""
    static let abortURL =
        ProcessInfo.processInfo.environment["TEST_ABORT_URL"] ?? ""
    static let abortControlURL =
        ProcessInfo.processInfo.environment["TEST_ABORT_CONTROL_URL"] ?? ""
    static let failureURL =
        ProcessInfo.processInfo.environment["TEST_FAILURE_URL"] ?? ""
    static let failureControlURL =
        ProcessInfo.processInfo.environment["TEST_FAILURE_CONTROL_URL"] ?? ""
    static let shareURL =
        ProcessInfo.processInfo.environment["TEST_SHARE_URL"] ?? ""
    static let s3AccessKeyId =
        ProcessInfo.processInfo.environment["TEST_S3_ACCESS_KEY_ID"] ?? "minioadmin"
    static let s3AccessKey =
        ProcessInfo.processInfo.environment["TEST_S3_ACCESS_KEY"] ?? "minioadmin"

    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
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

        // Upload the first photo. The repository is already open from the test connection.
        selectPhoto("IMG_0001.JPG")
        app.buttons["Upload"].tap()
        waitForUploadSuccess(fileCount: 1)
        app.buttons["OK"].tap()

        // Change the path prefix. The connection stays open because the prefix is client-side only.
        openSettingsFromMainScreen()
        changeRepoPathPrefix("uitest/sub")
        app.navigationBars["Repository Settings"].buttons["Save"].tap()
        waitForMainScreen()

        // Upload the second photo. No re-authentication is needed.
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
        XCTAssertTrue(app.navigationBars["Repository Passphrase"].waitToAppear(timeout: 5))
        enterPassphrase(saveToKeychain: false)

        // No S3 dialog should appear. Connection should succeed directly.
        let s3Nav = app.navigationBars["S3 Credentials"]
        XCTAssertFalse(
            s3Nav.waitToAppear(timeout: 3),
            "S3 credentials prompt unexpectedly appeared for an embedded-credentials URL")
        XCTAssertTrue(app.alerts["Connection Succeeded"].waitToAppear(timeout: 10))
        app.alerts["Connection Succeeded"].buttons["OK"].tap()
    }

    // A wrong passphrase surfaces the Settings Error alert (the open fails after
    // the S3 credentials are entered and encoded with the wrong passphrase), and
    // the user can recover by retrying with the correct passphrase. The recovery
    // leg guards against the failed attempt persisting a wrong-passphrase encoded
    // URI that would lock the user out.
    @MainActor
    func testWrongPassphraseShowsErrorThenRecovers() async throws {
        launchApp(hostURL: Self.hostURL)

        waitForMainScreen()
        openSettingsFromMainScreen()
        app.buttons["Test Connection"].tap()
        enterPassphrase(Self.wrongPassphrase, saveToKeychain: false)
        enterS3CredentialsIfPrompted()

        let alert = app.alerts["Settings Error"]
        XCTAssertTrue(alert.waitToAppear(timeout: 20))
        alert.buttons["OK"].tap()
        // The settings dialog stays usable (no stuck "Testing connection..." overlay).
        XCTAssertTrue(app.buttons["Test Connection"].waitToAppear(timeout: 5))

        app.buttons["Test Connection"].tap()
        enterPassphrase(saveToKeychain: false)
        enterS3CredentialsIfPrompted()
        XCTAssertTrue(app.alerts["Connection Succeeded"].waitToAppear(timeout: 10))
        app.alerts["Connection Succeeded"].buttons["OK"].tap()
    }

    // Cancelling the passphrase prompt must not leave a stuck "Testing
    // connection..." overlay. The settings dialog stays usable.
    @MainActor
    func testCancelPassphrasePromptRecoverable() async throws {
        launchApp(hostURL: Self.hostURL)

        waitForMainScreen()
        openSettingsFromMainScreen()
        app.buttons["Test Connection"].tap()
        XCTAssertTrue(app.navigationBars["Repository Passphrase"].waitToAppear(timeout: 5))
        app.navigationBars["Repository Passphrase"].buttons["Cancel"].tap()

        // Cancelling surfaces a dismissable error. The dialog stays usable.
        let alert = app.alerts["Settings Error"]
        if alert.waitToAppear(timeout: 5) {
            alert.buttons["OK"].tap()
        }
        XCTAssertTrue(app.buttons["Test Connection"].waitToAppear(timeout: 5))
    }

    // Aborting mid-upload returns the screen to a usable, non-uploading state.
    // (We assert the recovery, not a per-row label, which the current uploader
    // can race-overwrite.)
    @MainActor
    func testAbortMidUpload() async throws {
        guard !Self.abortURL.isEmpty else {
            throw XCTSkip("TEST_ABORT_URL not set. Run via go test harness.")
        }
        injectFault(controlURL: Self.abortControlURL, "reset")
        launchApp(hostURL: Self.abortURL)

        waitForMainScreen()
        openSettingsFromMainScreen()
        verifyConnectionWithoutSavingPassphrase()
        app.navigationBars["Repository Settings"].buttons["Save"].tap()
        waitForMainScreen()

        // Slow the uploads so the abort lands while work is in flight.
        injectFault(controlURL: Self.abortControlURL, "latency?ms=4000")
        app.navigationBars["Cling Sync"].buttons["Select All"].tap()
        app.buttons["Upload"].tap()

        let abortButton = app.buttons["Abort"]
        XCTAssertTrue(abortButton.waitToAppear(timeout: 15))
        abortButton.tap()
        // Let the in-flight request finish quickly so the abort can take effect.
        injectFault(controlURL: Self.abortControlURL, "reset")

        let okButton = app.buttons["OK"]
        XCTAssertTrue(okButton.waitToAppear(timeout: 30), "aborted upload should reach a terminal, dismissable state")
        okButton.tap()
        XCTAssertTrue(app.navigationBars["Cling Sync"].buttons["Select All"].waitToAppear(timeout: 15))
    }

    // A failing upload surfaces a dismissable error and never reports success.
    // The screen stays usable afterwards.
    @MainActor
    func testUploadFailureShowsError() async throws {
        guard !Self.failureURL.isEmpty else {
            throw XCTSkip("TEST_FAILURE_URL not set. Run via go test harness.")
        }
        injectFault(controlURL: Self.failureControlURL, "reset")
        launchApp(hostURL: Self.failureURL)

        waitForMainScreen()
        openSettingsFromMainScreen()
        verifyConnectionWithoutSavingPassphrase()
        app.navigationBars["Repository Settings"].buttons["Save"].tap()
        waitForMainScreen()

        injectFault(controlURL: Self.failureControlURL, "fail-writes?on=true")
        selectPhoto("IMG_0001.JPG")
        app.buttons["Upload"].tap()

        let okButton = app.buttons["OK"]
        XCTAssertTrue(okButton.waitToAppear(timeout: 30), "a failed upload should surface a dismissable error")
        XCTAssertFalse(
            app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Success!'")).firstMatch.exists,
            "a failed upload must not report success")
        okButton.tap()
        injectFault(controlURL: Self.failureControlURL, "reset")
        XCTAssertTrue(app.navigationBars["Cling Sync"].buttons["Select All"].waitToAppear(timeout: 15))
    }

    // Changing the Host URL switches repository: the connection must reset and
    // the "Repository access needed" banner must be offered (clearing the prior
    // repository's stored passphrase/URI is what prevents a stale-connection
    // lockout). Reconnecting itself is covered by the happy path.
    @MainActor
    func testRepositorySwitchRequiresReconnect() async throws {
        guard !Self.switchURL.isEmpty else {
            throw XCTSkip("TEST_SWITCH_URL not set. Run via go test harness.")
        }
        launchApp(hostURL: Self.hostURL)

        waitForMainScreen()
        openSettingsFromMainScreen()
        verifyConnectionWithoutSavingPassphrase()
        app.navigationBars["Repository Settings"].buttons["Save"].tap()
        waitForMainScreen()

        openSettingsFromMainScreen()
        replaceText(in: app.textFields["Host URL"], with: Self.switchURL)
        changeRepoPathPrefix("switched")
        app.navigationBars["Repository Settings"].buttons["Save"].tap()
        waitForMainScreen()

        XCTAssertTrue(
            app.staticTexts["Repository access needed"].waitToAppear(timeout: 10),
            "Switching repository must reset the connection")
        // The new repository is not yet connected, so its files are offered as
        // selectable rather than already-synced.
        XCTAssertTrue(app.staticTexts["IMG_0001.JPG"].waitToAppear(timeout: 10))
    }

    // Sharing files shows the share screen, which reuses the main file list: the
    // user connects, the shared file is scanned and offered, and uploading commits
    // it to the chosen target directory (the Go side verifies the path).
    @MainActor
    func testShareUploadHappyPath() async throws {
        guard !Self.shareURL.isEmpty else {
            throw XCTSkip("TEST_SHARE_URL not set. Run via go test harness.")
        }
        launchApp(hostURL: Self.shareURL, shareMode: true)

        XCTAssertTrue(app.navigationBars["Share with Cling Sync"].waitToAppear(timeout: 20))

        // The share screen connects eagerly (reusing the main connect flow), so the
        // passphrase + S3 prompts appear straight away.
        enterPassphrase(saveToKeychain: false)
        enterS3CredentialsIfPrompted()

        // After connecting + scanning, the new file is auto-selected (no manual tap).
        XCTAssertTrue(app.staticTexts["shared-note.txt"].waitToAppear(timeout: 20))

        let targetField = app.textFields["Target directory"]
        replaceText(in: targetField, with: "shared")

        let selected = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS '1 selected'")
        ).firstMatch
        XCTAssertTrue(selected.waitToAppear(timeout: 15))

        app.buttons["Upload"].tap()
        let success = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'Success!'")
        ).firstMatch
        XCTAssertTrue(success.waitToAppear(timeout: 40), "the share upload should report success")
        // Acknowledging the success banner returns to the main app (no manual Cancel).
        app.buttons["OK"].tap()
        XCTAssertTrue(app.navigationBars["Cling Sync"].waitToAppear(timeout: 15))
    }

    // Select All picks both new files. Uploading them together marks both Done,
    // after which they are no longer selectable (dedup via the local index).
    @MainActor
    func testSelectMultipleUploadMarksAllDone() async throws {
        guard !Self.multiURL.isEmpty else {
            throw XCTSkip("TEST_MULTI_URL not set. Run via go test harness.")
        }
        launchApp(hostURL: Self.multiURL)

        waitForMainScreen()
        openSettingsFromMainScreen()
        verifyConnectionWithoutSavingPassphrase()
        app.navigationBars["Repository Settings"].buttons["Save"].tap()
        waitForMainScreen()

        app.navigationBars["Cling Sync"].buttons["Select All"].tap()
        let selected = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS '2 selected'")
        ).firstMatch
        XCTAssertTrue(selected.waitToAppear(timeout: 5))

        app.buttons["Upload"].tap()
        waitForUploadSuccess(fileCount: 2)
        app.buttons["OK"].tap()

        // Both files are now Done, so there are no new files left to back up: the
        // Select All button reads "No new files" and is disabled.
        XCTAssertTrue(app.staticTexts["Done"].firstMatch.waitToAppear(timeout: 10))
        let noNewFiles = app.navigationBars["Cling Sync"].buttons["No new files"]
        XCTAssertTrue(noNewFiles.waitToAppear(timeout: 5), "Select All becomes No new files when nothing is selectable")
        XCTAssertFalse(noNewFiles.isEnabled, "Already-synced files must not be selectable")
    }
}
