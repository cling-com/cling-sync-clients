import Foundation
import Testing

@testable import ClingSync

struct SharedFilesSourceTest {
    @Test func stagesFilesAndUploadsFromTheLocalCopy() async throws {
        let original = try writeTempFile("hello share\n", ext: "txt")
        let staged = try #require(ShareImport.stage(original))
        #expect(staged.file.name == original.lastPathComponent)

        let source = SharedFilesSource(staged: [staged])
        let files = await source.loadFiles()
        #expect(files.count == 1)

        let file = try #require(files.first)
        let sha = try await source.sha256(for: file)
        #expect(sha == sha256Hex(of: original))

        let echoed = try await source.withLocalCopy(of: file) { url in
            try Data(contentsOf: url)
        }
        #expect(echoed == Data("hello share\n".utf8))
    }
}
