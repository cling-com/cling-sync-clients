import CryptoKit
import Foundation
import Testing

@testable import ClingSync

// Exercises the fixture path of the photo-library source (the path the UI tests
// use). The live Photos path needs an authorization prompt, so it is covered by
// the integration suite, not here.
struct SourceGatewayTest {
    @Test func loadsFixturesAsSourceFiles() async {
        let source = PhotoLibrarySource(isUITestMode: true)
        let files = await source.loadFiles()
        #expect(files.map(\.name).sorted() == ["IMG_0001.JPG", "IMG_0004.JPG"])
    }

    @Test func hashesFixtureContent() async throws {
        let source = PhotoLibrarySource(isUITestMode: true)
        let files = await source.loadFiles()
        let file = try #require(files.first { $0.name == "IMG_0001.JPG" })

        let hash = try await source.sha256(for: file)

        let expected = SHA256.hash(data: Data("ui test image 1\n".utf8))
            .map { String(format: "%02x", $0) }.joined()
        #expect(hash == expected)
    }

    @Test func hashingAnUnknownFileThrows() async {
        let source = PhotoLibrarySource(isUITestMode: true)
        _ = await source.loadFiles()
        let unknown = SourceFile(id: "missing", name: "missing.jpg", size: 1, modificationDate: .distantPast)
        await #expect(throws: SourceFileUnavailable.self) {
            try await source.sha256(for: unknown)
        }
    }
}
