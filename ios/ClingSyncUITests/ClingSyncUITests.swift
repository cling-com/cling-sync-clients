import XCTest

// This test requires a repository to be available at http://127.0.0.1:9124 with the
// passphrase "testpassphrase".
//
// Normally, this test is run by `main_test.go` which sets everything up.
final class ClingSyncUITests: XCTestCase {

    private static var passphrase = "testpassphrase"
    private static var hostURL = "http://127.0.0.1:9124"

    // private static var passphrase = "a"
    // private static var hostURL = "http://127.0.0.1:4242"

    let app = XCUIApplication()

    override func setUpWithError() throws {
        continueAfterFailure = false
        app.launchArguments = ["--reset"]
        app.resetAuthorizationStatus(for: .photos)
        app.launch()

        // Set up handler for photo library permission.
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
        // Configure server settings.
        let configureButton = app.buttons["Configure Settings"]
        XCTAssertTrue(configureButton.waitForExistence(timeout: 3))
        configureButton.tap()

        let hostURLField = app.textFields.element(boundBy: 0)
        hostURLField.tap()
        hostURLField.typeText(Self.hostURL)

        let passphraseField = app.secureTextFields.element(boundBy: 0)
        passphraseField.tap()
        passphraseField.typeText(Self.passphrase)

        let destinationPathField = app.textFields.element(boundBy: 1)
        destinationPathField.tap()
        destinationPathField.typeText("/uitest")

        // Save settings, dialog should close.
        app.navigationBars["Connect to Server"].buttons["Save"].tap()
        // Wait for setting dialog to close.
        let mainNavBar = app.navigationBars["Cling Sync"]
        XCTAssertTrue(mainNavBar.waitForExistence(timeout: 3))
        // Why is the next tap necessary? It is there to force the addUIInterruptionMonitor
        // to fire. It fires only if we try to interact with something that is blocked by
        // "interruption" (in this case the permission dialog).
        // See: https://wwdcnotes.com/documentation/wwdcnotes/wwdc20-10220-handle-interruptions-and-alerts-in-ui-tests/
        // "The system will automatically invoke the interruption handler stack when the UI test tries to interact
        // with something that is blocked by an interruption."
        mainNavBar.tap()

        // Select two photos.
        let photo1 = app.staticTexts["IMG_0001.JPG"]
        XCTAssertTrue(photo1.waitForExistence(timeout: 3))
        photo1.tap()
        let photo2 = app.staticTexts["IMG_0004.JPG"]
        XCTAssertTrue(photo2.waitForExistence(timeout: 3))
        photo2.tap()

        // Wait for a text that contains "2 selected"
        let selectedText = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS '2 selected'")
        ).firstMatch
        XCTAssertTrue(selectedText.waitForExistence(timeout: 60))

        // Start upload.
        let uploadButton = app.buttons["Upload"]
        XCTAssertTrue(uploadButton.waitForExistence(timeout: 5))
        uploadButton.tap()

        // Wait for the upload to finish.
        let successMessage = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'Success! 2 files uploaded'")
        ).firstMatch
        XCTAssertTrue(successMessage.waitForExistence(timeout: 10))
    }
}
