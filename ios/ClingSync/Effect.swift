import Foundation

// A side effect the reducer requests and the store performs. Keeping these as
// data (rather than calling out directly) is what lets the reducers stay pure
// and assertable: a test checks `reduction.effects`, no IO runs.
enum Effect: Equatable {
    case enqueueUpload(ids: [String], author: String)
    case cancelUpload
    case persistSettings(RepositoryConfiguration)
    // Drop the stored passphrase + encoded URI of a repository we left.
    case invalidateRepository(repositoryID: String)
    case loadFiles
    // Open the repository (the store drives the passphrase/S3 prompts + gateway).
    case connect
}

struct Reduction: Equatable {
    var state: AppState
    var effects: [Effect] = []

    static func only(_ state: AppState) -> Reduction {
        Reduction(state: state)
    }
}
