import Foundation
import Testing

@testable import ClingSync

// Real-bridge tests for the single repository-open path, including the
// open-before-persist invariant that prevents the wrong-passphrase lockout.
extension BridgeSuite {
    @Test(.enabled(if: TestRepo.isAvailable))
    func gatewayOpensCleartextS3AndPersistsEncodedURI() async throws {
        let repo = try await TestRepo.fresh()
        RepositoryURIStore.clear(for: repo.url)
        let gateway = RepositoryGateway()

        _ = try await gateway.open(
            hostURL: repo.url,
            passphrase: repo.passphrase,
            askS3: { S3CredentialsResult(accessKeyId: repo.s3KeyId, accessKey: repo.s3Key) })

        // After a successful open, the encoded URI is persisted for reuse, and the
        // repository reports as already open.
        #expect(RepositoryURIStore.get(for: repo.url) != nil)
        let status = await gateway.isAlreadyOpen(hostURL: repo.url)
        #expect(status.open)
    }

    @Test(.enabled(if: TestRepo.isAvailable))
    func gatewayWrongPassphraseDoesNotPersistURI() async throws {
        let repo = try await TestRepo.fresh()
        RepositoryURIStore.clear(for: repo.url)
        let gateway = RepositoryGateway()

        var threw = false
        do {
            _ = try await gateway.open(
                hostURL: repo.url,
                passphrase: "definitely-the-wrong-passphrase",
                askS3: { S3CredentialsResult(accessKeyId: repo.s3KeyId, accessKey: repo.s3Key) })
        } catch is BridgeError {
            threw = true
        }

        #expect(threw, "a wrong passphrase must fail the open")
        // A failed open must not leave an encoded URI behind, which would be
        // reused on the next attempt and lock the user out.
        #expect(
            RepositoryURIStore.get(for: repo.url) == nil,
            "a failed open must not persist the encoded URI")
    }
}
