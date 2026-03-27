import Foundation

let loginAuthorName: String = {
    let user = NSUserName().trimmingCharacters(in: .whitespacesAndNewlines)
    return user.isEmpty ? NSFullUserName() : user
}()

struct WorkspaceConfig: Codable, Identifiable, Equatable {
    var id: UUID
    var hostURL: String
    var localDirectory: String
    var repoPathPrefix: String
    var author: String
    var verifiedAccessSignature: String

    init(
        id: UUID = UUID(),
        hostURL: String = "",
        localDirectory: String = "",
        repoPathPrefix: String = "",
        author: String = loginAuthorName,
        verifiedAccessSignature: String = ""
    ) {
        self.id = id
        self.hostURL = hostURL
        self.localDirectory = localDirectory
        self.repoPathPrefix = repoPathPrefix
        self.author = author
        self.verifiedAccessSignature = verifiedAccessSignature
    }

    var isComplete: Bool {
        !hostURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !localDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isValidForSave: Bool {
        isComplete && isAccessVerified
    }

    var isReadyForTest: Bool {
        !hostURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !localDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var normalizedHostURL: String {
        hostURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedLocalDirectory: String {
        localDirectory.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var normalizedRepoPathPrefix: String {
        let trimmed = repoPathPrefix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return trimmed.hasSuffix("/") ? trimmed : trimmed + "/"
    }

    var normalizedAuthor: String {
        let trimmed = author.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? loginAuthorName : trimmed
    }

    var accessSignature: String {
        [normalizedLocalDirectory, normalizedHostURL, normalizedRepoPathPrefix].joined(separator: "\n")
    }

    var isAccessVerified: Bool {
        !verifiedAccessSignature.isEmpty && verifiedAccessSignature == accessSignature
    }

    var displayName: String {
        let path = normalizedLocalDirectory
        if path.isEmpty {
            return "Untitled Folder"
        }
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }

    var detailText: String {
        let path = normalizedLocalDirectory
        return path.isEmpty ? normalizedHostURL : path
    }

    var lastMergeDate: Date? {
        let path = (normalizedLocalDirectory as NSString).appendingPathComponent(".cling/repository/refs/head")
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else {
            return nil
        }
        return attrs[.modificationDate] as? Date
    }
}
