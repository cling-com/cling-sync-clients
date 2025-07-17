import SwiftUI

struct SettingsView: View {
    @AppStorage("hostURL") private var hostURL = ""
    @AppStorage("passphrase") private var passphrase = ""
    @AppStorage("repoPathPrefix") private var repoPathPrefix = ""

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
                }

                Section {
                    Button(action: testConnection) {
                        if isConnecting {
                            HStack {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle())
                                    .scaleEffect(0.8)
                                Text("Connecting...")
                            }
                        } else {
                            Text("Test Connection")
                        }
                    }
                    .disabled(hostURL.isEmpty || passphrase.isEmpty || isConnecting)
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
                        isPresented = false
                    }
                    .disabled(hostURL.isEmpty || passphrase.isEmpty)
                }
            }
            .alert(isPresented: $showError) {
                Alert(
                    title: Text(
                        errorMessage.isEmpty ? "Connection Successful" : "Connection Error"),
                    message: Text(
                        errorMessage.isEmpty ? "Successfully connected to server" : errorMessage),
                    dismissButton: .default(Text("OK"))
                )
            }
        }
    }

    private func testConnection() {
        isConnecting = true
        errorMessage = ""

        Task {
            do {
                try Bridge.ensureOpen(url: hostURL, password: passphrase)
                await MainActor.run {
                    isConnecting = false
                    errorMessage = ""
                    showError = true
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
