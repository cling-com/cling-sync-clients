import SwiftUI

struct WelcomeStateView: View {
    let isBusy: Bool
    @Binding var showSettings: Bool

    var body: some View {
        NavigationView {
            VStack {
                Text("Welcome to Cling Sync")
                    .font(.largeTitle)
                    .padding()
                Text("Configure your repository, then test access or start syncing when you need it.")
                    .padding()
                Button("Configure Settings") {
                    showSettings = true
                }
                .buttonStyle(.borderedProminent)
                .disabled(isBusy)
            }
        }
    }
}

struct ConnectingStateView: View {
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .progressViewStyle(CircularProgressViewStyle())
                .scaleEffect(1.5)
            Text("Connecting to server...")
                .font(.headline)
        }
    }
}

struct ConnectionFailedStateView: View {
    let message: String
    let isBusy: Bool
    let retry: () -> Void
    @Binding var showSettings: Bool

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 48))
                .foregroundColor(.red)
            Text("Connection Failed")
                .font(.headline)
            Text(message)
                .font(.subheadline)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)
            HStack(spacing: 12) {
                Button("Retry", action: retry)
                    .buttonStyle(.borderedProminent)
                    .disabled(isBusy)
                Button("Settings") {
                    showSettings = true
                }
                .buttonStyle(.bordered)
                .disabled(isBusy)
            }
        }
    }
}

struct RepositoryAccessBanner: View {
    let connect: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "lock.shield")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text("Repository access needed")
                    .font(.subheadline.weight(.semibold))
                Text("Connect to compare files before you sync new media.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Connect", action: connect)
                .buttonStyle(.borderedProminent)
        }
        .padding(12)
        .background(.thinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding([.horizontal, .top])
    }
}
