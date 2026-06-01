import Photos

struct ResolvedPassphrase {
    let passphrase: String
    let mode: PassphraseStorageMode
}

@MainActor
extension ContentView {
    func initialize() async {
        applyUITestConfigurationIfNeeded()
        guard configuration.isConfigured else {
            appState = .needsSettings
            return
        }
        if hasStoredPassphrase {
            appState = .connectingToServer
            await connectToRepository(promptIfNeeded: false)
        } else {
            repositoryConnected = false
            await enterReadyState()
        }
    }

    func applyUITestConfigurationIfNeeded() {
        guard isUITestMode else {
            return
        }
        let environment = ProcessInfo.processInfo.environment
        if hostURL.isEmpty, let configuredHostURL = environment["CLING_SYNC_UI_TEST_HOST_URL"] {
            hostURL = configuredHostURL
        }
        if repoPathPrefix.isEmpty, let configuredRepoPathPrefix = environment["CLING_SYNC_UI_TEST_REPO_PATH_PREFIX"] {
            repoPathPrefix = configuredRepoPathPrefix
        }
        if author.isEmpty, let configuredAuthor = environment["CLING_SYNC_UI_TEST_AUTHOR"] {
            author = configuredAuthor
        }
    }

    func handleSettingsSave(configuration: RepositoryConfiguration, repositoryVerified: Bool) {
        let previousConfiguration = self.configuration
        hostURL = configuration.hostURL
        repoPathPrefix = configuration.repoPathPrefix
        author = configuration.author

        guard configuration.isConfigured else {
            repositoryConnected = false
            appState = .needsSettings
            return
        }
        let repositoryChanged = previousConfiguration.repositoryID != configuration.repositoryID
        if repositoryChanged && !previousConfiguration.repositoryID.isEmpty {
            try? PassphraseStore.shared.clear(for: previousConfiguration.repositoryID)
            RepositoryURIStore.clear(for: previousConfiguration.hostURL)
        }
        repositoryConnected = repositoryVerified || (!repositoryChanged && repositoryConnected)
        appState = .ready
        if isUITestMode {
            files = loadUITestFiles()
            applyIndexedStatus()
            if repositoryConnected {
                Task { await checkFilesInRepository() }
            } else {
                markUnknownFilesAsNew()
            }
        } else {
            Task { await loadMediaLibrary() }
        }
    }

    func enterReadyState() async {
        appState = .ready
        if files.isEmpty {
            await loadMediaLibrary()
            return
        }
        applyIndexedStatus()
        if repositoryConnected {
            await checkFilesInRepository()
        } else if isUITestMode {
            markUnknownFilesAsNew()
        }
    }

    func connectToRepository(promptIfNeeded: Bool) async {
        guard configuration.isConfigured else {
            appState = .needsSettings
            return
        }
        do {
            let currentConfiguration = configuration
            let connection = try await openRepositoryIfNeeded(
                configuration: currentConfiguration,
                promptIfNeeded: promptIfNeeded
            )
            guard let connection else {
                repositoryConnected = false
                await enterReadyState()
                return
            }
            SyncIndexStore.shared.resetIfRepositoryChanged(
                repositoryID: currentConfiguration.repositoryID,
                headRevisionID: connection.headRevisionId
            )
            repositoryConnected = true
            await enterReadyState()
        } catch let error as PassphraseStoreError {
            repositoryConnected = false
            appState = .connectionFailed(error.message)
        } catch let error as BridgeError {
            repositoryConnected = false
            appState = .connectionFailed(error.message)
        } catch {
            repositoryConnected = false
            appState = .connectionFailed(error.localizedDescription)
        }
    }

