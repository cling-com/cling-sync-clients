package com.clingsync.android.presentation

import com.clingsync.android.FileStatus
import com.clingsync.android.UploadInfo
import com.clingsync.android.validateHostUrl

// Pure transition table for user intents and internal completions. Returns the
// next state plus the side effects the ViewModel should perform. No IO, no
// Android framework, no coroutines: every rule is one assertable function.
object MainReducer {
    fun reduce(
        state: MainUiState,
        event: MainEvent,
    ): Reduction =
        when (event) {
            is MainEvent.FileSelectionChanged ->
                only(
                    state.copy(
                        selectedPaths =
                            if (event.selected) {
                                state.selectedPaths + event.path
                            } else {
                                state.selectedPaths - event.path
                            },
                    ),
                )

            MainEvent.SelectAllClicked -> only(state.copy(selectedPaths = state.selectAllTargets))

            is MainEvent.SearchQueryChanged ->
                only(state.copy(searchQuery = event.query, selectedPaths = emptySet()))

            MainEvent.SearchToggled -> {
                val opening = !state.showSearch
                only(
                    state.copy(
                        showSearch = opening,
                        searchQuery = if (opening) state.searchQuery else "",
                        selectedPaths = if (opening) emptySet() else state.selectedPaths,
                    ),
                )
            }

            MainEvent.SearchCleared -> only(state.copy(searchQuery = ""))

            MainEvent.RefreshClicked -> Reduction(state, listOf(Effect.LoadFiles))

            MainEvent.UploadClicked -> upload(state)

            MainEvent.AbortClicked ->
                Reduction(state.copy(isUploadInitiated = false), listOf(Effect.CancelUpload))

            is MainEvent.PermissionResult ->
                if (event.granted) {
                    Reduction(state.copy(hasPermission = true), listOf(Effect.LoadFiles))
                } else {
                    only(state.copy(hasPermission = false))
                }

            MainEvent.LoadingStarted -> only(state.copy(isLoadingFiles = true))

            is MainEvent.FilesLoaded ->
                only(
                    state.copy(
                        isLoadingFiles = false,
                        files = event.files,
                        overlay =
                            if (event.needsStoragePermission && state.overlay is Overlay.None) {
                                Overlay.StoragePermission
                            } else {
                                state.overlay
                            },
                    ),
                )

            is MainEvent.ScanStarted ->
                only(
                    state.copy(
                        isScanning = true,
                        scanProgress = 0 to event.paths.size,
                        fileStatus = state.fileStatus + event.paths.associateWith { FileStatus.Scanning },
                    ),
                )

            is MainEvent.ScanProgress ->
                only(
                    state.copy(
                        fileStatus = state.fileStatus + event.statuses,
                        scanProgress = event.processed to event.total,
                    ),
                )

            is MainEvent.ScanCompleted ->
                only(
                    state.copy(
                        fileStatus = state.fileStatus + event.statuses,
                        scanProgress = null,
                        isScanning = false,
                    ),
                )

            is MainEvent.ScanFailed -> scanFailed(state, event)

            MainEvent.SettingsClicked -> only(state.copy(showSettings = true))

            MainEvent.SettingsDismissed -> only(state.copy(showSettings = false))

            is MainEvent.SettingsSaved -> settingsSaved(state, event)

            is MainEvent.SettingsTestConnection -> {
                val urlError = validateHostUrl(event.settings.hostUrl)
                if (urlError != null) {
                    only(state.copy(overlay = Overlay.Error("Invalid Host URL", urlError)))
                } else {
                    Reduction(state.copy(settings = event.settings), listOf(Effect.Connect))
                }
            }

            MainEvent.ConnectClicked -> Reduction(state, listOf(Effect.Connect))

            MainEvent.ConnectStarted -> only(state.copy(isConnecting = true))

            MainEvent.ConnectSucceeded ->
                only(state.copy(isConnecting = false, isConnected = true))

            is MainEvent.ConnectFailed ->
                only(
                    state.copy(
                        isConnecting = false,
                        isConnected = false,
                        overlay =
                            if (state.overlay is Overlay.None) {
                                Overlay.Error("Connection Error", event.message)
                            } else {
                                state.overlay
                            },
                    ),
                )

            is MainEvent.ShowPassphrasePrompt ->
                only(state.copy(overlay = Overlay.Passphrase(event.showKeychainOption)))

            is MainEvent.PassphraseEntered -> only(state.copy(overlay = Overlay.None))

            MainEvent.PassphraseDismissed -> only(state.copy(overlay = Overlay.None))

            // Biometric results are consumed by the ViewModel (to drive the open
            // flow); they carry no state change of their own.
            is MainEvent.PassphraseLoaded -> only(state)

            is MainEvent.PassphraseLoadFailed -> only(state)

            MainEvent.ShowS3Prompt -> only(state.copy(overlay = Overlay.S3Credentials))

            is MainEvent.S3CredentialsEntered -> only(state.copy(overlay = Overlay.None))

            MainEvent.S3CredentialsDismissed -> only(state.copy(overlay = Overlay.None))

            MainEvent.ErrorDismissed -> only(state.copy(overlay = Overlay.None))

            MainEvent.StoragePermissionDismissed -> only(state.copy(overlay = Overlay.None))

            MainEvent.OpenStorageSettingsClicked ->
                Reduction(state.copy(overlay = Overlay.None), listOf(Effect.OpenStorageSettings))
        }

