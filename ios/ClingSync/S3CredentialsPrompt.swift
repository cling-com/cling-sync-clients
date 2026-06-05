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
