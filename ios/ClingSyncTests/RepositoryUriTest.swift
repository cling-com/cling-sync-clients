import Foundation
import Testing

@testable import ClingSync

// Pure tests for the URL classification that decides whether the S3 credentials
// prompt is needed and whether a URL already carries embedded credentials.
struct RepositoryUriTest {
    @Test func cleartextS3IsDetected() {
        #expect(RepositoryURI.isCleartextS3("s3+http://bucket.example.com"))
        #expect(RepositoryURI.isCleartextS3("s3+https://bucket.example.com"))
        #expect(RepositoryURI.isCleartextS3("S3+HTTP://bucket.example.com"))
    }

    @Test func nonS3OrEmbeddedIsNotCleartextS3() {
        // Not an S3 scheme.
        #expect(!RepositoryURI.isCleartextS3("https://bucket.example.com"))
        #expect(!RepositoryURI.isCleartextS3(""))
        // Already carries embedded credentials in the userinfo.
        #expect(!RepositoryURI.isCleartextS3("s3+http://key:secret@bucket.example.com"))
    }

    @Test func embeddedCredentialsOnlyCountInTheAuthority() {
        #expect(RepositoryURI.hasEmbeddedCredentials("s3+http://key@bucket.example.com"))
        // An @ that appears only in the path is not embedded credentials.
        #expect(!RepositoryURI.hasEmbeddedCredentials("s3+http://bucket.example.com/a@b"))
        #expect(!RepositoryURI.hasEmbeddedCredentials("s3+http://bucket.example.com"))
    }
}
