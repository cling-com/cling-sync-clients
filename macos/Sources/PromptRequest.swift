import AppKit

struct PassphrasePromptResult: Equatable {
    let passphrase: String
    let rememberInKeychain: Bool
}

struct S3CredentialsResult: Equatable {
    let accessKeyId: String
    let accessKey: String
}

struct SyncTargetResult: Equatable {
    let name: String
    let uri: String
}

// The modal-prompt seam. Keeping prompts behind a protocol (rather than on the
// event bus) lets the store await an answer inline while staying testable: a
// ScriptedPrompter answers without UI.
@MainActor
protocol Prompter {
    func passphrase(workspaceName: String) async -> PassphrasePromptResult?
    func newRepositoryPassphrase(at path: String) async -> String?
    func confirmCreateRepository(at path: String) async -> Bool
    func s3Credentials(hostURL: String) async -> S3CredentialsResult?
    func syncTarget() async -> SyncTargetResult?
    func alert(title: String, message: String) async
}

// The real prompts: synchronous NSAlert.runModal wrapped as async. Every
// accessibility identifier and button title is preserved verbatim because the
// XCUITests drive these. Where two prompts share a button title, those buttons
// carry identifiers: a title-based query cannot tell two alerts apart, and picks
// whichever the accessibility hierarchy happens to list first.
@MainActor
final class AppKitPrompter: Prompter {
    // Progress windows are `.floating`, which sits above a modal alert and covers
    // whatever part of it they overlap. Clicks aimed at the covered part hit the
    // progress window and are dropped by the modal session, while typing still
    // reaches the alert's first responder, so a prompt can look like it is working
    // while every click into it goes nowhere. Raising the alert instead does not
    // help: the level it is given is not honoured against a floating window for as
    // long as the modal session owns it. Dropping the windows that float, for no
    // longer than the prompt is up, is what actually clears the alert. They go below
    // the alert rather than level with it: at an equal level the two are separated
    // only by their front-to-back order, which would leave the very same prompt
    // covered whenever the alert happens to land behind.
    private func runModal(_ alert: NSAlert) -> NSApplication.ModalResponse {
        let belowAlert = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
        let floating = NSApp.windows.filter { $0.level == .floating }
        for window in floating {
            window.level = belowAlert
        }
        defer {
            for window in floating {
                window.level = .floating
            }
        }
        return alert.runModal()
    }

