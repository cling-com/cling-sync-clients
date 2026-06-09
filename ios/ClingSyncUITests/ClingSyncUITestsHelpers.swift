import Darwin
import XCTest

extension ClingSyncUITests {
    func launchApp(hostURL: String, repoPathPrefix: String = "/uitest", shareMode: Bool = false) {
        app.launchArguments = ["--reset", "--ui-test-mode"]
        if shareMode {
            app.launchArguments.append("--share-test-mode")
        }
        app.launchEnvironment["CLING_SYNC_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CLING_SYNC_UI_TEST_HOST_URL"] = hostURL
        app.launchEnvironment["CLING_SYNC_UI_TEST_REPO_PATH_PREFIX"] = repoPathPrefix
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

    func openSettingsFromMainScreen() {
        app.navigationBars["Cling Sync"].buttons["Settings"].tap()
        XCTAssertTrue(app.navigationBars["Repository Settings"].waitToAppear(timeout: 3))
    }

    // Replaces the Host URL with a non-S3 value and verifies that Test
    // Connection surfaces the validation alert. The caller is responsible for
    // restoring the URL (typically by dismissing and re-opening settings).
    func rejectInvalidHostURL() {
        let field = app.textFields["Host URL"]
        XCTAssertTrue(field.waitToAppear(timeout: 5))
        replaceText(in: field, with: "https://wrong.example.com")
        app.buttons["Test Connection"].tap()
        let alert = app.alerts["Settings Error"]
        XCTAssertTrue(alert.waitToAppear(timeout: 5))
        alert.buttons["OK"].tap()
    }

    func replaceText(in field: XCUIElement, with value: String) {
        field.tap()
        if let current = field.value as? String, !current.isEmpty {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        field.typeText(value)
    }

    func verifyConnectionWithoutSavingPassphrase() {
        app.buttons["Test Connection"].tap()
        XCTAssertTrue(app.navigationBars["Repository Passphrase"].waitToAppear(timeout: 5))
        enterPassphrase(saveToKeychain: false)
        enterS3CredentialsIfPrompted()
        XCTAssertTrue(app.alerts["Connection Succeeded"].waitToAppear(timeout: 10))
        app.alerts["Connection Succeeded"].buttons["OK"].tap()
    }

    func enterS3CredentialsIfPrompted() {
        let s3Nav = app.navigationBars["S3 Credentials"]
        guard s3Nav.waitToAppear(timeout: 5) else {
            return
        }
        let keyIdField = app.textFields["S3 Key ID"]
        XCTAssertTrue(keyIdField.waitToAppear(timeout: 3))
        keyIdField.tap()
        keyIdField.typeText(Self.s3AccessKeyId)

        let accessKeyField = app.secureTextFields["S3 Access Key"]
        accessKeyField.tap()
        accessKeyField.typeText(Self.s3AccessKey)

        s3Nav.buttons["Continue"].tap()
    }

    func waitForMainScreen() {
        let mainNavBar = app.navigationBars["Cling Sync"]
        XCTAssertTrue(mainNavBar.waitToAppear(timeout: 20))
        mainNavBar.tap()
    }

    func selectPhoto(_ name: String) {
        let photo = app.staticTexts[name]
        XCTAssertTrue(photo.waitToAppear(timeout: 20))
        photo.tap()

        let selectedText = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS '1 selected'")
        ).firstMatch
        XCTAssertTrue(selectedText.waitToAppear(timeout: 10))
    }

    func waitForUploadSuccess(fileCount: Int) {
        let successMessage = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS 'Success! \(fileCount) file'")
        ).firstMatch
        XCTAssertTrue(successMessage.waitToAppear(timeout: 40))
    }

    func changeRepoPathPrefix(_ newPrefix: String) {
        let field = app.textFields["Destination path"]
        XCTAssertTrue(field.waitToAppear(timeout: 5))
        replaceText(in: field, with: newPrefix)
    }

    func enterPassphrase(_ passphrase: String = ClingSyncUITests.passphrase, saveToKeychain: Bool) {
        let passphraseField = app.secureTextFields["Passphrase"]
        XCTAssertTrue(passphraseField.waitToAppear(timeout: 5))
        passphraseField.tap()
        passphraseField.typeText(passphrase)

        let saveToggle = app.switches["Save in iPhone Keychain"]
        if saveToggle.exists {
            let isOn = (saveToggle.value as? String) == "1"
            if saveToKeychain != isOn {
                saveToggle.tap()
            }
        }

        app.navigationBars["Repository Passphrase"].buttons["Continue"].tap()
    }

    // Toggles fault injection on a repo's S3 server (e.g. "fail-writes?on=true",
    // "latency?ms=4000", "reset") via a raw socket. App Transport Security would
    // block a URLSession cleartext request to localhost from the test runner.
    func injectFault(controlURL: String, _ query: String) {
        guard let url = URL(string: controlURL), let host = url.host, let port = url.port else {
            return
        }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return }
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
        guard connected == 0 else { return }
        let request =
            "POST /__test/\(query) HTTP/1.1\r\nHost: \(host):\(port)\r\nConnection: close\r\nContent-Length: 0\r\n\r\n"
        _ = request.withCString { send(descriptor, $0, strlen($0), 0) }
        // Drain the response so the toggle is applied before we return.
        var buffer = [UInt8](repeating: 0, count: 256)
        _ = recv(descriptor, &buffer, buffer.count, 0)
    }
}
