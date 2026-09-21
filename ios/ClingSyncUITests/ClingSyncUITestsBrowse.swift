import XCTest

extension ClingSyncUITests {
    // Browse smoke test: connect (which caches the passphrase for the
    // session), open the browse screen via the globe button, and assert the
    // Go-rendered page shows the seeded repository file.
    @MainActor
    func testBrowseShowsRepositoryFile() async throws {
        guard !Self.browseURL.isEmpty else {
            throw XCTSkip("TEST_BROWSE_URL not set. Run via go test harness.")
        }
        launchApp(hostURL: Self.browseURL)

        waitForMainScreen()
        openSettingsFromMainScreen()
        app.buttons["Test Connection"].tap()
        XCTAssertTrue(app.navigationBars["Repository Passphrase"].waitToAppear(timeout: 5))
        enterPassphrase(saveToKeychain: false)
        enterS3CredentialsIfPrompted()
        XCTAssertTrue(app.alerts["Connection Succeeded"].waitToAppear(timeout: 10))
        app.alerts["Connection Succeeded"].buttons["OK"].tap()
        app.navigationBars["Repository Settings"].buttons["Cancel"].tap()
        waitForMainScreen()

        app.buttons["Browse"].tap()
        XCTAssertTrue(
            app.webViews.staticTexts["browse-hello.txt"].firstMatch.waitToAppear(timeout: 30),
            "browse screen did not render the repository content")
        XCTAssertTrue(app.webViews.links["Download"].firstMatch.waitToAppear(timeout: 5))

        app.buttons["Back"].tap()
        waitForMainScreen()
    }
}