    func openRepositoryIfNeeded(
        configuration: RepositoryConfiguration,
        promptIfNeeded: Bool
    ) async throws -> RepositoryConnectionInfo? {
        // Check if the repository is already open. The repo is opened under the
        // encrypted URI (S3 credentials embedded), so we must check that same URI;
        // passing the cleartext host URL would look like a different repository and
        // make the bridge close the open one, forcing a needless re-open.
        let repositoryURI = RepositoryURIStore.get(for: configuration.hostURL) ?? configuration.hostURL
        let status = try await Task.detached(priority: .userInitiated) {
            try Bridge.checkRepositoryOpen(url: repositoryURI)
        }.value
        if status.open {
            return RepositoryConnectionInfo(headRevisionId: status.headRevisionId)
        }

        // Repository not open — we need the passphrase.
        guard
            let access = try await passphrasePromptController.resolvePassphrase(
                repositoryID: configuration.repositoryID,
                currentMode: passphraseStorageMode,
                promptIfNeeded: promptIfNeeded,
                allowsKeychainSave: true,
                promptMessage: "Enter the repository passphrase to connect."
            )
        else {
            return nil
        }

        try await Bridge.triggerNetworkPermissionIfNeeded(url: configuration.hostURL)
        let connection = try await s3CredentialsPromptController.openRepository(
            hostURL: configuration.hostURL, passphrase: access.passphrase)

        if access.mode.savesInKeychain {
            try PassphraseStore.shared.save(
                passphrase: access.passphrase, for: configuration.repositoryID, mode: access.mode)
        }
        passphraseStorageModeRaw = access.mode.rawValue

        return connection
    }

    func loadMediaLibrary() async {
        isLoading = true
        defer { isLoading = false }

        if isUITestMode {
            files = loadUITestFiles()
            applyIndexedStatus()
            if repositoryConnected {
                await checkFilesInRepository()
            } else {
                markUnknownFilesAsNew()
            }
            return
        }

        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            files = []
            return
        }

        let fetchOptions = PHFetchOptions()
        fetchOptions.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        let assets = PHAsset.fetchAssets(with: fetchOptions)
        files = await Task.detached(priority: .userInitiated) {
            var loadedFiles: [MediaFile] = []
            assets.enumerateObjects { asset, _, _ in
                guard let resource = primaryResource(for: asset) else { return }
                loadedFiles.append(
                    MediaFile(
                        name: resource.originalFilename,
                        size: fileSize(for: resource),
                        asset: asset,
                        resource: resource,
                        modificationDate: asset.modificationDate ?? asset.creationDate ?? .distantPast
                    ))
            }
            return loadedFiles
        }.value

        applyIndexedStatus()
        if repositoryConnected {
            await checkFilesInRepository()
        } else if isUITestMode {
            markUnknownFilesAsNew()
        }
    }

    func applyIndexedStatus() {
        for file in files {
            file.uploadState =
                SyncIndexStore.shared.contains(file.syncedRecord, repositoryID: configuration.repositoryID)
                ? .done : .none
        }
    }

    func markUnknownFilesAsNew() {
        for file in files where file.uploadState == .none {
            file.uploadState = .new
        }
    }

    func checkFilesInRepository() async {
        let pendingFiles = files.filter { $0.uploadState == .none }
        guard !pendingFiles.isEmpty else { return }

        for file in pendingFiles {
            file.uploadState = .checking
        }

        let checker = FileChecker(
            files: pendingFiles,
            fileStatusUpdate: { fileStatuses in
                DispatchQueue.main.async {
                    for file in pendingFiles {
                        guard let repoPath = fileStatuses[file.id] else { continue }
                        file.uploadState = repoPath.isEmpty ? .new : .exists(repoPath: repoPath)
                    }
                }
            },
            progressUpdate: { _, _ in }
        )

        do {
            try await checker.checkFiles()
        } catch {
            for file in pendingFiles where file.uploadState == .checking {
                file.uploadState = .new
            }
        }
    }

    func toggleSelectAll() {
        if selectedFileNames.count == selectableFiles.count && !selectableFiles.isEmpty {
            selectedFileNames.removeAll()
        } else {
            selectedFileNames = Set(selectableFiles.map { $0.id })
        }
    }

    func toggleSelection(for file: MediaFile) {
        guard isSelectable(file) else { return }
        if selectedFileNames.contains(file.id) {
            selectedFileNames.remove(file.id)
        } else {
            selectedFileNames.insert(file.id)
        }
    }

    func startUpload() async {
        guard !selectedFileNames.isEmpty, uploader == nil else { return }
        do {
            let currentConfiguration = configuration
            let connection = try await openRepositoryIfNeeded(
                configuration: currentConfiguration,
                promptIfNeeded: true
            )
            guard let connection else { return }
            repositoryConnected = true

            let uploader = Uploader(
                files: selectedFiles, configuration: configuration, headRevisionId: connection.headRevisionId)
            self.uploader = uploader
            uploader.start()
            selectedFileNames.removeAll()
        } catch let error as PassphraseStoreError {
            appState = .connectionFailed(error.message)
        } catch let error as BridgeError {
            appState = .connectionFailed(error.message)
        } catch {
            appState = .connectionFailed(error.localizedDescription)
        }
    }
}