    private fun only(state: MainUiState): Reduction = Reduction(state)

    private fun upload(state: MainUiState): Reduction {
        val paths = state.selectedFiles.map { it.absolutePath }
        if (paths.isEmpty()) return only(state)
        return Reduction(
            state.copy(
                isUploadInitiated = true,
                scanProgress = null,
                uploadInfo = UploadInfo(currentFile = null, currentIndex = 0, totalFiles = paths.size),
                currentUploadPaths = paths.toSet(),
                fileStatus = state.fileStatus + paths.associateWith { FileStatus.Waiting },
                selectedPaths = emptySet(),
            ),
            listOf(Effect.EnqueueUpload(paths, state.settings.author)),
        )
    }

    private fun scanFailed(
        state: MainUiState,
        event: MainEvent.ScanFailed,
    ): Reduction {
        val reverted =
            event.paths.filter { state.fileStatus[it] is FileStatus.Scanning }.associateWith { FileStatus.New }
        return only(
            state.copy(
                fileStatus = state.fileStatus + reverted,
                scanProgress = null,
                isScanning = false,
                overlay =
                    if (state.overlay is Overlay.None) {
                        Overlay.Error("File Scanning Error", "Some files could not be scanned: ${event.message}")
                    } else {
                        state.overlay
                    },
            ),
        )
    }

    private fun settingsSaved(
        state: MainUiState,
        event: MainEvent.SettingsSaved,
    ): Reduction {
        val urlError = validateHostUrl(event.settings.hostUrl)
        if (urlError != null) {
            return only(state.copy(overlay = Overlay.Error("Invalid Host URL", urlError)))
        }
        val oldId = state.settings.repositoryID()
        val repositoryChanged = oldId != event.settings.repositoryID()
        val sourceChanged =
            state.settings.sourceDirectory != event.settings.sourceDirectory ||
                state.settings.mediaOnly != event.settings.mediaOnly
        val base = state.copy(settings = event.settings, showSettings = false)
        val persist = Effect.PersistSettings(event.settings)
        return when {
            repositoryChanged ->
                Reduction(
                    base.copy(fileStatus = emptyMap(), isConnected = false, selectedPaths = emptySet()),
                    listOf(persist, Effect.InvalidateRepository(oldId), Effect.LoadFiles),
                )
            sourceChanged ->
                Reduction(
                    base.copy(fileStatus = emptyMap(), selectedPaths = emptySet()),
                    listOf(persist, Effect.LoadFiles),
                )
            else -> Reduction(base, listOf(persist))
        }
    }
}
