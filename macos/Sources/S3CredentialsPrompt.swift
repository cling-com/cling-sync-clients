import AppKit

struct S3CredentialsPromptResult {
    let accessKeyId: String
    let accessKey: String
}

enum S3CredentialsPrompt {
    static func run(for hostURL: String) -> S3CredentialsPromptResult? {
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
            if alert.runModal() != .alertFirstButtonReturn {
                return nil
            }
            let accessKeyId = keyIdField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let accessKey = accessKeyField.stringValue
            if !accessKeyId.isEmpty && !accessKey.isEmpty {
                return S3CredentialsPromptResult(accessKeyId: accessKeyId, accessKey: accessKey)
            }
        }
    }
}
