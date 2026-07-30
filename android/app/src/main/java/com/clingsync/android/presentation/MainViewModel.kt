package com.clingsync.android.presentation

import android.Manifest
import android.app.Application
import android.content.pm.PackageManager
import android.os.Build
import androidx.core.content.ContextCompat
import androidx.lifecycle.AndroidViewModel
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.work.WorkInfo
import androidx.work.WorkManager
import com.clingsync.android.FileChecker
import com.clingsync.android.FileStatus
import com.clingsync.android.GoBridgeProvider
import com.clingsync.android.PassphraseStore
import com.clingsync.android.RecentTargets
import com.clingsync.android.RepositoryUriStore
import com.clingsync.android.S3CredentialsResult
import com.clingsync.android.SHA256Cache
import com.clingsync.android.SettingsManager
import com.clingsync.android.ShareTargetOptions
import com.clingsync.android.UploadWorker
import com.clingsync.android.data.UploadProgressIo
import com.clingsync.android.effect.RepositoryGateway
import com.clingsync.android.getSourceDirectory
import com.clingsync.android.getSourceFiles
import com.clingsync.android.needsAllFilesAccess
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.receiveAsFlow
import kotlinx.coroutines.launch
import kotlinx.coroutines.suspendCancellableCoroutine
import kotlinx.coroutines.withContext
import java.io.File

