import SwiftUI

struct SettingsView: View {
    @AppStorage("hostURL") private var hostURL = ""
    @AppStorage("passphrase") private var passphrase = ""
    @AppStorage("repoPathPrefix") private var repoPathPrefix = ""
    @AppStorage("author") private var author = "iOS User"

    @Binding var isPresented: Bool
    @State private var isConnecting = false
    @State private var errorMessage = ""
    @State private var showError = false

    var body: some View {
        NavigationView {
            Form {
                Section(header: Text("Server Configuration")) {
                    TextField("Host URL", text: $hostURL)
                        .textContentType(.URL)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)

                    SecureField("Passphrase", text: $passphrase)
                        .textContentType(.password)

                    TextField("Destination path", text: $repoPathPrefix)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)

                    TextField("Author", text: $author)
                        .textContentType(.name)
                }
            }
            .navigationTitle("Connect to Server")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("Cancel") {
                        isPresented = false
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Save") {
                        if !isConnecting {
                            testConnection()
                        }
                    }
                    .disabled(hostURL.isEmpty || passphrase.isEmpty || isConnecting)
                }
            }
            .alert(isPresented: $showError) {
                Alert(
                    title: Text("Connection Error"),
                    message: Text(errorMessage),
                    dismissButton: .default(Text("OK"))
                )
            }
            .overlay {
                if isConnecting {
                    Color.black.opacity(0.3)
                        .ignoresSafeArea()
                        .overlay {
                            VStack(spacing: 16) {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle())
                                    .scaleEffect(1.5)
                                Text("Connecting to server...")
                                    .font(.headline)
                            }
                            .padding(24)
                            .background(Color(.systemBackground))
                            .cornerRadius(12)
                            .shadow(radius: 4)
                        }
                }
            }
        }
    }

    private func testConnection() {
        isConnecting = true
        errorMessage = ""

        Task {
            do {
                try Bridge.ensureOpen(url: hostURL, password: passphrase, repoPathPrefix: repoPathPrefix)
                await MainActor.run {
                    isConnecting = false
                    // Close the dialog on success
                    isPresented = false
                }
            } catch {
                await MainActor.run {
                    isConnecting = false
                    if let bridgeError = error as? BridgeError {
                        errorMessage = bridgeError.message
                    } else {
                        errorMessage = error.localizedDescription
                    }
                    showError = true
                }
            }
        }
    }
}

extension View {
    func placeholder<Content: View>(
        when shouldShow: Bool,
        alignment: Alignment = .leading,
        @ViewBuilder placeholder: () -> Content
    ) -> some View {

        ZStack(alignment: alignment) {
            placeholder().opacity(shouldShow ? 1 : 0)
            self
        }
    }
}

#Preview {
    SettingsView(isPresented: .constant(true))
}
