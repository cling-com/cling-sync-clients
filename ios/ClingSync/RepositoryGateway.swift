import Foundation

// The single place a repository is opened. Handles the cleartext-S3 credential
// fallback. The passphrase is passed straight to the bridge and never retained.
final class RepositoryGateway {
    // Whether the bridge already has this repository open (same process), so no
    // passphrase prompt is needed.
    func isAlreadyOpen(hostURL: String) async -> RepositoryStatus {
        let uri = RepositoryURIStore.get(for: hostURL) ?? hostURL
        return await Task.detached(priority: .userInitiated) {
            (try? Bridge.checkRepositoryOpen(url: uri)) ?? RepositoryStatus(open: false, headRevisionId: "")
        }.value
    }

    // Opens the repository, calling askS3 to collect credentials when the host is
    // a cleartext S3 URL with none stored.
    func open(
        hostURL: String,
        passphrase: String,
        askS3: () async throws -> S3CredentialsResult
    ) async throws -> RepositoryConnectionInfo {
        if let stored = RepositoryURIStore.get(for: hostURL) {
            return try await openRepository(url: stored, passphrase: passphrase)
        }
        do {
            return try await openRepository(url: hostURL, passphrase: passphrase)
        } catch let error as BridgeError {
            guard RepositoryURI.isCleartextS3(hostURL) else { throw error }
            let creds = try await askS3()
            let encoded = try await Task.detached(priority: .userInitiated) {
                try Bridge.encodeS3URI(
                    hostUrl: hostURL,
                    passphrase: passphrase,
                    accessKeyId: creds.accessKeyId,
                    accessKey: creds.accessKey)
            }.value
            // Open before persisting: a wrong passphrase (or any failed retry)
            // must not leave behind an encoded URI that would be reused and lock
            // the user out.
            let info = try await openRepository(url: encoded, passphrase: passphrase)
            RepositoryURIStore.set(encoded, for: hostURL)
            return info
        }
    }

    private func openRepository(url: String, passphrase: String) async throws -> RepositoryConnectionInfo {
        try await Task.detached(priority: .userInitiated) {
            try Bridge.openRepository(url: url, password: passphrase)
        }.value
    }
}