// The single state holder for the main screen. Holds one immutable MainUiState,
// runs the pure reducers, observes WorkManager, drives connect/scan/upload, and
// emits ViewActions for the things only the Activity can do.
class MainViewModel(
    application: Application,
    private val settingsManager: SettingsManager,
    private val passphraseStore: PassphraseStore,
    private val repositoryUriStore: RepositoryUriStore,
    private val gateway: RepositoryGateway,
    private val fileChecker: FileChecker,
    private val workManager: WorkManager,
    private val ioDispatcher: CoroutineDispatcher,
    // The share flow reuses this ViewModel over a fixed staged-files directory and a
    // chosen target prefix instead of the camera source + settings prefix.
    private val sourceDirOverride: String? = null,
    private val shareMode: Boolean = false,
) : AndroidViewModel(application) {
    private val _state =
        MutableStateFlow(
            if (shareMode) {
                val settings = settingsManager.getSettings()
                val options = ShareTargetOptions.from(settings.repoPathPrefix, RecentTargets.load(application))
                MainUiState(
                    settings = settings.copy(repoPathPrefix = options.default),
                    // Staged files need no permission; show the loading state until they are staged + loaded.
                    hasPermission = true,
                    isLoadingFiles = true,
                    shareMode = true,
                    shareTargetOptions = options.options,
                )
            } else {
                MainUiState.initial(settingsManager.getSettings())
            },
        )
    val state: StateFlow<MainUiState> = _state.asStateFlow()

    private val _actions = Channel<ViewAction>(Channel.BUFFERED)
    val actions = _actions.receiveAsFlow()

    private var scanJob: Job? = null
    private var connectJob: Job? = null
    private var s3Continuation: CancellableContinuation<S3CredentialsResult>? = null

    // Whether THIS ViewModel enqueued the upload it is observing. Both the main and
    // the share ViewModel watch the same unique work, so the share screen also sees
    // a backup upload that was already running; that foreign upload must not be
    // reported as the share's outcome.
    private var enqueuedOwnUpload = false

    init {
        viewModelScope.launch {
            workManager.getWorkInfosForUniqueWorkFlow(UploadWorker.WORK_NAME).collect(::handleWorkInfos)
        }
    }

    // --- Event entry point ---------------------------------------------------

    fun dispatch(event: MainEvent) {
        val reduction = MainReducer.reduce(_state.value, event)
        _state.value = reduction.state
        reduction.effects.forEach(::runEffect)
        orchestrate(event)
    }

    // Side orchestration that goes beyond a pure state change.
    private fun orchestrate(event: MainEvent) {
        when (event) {
            is MainEvent.PassphraseEntered -> openWith(event.result.passphrase, event.result.saveToKeychain)
            is MainEvent.PassphraseLoaded -> openWith(event.passphrase, saveToKeychain = false)
            is MainEvent.PassphraseLoadFailed ->
                if (event.error.contains("re-enter", ignoreCase = true)) {
                    dispatch(MainEvent.ShowPassphrasePrompt(passphraseStore.canStoreSecurely()))
                }
            is MainEvent.S3CredentialsEntered -> {
                s3Continuation?.takeIf { it.isActive }?.resumeWith(Result.success(event.result))
                s3Continuation = null
            }
            MainEvent.S3CredentialsDismissed -> {
                s3Continuation?.takeIf { it.isActive }?.resumeWith(Result.failure(CancelledException))
                s3Continuation = null
            }
            else -> Unit
        }
    }

    private fun runEffect(effect: Effect) {
        when (effect) {
            is Effect.EnqueueUpload -> {
                scanJob?.cancel()
                scanJob = null
                enqueuedOwnUpload = true
                if (shareMode) {
                    RecentTargets.record(getApplication(), _state.value.settings.repoPathPrefix)
                }
                val id =
                    UploadWorker.enqueueUpload(
                        getApplication(),
                        effect.paths,
                        effect.author,
                        repoPathPrefix = _state.value.settings.repoPathPrefix,
                        sourceDir = sourceDirOverride,
                    )
                dispatchWork(WorkUpdate.Enqueued(id))
            }
            Effect.CancelUpload -> workManager.cancelUniqueWork(UploadWorker.WORK_NAME)
            is Effect.PersistSettings -> settingsManager.saveSettings(effect.settings)
            is Effect.InvalidateRepository -> {
                // Emitted only on a repository switch. A connect still in flight for
                // the old repository must not survive it: its late success would mark
                // the app connected while the bridge holds the old repository, and
                // uploads would land there.
                connectJob?.cancel()
                passphraseStore.delete(effect.repositoryId)
                repositoryUriStore.clear(effect.repositoryId)
            }
            Effect.LoadFiles -> loadFiles()
            Effect.Connect -> connect()
            Effect.OpenStorageSettings -> emit(ViewAction.OpenStorageSettings)
            Effect.FinishShare -> emit(ViewAction.Finish)
        }
    }

    // --- Startup -------------------------------------------------------------

    // Called by the Activity once it is listening for actions. Mirrors the old
    // LaunchedEffect(Unit): resume an open repo, then load files / ask for perms.
    fun onStart() {
        viewModelScope.launch {
            val settings = _state.value.settings
            if (settings.isValid()) {
                if (gateway.isAlreadyOpen(settings)) {
                    dispatch(MainEvent.ConnectSucceeded)
                } else {
                    // The ViewModel can outlive the repository: a recreate (rotation
                    // while away) re-runs onStart with state still claiming the
                    // connection the background grace close dropped. Reset it, or
                    // connect()'s isConnected guard would block the reopen forever.
                    if (_state.value.isConnected) {
                        dispatch(MainEvent.RepositoryClosed)
                    }
                    if (shareMode || passphraseStore.hasStoredPassphrase(settings.repositoryID())) {
                        // The share connects eagerly (prompting if needed) so it scans right away.
                        connect()
                    }
                }
            }
            if (shareMode) {
                // Staged files live in the app cache, so no media permission is needed.
                dispatch(MainEvent.PermissionResult(true))
            } else {
                val granted = requiredPermissions().all { hasPermission(it) }
                dispatch(MainEvent.PermissionResult(granted))
                if (!granted) {
                    emit(ViewAction.RequestPermissions)
                }
            }
        }
    }

    // Returning to the foreground. The background grace close (RepositoryCloser) may
    // have dropped the repository while the app was away: if this screen still shows
    // a connection the bridge no longer has, re-open (a Keychain passphrase unlocks
    // via biometrics, otherwise the passphrase prompt is shown). A connect already in
    // flight is left alone, or its prompt would be duplicated and its S3 continuation
    // leaked. The repository can also have been opened by the other Activity (main
    // screen vs share) in the meantime; then this screen just adopts the connection.
    fun onResumed() {
        viewModelScope.launch {
            val s = _state.value
            if (!s.settings.isValid() || s.isConnecting) return@launch
            // A finished share only shows its outcome dialog; re-authenticating
            // just to let the user acknowledge it would be pointless friction.
            if (s.shareOutcome != null) return@launch
            if (gateway.isAlreadyOpen(s.settings)) {
                if (!s.isConnected) {
                    dispatch(MainEvent.ConnectSucceeded)
                    scanUnscanned()
                }
            } else if (s.isConnected) {
                dispatch(MainEvent.RepositoryClosed)
                connect()
            }
        }
    }

    private fun requiredPermissions(): Array<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO)
        } else {
            arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
        }

    private fun hasPermission(permission: String): Boolean =
        ContextCompat.checkSelfPermission(getApplication(), permission) == PackageManager.PERMISSION_GRANTED

    // --- Connection ----------------------------------------------------------

    private fun connect() {
        val s = _state.value
        if (s.isConnected || s.isConnecting) return
        if (passphraseStore.hasStoredPassphrase(s.settings.repositoryID())) {
            emit(ViewAction.LoadStoredPassphrase(s.settings.repositoryID()))
        } else {
            dispatch(MainEvent.ShowPassphrasePrompt(passphraseStore.canStoreSecurely()))
        }
    }

    private fun openWith(
        passphrase: String,
        saveToKeychain: Boolean,
    ) {
        dispatch(MainEvent.ConnectStarted)
        connectJob =
            viewModelScope.launch {
                try {
                    gateway.open(_state.value.settings, passphrase) { askS3() }
                    // A connect cancelled by a repository switch must not record a
                    // connection for the repository the bridge no longer targets.
                    ensureActive()
                    dispatch(MainEvent.ConnectSucceeded)
                    if (saveToKeychain) {
                        emit(ViewAction.SavePassphrase(passphrase, _state.value.settings.repositoryID()))
                    }
                    scanUnscanned()
                } catch (e: CancellationException) {
                    throw e
                } catch (e: CancelledException) {
                    // A dismissed credentials prompt is a decline, not a failure.
                    dispatch(MainEvent.RepositoryClosed)
                } catch (e: Exception) {
                    dispatch(MainEvent.ConnectFailed("Failed to connect: ${e.message}"))
                }
            }
    }

    private suspend fun askS3(): S3CredentialsResult =
        suspendCancellableCoroutine { cont ->
            s3Continuation = cont
            dispatch(MainEvent.ShowS3Prompt)
            cont.invokeOnCancellation { s3Continuation = null }
        }

    // --- File loading & scanning --------------------------------------------

    private fun loadFiles() {
        viewModelScope.launch { loadAndScanFiles() }
    }

    private suspend fun loadAndScanFiles() {
        dispatch(MainEvent.LoadingStarted)
        val settings = _state.value.settings
        val sourceDir = sourceDirOverride?.let(::File) ?: getSourceDirectory(settings)
        val mediaOnly = !shareMode && settings.mediaOnly
        val files = withContext(ioDispatcher) { getSourceFiles(sourceDir, mediaOnly) }
        // The prompt cannot be keyed on the scan result: scoped storage hides files by
        // omitting them from listings, not by failing (see needsAllFilesAccess). A
        // media-only backup never prompts: the runtime media permissions govern media
        // visibility, and the directories they cannot enter (e.g. Android/data) stay
        // unreadable even with "All files access".
        val needsStoragePermission =
            !shareMode && !settings.mediaOnly && needsAllFilesAccess(getApplication(), sourceDir)
        dispatch(MainEvent.FilesLoaded(files, needsStoragePermission))
        scanUnscanned()
    }

    private fun scanUnscanned() {
        val s = _state.value
        if (!s.settings.isValid() || s.files.isEmpty() || !s.isConnected || scanJob != null) return
        // New is rechecked like never-scanned (cheap, the hash cache answers), so a
        // failed or cancelled scan that reverted files to New heals on the next scan.
        // A stale Scanning marker (its scan died without a ScanFailed) heals the same way.
        val toCheck =
            s.files.filter {
                when (s.fileStatus[it.absolutePath]) {
                    null, FileStatus.New, FileStatus.Scanning -> true
                    else -> false
                }
            }
        if (toCheck.isEmpty()) return
        scanJob =
            viewModelScope.launch {
                runFileCheck(toCheck.map { it.absolutePath })
                scanJob = null
            }
    }

    private suspend fun runFileCheck(paths: List<String>) {
        dispatch(MainEvent.ScanStarted(paths))
        val result =
            fileChecker.checkFiles(
                filePaths = paths,
                onProgress = { update ->
                    // Invoked on the checker's IO dispatcher; state mutation must stay
                    // on the main thread or concurrent dispatches lose updates.
                    viewModelScope.launch {
                        dispatch(MainEvent.ScanProgress(update.processedCount, update.totalFiles, update.statuses))
                    }
                },
            )
        result.fold(
            onSuccess = {
                dispatch(MainEvent.ScanCompleted(it.statuses))
                // The share pre-selects every not-already-uploaded file.
                if (shareMode) dispatch(MainEvent.SelectAllClicked)
            },
            onFailure = { dispatch(MainEvent.ScanFailed(it.message ?: "unknown error", paths)) },
        )
    }

    // --- WorkManager observation --------------------------------------------

    private fun dispatchWork(update: WorkUpdate) {
        _state.value = UploadReducer.reduce(_state.value, update)
    }

    private suspend fun handleWorkInfos(infos: List<WorkInfo>) {
        val s = _state.value
        val workInfo =
            infos.find { it.id == s.currentUploadId }
                ?: infos.lastOrNull { it.state == WorkInfo.State.RUNNING || it.state == WorkInfo.State.ENQUEUED }
                ?: if (s.isUploading || s.isUploadInitiated) infos.lastOrNull() else null
        workInfo ?: return

        // Reattach to a running job after process death (no current id yet).
        if (s.currentUploadId == null &&
            (workInfo.state == WorkInfo.State.RUNNING || workInfo.state == WorkInfo.State.ENQUEUED)
        ) {
            dispatchWork(WorkUpdate.Enqueued(workInfo.id))
        }

        val isTerminal =
            workInfo.state == WorkInfo.State.SUCCEEDED ||
                workInfo.state == WorkInfo.State.FAILED ||
                workInfo.state == WorkInfo.State.CANCELLED
        if (isTerminal && workInfo.id != _state.value.currentUploadId && !_state.value.isUploading) {
            return
        }

        val update =
            when (workInfo.state) {
                WorkInfo.State.ENQUEUED, WorkInfo.State.BLOCKED -> return
                WorkInfo.State.RUNNING -> {
                    val statusFile = workInfo.progress.getString("status_file")?.let(::File)
                    val bytes = workInfo.progress.getLong("uploaded_bytes", 0)
                    val statuses =
                        withContext(ioDispatcher) { statusFile?.takeIf { it.exists() }?.let(::readProgress) }
                            ?: emptyMap()
                    WorkUpdate.Running(statuses, bytes)
                }
                WorkInfo.State.SUCCEEDED -> {
                    val resultFile = workInfo.outputData.getString("result_file")?.let(::File)
                    // Missing result file -> keep existing statuses (as the original
                    // did); a read failure falls back to marking in-flight files done.
                    val finalStatuses =
                        withContext(ioDispatcher) {
                            resultFile?.takeIf { it.exists() }?.let {
                                val parsed = readResult(it)
                                it.delete()
                                parsed
                            }
                        } ?: emptyMap()
                    WorkUpdate.Succeeded(finalStatuses)
                }
                WorkInfo.State.FAILED ->
                    WorkUpdate.Failed(workInfo.outputData.getString("error") ?: "Upload failed")
                WorkInfo.State.CANCELLED -> WorkUpdate.Cancelled
                else -> return
            }
        // Capture the upload size before dispatchWork resets the per-upload fields.
        val uploadCount = _state.value.currentUploadPaths.size
        dispatchWork(update)
        // A share returns to the main app after its outcome is acknowledged; an abort
        // keeps the share open so the user can retry or cancel. Only an upload this
        // screen enqueued counts: the share also observes (and may abort) a backup
        // upload that was already running, whose outcome is not the share's.
        if (shareMode && enqueuedOwnUpload) {
            _state.value =
                when (update) {
                    is WorkUpdate.Succeeded -> _state.value.copy(shareOutcome = ShareOutcome.Success(uploadCount))
                    is WorkUpdate.Failed -> _state.value.copy(shareOutcome = ShareOutcome.Failure(update.error))
                    else -> _state.value
                }
        }
    }

    private fun readProgress(file: File): Map<String, FileStatus> =
        try {
            UploadProgressIo.readProgress(file)
        } catch (e: Exception) {
            emptyMap()
        }

    private fun readResult(file: File): Map<String, FileStatus> =
        try {
            UploadProgressIo.readResult(file)
        } catch (e: Exception) {
            fallbackFinalStatuses()
        }

    // When the result file can't be read, mark every in-flight file done.
    private fun fallbackFinalStatuses(): Map<String, FileStatus> =
        _state.value.fileStatus
            .filterValues {
                it is FileStatus.Waiting ||
                    it is FileStatus.Uploading ||
                    it is FileStatus.Uploaded ||
                    it is FileStatus.Committing
            }
            .mapValues { FileStatus.Done }

    private fun emit(action: ViewAction) {
        _actions.trySend(action)
    }

    private object CancelledException : Exception("cancelled")

    class Factory(
        private val application: Application,
        private val sourceDirOverride: String? = null,
        private val shareMode: Boolean = false,
    ) : ViewModelProvider.Factory {
        override fun <T : ViewModel> create(modelClass: Class<T>): T {
            val bridge = GoBridgeProvider.getInstance()
            val uriStore = RepositoryUriStore(application)
            @Suppress("UNCHECKED_CAST")
            return MainViewModel(
                application = application,
                settingsManager = SettingsManager(application),
                passphraseStore = PassphraseStore(application),
                repositoryUriStore = uriStore,
                gateway = RepositoryGateway(bridge, uriStore, Dispatchers.IO),
                fileChecker = FileChecker(SHA256Cache.getInstance(application), Dispatchers.IO),
                workManager = WorkManager.getInstance(application),
                ioDispatcher = Dispatchers.IO,
                sourceDirOverride = sourceDirOverride,
                shareMode = shareMode,
            ) as T
        }
    }
}
