import Foundation

struct SyncedFileRecord: Codable, Hashable {
    let name: String
    let size: Int64
    let modificationDate: Date
}

final class SyncIndexStore {
    static let shared = SyncIndexStore()

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func resetIfRepositoryChanged(repositoryID: String, headRevisionID: String) {
        let storedRepositoryID = defaults.string(forKey: AppStorageKey.repoIdentifier) ?? ""
        let storedHeadRevisionID = defaults.string(forKey: AppStorageKey.repoHeadRevisionId) ?? ""
        guard storedRepositoryID == repositoryID, storedHeadRevisionID == headRevisionID else {
            defaults.removeObject(forKey: AppStorageKey.syncedFileIndex)
            defaults.set(repositoryID, forKey: AppStorageKey.repoIdentifier)
            defaults.set(headRevisionID, forKey: AppStorageKey.repoHeadRevisionId)
            return
        }
    }

    func contains(_ record: SyncedFileRecord, repositoryID: String) -> Bool {
        guard defaults.string(forKey: AppStorageKey.repoIdentifier) == repositoryID else {
            return false
        }
        return loadRecords().contains(record)
    }

    func add(_ records: [SyncedFileRecord], repositoryID: String, headRevisionID: String) {
        var allRecords = loadRecords()
        allRecords.formUnion(records)
        save(records: allRecords, repositoryID: repositoryID, headRevisionID: headRevisionID)
    }

    private func loadRecords() -> Set<SyncedFileRecord> {
        guard let data = defaults.data(forKey: AppStorageKey.syncedFileIndex),
            let records = try? JSONDecoder().decode(Set<SyncedFileRecord>.self, from: data)
        else {
            return []
        }
        return records
    }

    private func save(records: Set<SyncedFileRecord>, repositoryID: String, headRevisionID: String) {
        guard let data = try? JSONEncoder().encode(records) else {
            return
        }
        defaults.set(data, forKey: AppStorageKey.syncedFileIndex)
        defaults.set(repositoryID, forKey: AppStorageKey.repoIdentifier)
        defaults.set(headRevisionID, forKey: AppStorageKey.repoHeadRevisionId)
    }
}