    func passphrase(workspaceName: String) async -> PassphrasePromptResult? {
        while true {
            let alert = NSAlert()
            alert.messageText = "Enter Passphrase"
            alert.informativeText = "Cling Sync needs the repository passphrase for \(workspaceName)."
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            field.placeholderString = "Passphrase"
            field.setAccessibilityIdentifier("passphrasePromptField")
            let checkbox = NSButton(checkboxWithTitle: "Save access in macOS Keychain", target: nil, action: nil)
            checkbox.setAccessibilityIdentifier("passphrasePromptRemember")
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 56))
            let stack = NSStackView(frame: container.bounds)
            stack.orientation = .vertical
            stack.spacing = 8
            stack.alignment = .leading
            stack.autoresizingMask = [.width, .height]
            stack.addArrangedSubview(field)
            stack.addArrangedSubview(checkbox)
            container.addSubview(stack)
            alert.accessoryView = container
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            alert.window.initialFirstResponder = field
            DispatchQueue.main.async {
                alert.window.makeFirstResponder(field)
                field.selectText(nil)
            }
            if runModal(alert) != .alertFirstButtonReturn {
                return nil
            }
            let passphrase = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !passphrase.isEmpty {
                return PassphrasePromptResult(passphrase: passphrase, rememberInKeychain: checkbox.state == .on)
            }
        }
    }

    func newRepositoryPassphrase(at path: String) async -> String? {
        while true {
            let alert = NSAlert()
            alert.messageText = "Set Repository Passphrase"
            alert.informativeText =
                "Choose a passphrase to protect the new repository at \(path). "
                + "This passphrase cannot be recovered if lost."
            let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            field.placeholderString = "Passphrase"
            field.setAccessibilityIdentifier("newRepositoryPassphraseField")
            alert.accessoryView = field
            alert.addButton(withTitle: "Create")
                .setAccessibilityIdentifier("newRepositoryPassphraseCreateButton")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            alert.window.initialFirstResponder = field
            DispatchQueue.main.async {
                alert.window.makeFirstResponder(field)
                field.selectText(nil)
            }
            if runModal(alert) != .alertFirstButtonReturn {
                return nil
            }
            let passphrase = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !passphrase.isEmpty {
                return passphrase
            }
        }
    }

    func confirmCreateRepository(at path: String) async -> Bool {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Create New Repository?"
        alert.informativeText = "No repository was found at \(path). Do you want to create a new repository there?"
        alert.addButton(withTitle: "Create").setAccessibilityIdentifier("confirmCreateRepositoryButton")
        alert.addButton(withTitle: "Cancel").setAccessibilityIdentifier("confirmCreateRepositoryCancelButton")
        return runModal(alert) == .alertFirstButtonReturn
    }

    func s3Credentials(hostURL: String) async -> S3CredentialsResult? {
        while true {
            let alert = NSAlert()
            alert.messageText = "S3 Credentials"
            alert.informativeText =
                "Enter the S3 access key for \(hostURL). "
                + "The credentials are encrypted with your repository passphrase before being stored."
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 60))
            let stack = NSStackView(frame: container.bounds)
            stack.orientation = .vertical
            stack.spacing = 8
            stack.alignment = .leading
            stack.autoresizingMask = [.width, .height]
            let keyIdField = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            keyIdField.placeholderString = "S3 Key ID"
            keyIdField.setAccessibilityIdentifier("s3KeyIdField")
            let accessKeyField = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            accessKeyField.placeholderString = "S3 Access Key"
            accessKeyField.setAccessibilityIdentifier("s3AccessKeyField")
            stack.addArrangedSubview(keyIdField)
            stack.addArrangedSubview(accessKeyField)
            container.addSubview(stack)
            alert.accessoryView = container
            alert.addButton(withTitle: "Continue")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            alert.window.initialFirstResponder = keyIdField
            DispatchQueue.main.async {
                alert.window.makeFirstResponder(keyIdField)
            }
            if runModal(alert) != .alertFirstButtonReturn {
                return nil
            }
            let accessKeyId = keyIdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let accessKey = accessKeyField.stringValue
            if !accessKeyId.isEmpty && !accessKey.isEmpty {
                return S3CredentialsResult(accessKeyId: accessKeyId, accessKey: accessKey)
            }
        }
    }

    func syncTarget() async -> SyncTargetResult? {
        while true {
            let alert = NSAlert()
            alert.messageText = "Add Sync Target"
            alert.informativeText =
                "Enter a name and the repository to mirror to. The repository can be a local folder "
                + "path or an s3+http(s) URL that includes its encrypted credentials."
            let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 56))
            let stack = NSStackView(frame: container.bounds)
            stack.orientation = .vertical
            stack.spacing = 8
            stack.alignment = .leading
            stack.autoresizingMask = [.width, .height]
            let nameField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            nameField.placeholderString = "Name (letters, digits, '-')"
            nameField.setAccessibilityIdentifier("syncTargetNameField")
            let repoField = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
            repoField.placeholderString = "Folder path or s3+https://... URL"
            repoField.setAccessibilityIdentifier("syncTargetRepositoryField")
            stack.addArrangedSubview(nameField)
            stack.addArrangedSubview(repoField)
            container.addSubview(stack)
            alert.accessoryView = container
            alert.addButton(withTitle: "Add")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            alert.window.initialFirstResponder = nameField
            DispatchQueue.main.async {
                alert.window.makeFirstResponder(nameField)
            }
            if runModal(alert) != .alertFirstButtonReturn {
                return nil
            }
            let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let uri = repoField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty && !uri.isEmpty {
                return SyncTargetResult(name: name, uri: uri)
            }
        }
    }

    func alert(title: String, message: String) async {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        _ = runModal(alert)
    }
}

// A test double that answers from queued results and records alerts.
@MainActor
final class ScriptedPrompter: Prompter {
    var passphraseResults: [PassphrasePromptResult?] = []
    var newRepositoryPassphraseResults: [String?] = []
    var confirmCreateResults: [Bool] = []
    var s3CredentialsResults: [S3CredentialsResult?] = []
    var syncTargetResults: [SyncTargetResult?] = []

    private(set) var passphraseRequestCount = 0
    private(set) var recordedAlerts: [String] = []

    func passphrase(workspaceName: String) async -> PassphrasePromptResult? {
        passphraseRequestCount += 1
        return passphraseResults.isEmpty ? nil : passphraseResults.removeFirst()
    }

    func newRepositoryPassphrase(at path: String) async -> String? {
        newRepositoryPassphraseResults.isEmpty ? nil : newRepositoryPassphraseResults.removeFirst()
    }

    func confirmCreateRepository(at path: String) async -> Bool {
        confirmCreateResults.isEmpty ? false : confirmCreateResults.removeFirst()
    }

    func s3Credentials(hostURL: String) async -> S3CredentialsResult? {
        s3CredentialsResults.isEmpty ? nil : s3CredentialsResults.removeFirst()
    }

    func syncTarget() async -> SyncTargetResult? {
        syncTargetResults.isEmpty ? nil : syncTargetResults.removeFirst()
    }

    func alert(title: String, message: String) async {
        recordedAlerts.append("\(title): \(message)")
    }
}
