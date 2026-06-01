import SwiftUI

struct S3CredentialsResult {
    let accessKeyId: String
    let accessKey: String
}

struct S3CredentialsRequest: Identifiable {
    let id = UUID()
    let hostURL: String
}

@MainActor
final class S3CredentialsPromptController: ObservableObject {
    @Published var request: S3CredentialsRequest?

    private var continuation: CheckedContinuation<S3CredentialsResult, Error>?

    func prompt(hostURL: String) async throws -> S3CredentialsResult {
        try await withCheckedThrowingContinuation { continuation in
            self.request = S3CredentialsRequest(hostURL: hostURL)
            self.continuation = continuation
        }
    }

    func submit(accessKeyId: String, accessKey: String) {
        continuation?.resume(
            returning: S3CredentialsResult(accessKeyId: accessKeyId, accessKey: accessKey))
        continuation = nil
        request = nil
    }

    func cancel() {
        continuation?.resume(throwing: CancellationError())
        continuation = nil
        request = nil
    }

    // Opens the repository. If a cleartext S3 URL fails to open, prompts for the
    // S3 key/secret, encodes them into the URI, stores it, and retries.
    func openRepository(hostURL: String, passphrase: String) async throws -> RepositoryConnectionInfo {
        if let stored = RepositoryURIStore.get(for: hostURL) {
            return try await Task.detached(priority: .userInitiated) {
                try Bridge.openRepository(url: stored, password: passphrase)
            }.value
        }
        do {
            return try await Task.detached(priority: .userInitiated) {
                try Bridge.openRepository(url: hostURL, password: passphrase)
            }.value
        } catch let error as BridgeError {
            guard RepositoryURI.isCleartextS3(hostURL) else { throw error }
            let creds = try await prompt(hostURL: hostURL)
            let encoded = try await Task.detached(priority: .userInitiated) {
                try Bridge.encodeS3URI(
                    hostUrl: hostURL,
                    passphrase: passphrase,
                    accessKeyId: creds.accessKeyId,
                    accessKey: creds.accessKey)
            }.value
            RepositoryURIStore.set(encoded, for: hostURL)
            return try await Task.detached(priority: .userInitiated) {
                try Bridge.openRepository(url: encoded, password: passphrase)
            }.value
        }
    }
}

enum RepositoryURI {
    static func isCleartextS3(_ url: String) -> Bool {
        let lower = url.lowercased()
        let isS3 = lower.hasPrefix("s3+http://") || lower.hasPrefix("s3+https://")
        return isS3 && !hasEmbeddedCredentials(url)
    }

    static func hasEmbeddedCredentials(_ url: String) -> Bool {
        guard let schemeEnd = url.range(of: "://") else { return false }
        return url[schemeEnd.upperBound...].prefix(while: { $0 != "/" }).contains("@")
    }
}

// Persists the encrypted S3 repository URI per cleartext URL, so the credentials
// (encrypted with the passphrase) are entered once and re-sent thereafter.
enum RepositoryURIStore {
    private static let key = "repositoryURIs"

    static func get(for hostURL: String) -> String? {
        dictionary()[hostURL]
    }

    static func set(_ uri: String, for hostURL: String) {
        var dict = dictionary()
        dict[hostURL] = uri
        UserDefaults.standard.set(dict, forKey: key)
    }

    static func clear(for hostURL: String) {
        var dict = dictionary()
        dict.removeValue(forKey: hostURL)
        UserDefaults.standard.set(dict, forKey: key)
    }

    private static func dictionary() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: key) as? [String: String] ?? [:]
    }
}

struct S3CredentialsPromptView: View {
    @ObservedObject var controller: S3CredentialsPromptController
    let request: S3CredentialsRequest

    @Environment(\.dismiss) private var dismiss
    @State private var accessKeyId = ""
    @State private var accessKey = ""

    var body: some View {
        NavigationView {
            Form {
                Section {
                    Text(
                        "Enter the S3 access key for \(request.hostURL). "
                            + "The credentials are encrypted with your repository passphrase before being stored."
                    )
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                }

                Section("S3 Key ID") {
                    TextField("S3 Key ID", text: $accessKeyId)
                        .textInputAutocapitalization(.never)
                        .disableAutocorrection(true)
                }

                Section("S3 Access Key") {
                    SecureField("S3 Access Key", text: $accessKey)
                        .textContentType(.password)
                }
            }
            .interactiveDismissDisabled()
            .navigationTitle("S3 Credentials")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        controller.cancel()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Continue") {
                        controller.submit(
                            accessKeyId: accessKeyId.trimmingCharacters(in: .whitespaces),
                            accessKey: accessKey)
                        dismiss()
                    }
                    .disabled(accessKeyId.isEmpty || accessKey.isEmpty)
                }
            }
        }
    }
}
