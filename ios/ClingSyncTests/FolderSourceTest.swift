import CryptoKit
import Foundation
import Testing

@testable import ClingSync

struct FolderSourceTest {
    private func makeFolder(_ files: [(name: String, contents: String)]) throws -> Data {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for file in files {
            try Data(file.contents.utf8).write(to: directory.appendingPathComponent(file.name))
        }
        return try directory.bookmarkData()
    }

    @Test func enumeratesFolderFilesAsSourceFiles() async throws {
        let bookmark = try makeFolder([("a.txt", "alpha"), ("b.txt", "bravo longer")])
        let source = FolderSource(bookmark: bookmark)

        let files = await source.loadFiles()

        #expect(files.map(\.name).sorted() == ["a.txt", "b.txt"])
        #expect(files.allSatisfy { $0.size > 0 })
    }

    @Test func hashesAndExposesLocalCopyForUpload() async throws {
        let bookmark = try makeFolder([("photo.jpg", "image-bytes")])
        let source = FolderSource(bookmark: bookmark)
        let file = try #require(await source.loadFiles().first)

        let hash = try await source.sha256(for: file)
        let expected = SHA256.hash(data: Data("image-bytes".utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(hash == expected)

        let name = try await source.withLocalCopy(of: file) { $0.lastPathComponent }
        #expect(name == "photo.jpg")
    }

    @Test func unknownFileThrows() async throws {
        let bookmark = try makeFolder([("a.txt", "x")])
        let source = FolderSource(bookmark: bookmark)
        _ = await source.loadFiles()
        let unknown = SourceFile(id: "missing", name: "missing", size: 1, modificationDate: .distantPast)
        await #expect(throws: SourceFileUnavailable.self) {
            try await source.withLocalCopy(of: unknown) { _ in () }
        }
    }
}
