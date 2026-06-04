package com.clingsync.android.presentation

import android.Manifest
import android.app.Application
import android.content.pm.PackageManager
import android.os.Build
import android.os.Environment
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
import com.clingsync.android.RepositoryUriStore
import com.clingsync.android.S3CredentialsResult
import com.clingsync.android.SHA256Cache
import com.clingsync.android.SettingsManager
import com.clingsync.android.UploadWorker
import com.clingsync.android.data.UploadProgressIo
import com.clingsync.android.effect.RepositoryGateway
import com.clingsync.android.getSourceDirectory
import com.clingsync.android.getSourceFiles
import kotlinx.coroutines.CancellableContinuation
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.channels.Channel
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
) : AndroidViewModel(application) {
    private val _state = MutableStateFlow(MainUiState.initial(settingsManager.getSettings()))
    val state: StateFlow<MainUiState> = _state.asStateFlow()

    private val _actions = Channel<ViewAction>(Channel.BUFFERED)
    val actions = _actions.receiveAsFlow()

    private var scanJob: Job? = null
    private var s3Continuation: CancellableContinuation<S3CredentialsResult>? = null

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
                    dispatch(MainEvent.ShowPassphrasePrompt(passphraseStore.canUseBiometric()))
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
                val id = UploadWorker.enqueueUpload(getApplication(), effect.paths, effect.author)
                dispatchWork(WorkUpdate.Enqueued(id))
            }
            Effect.CancelUpload -> workManager.cancelUniqueWork(UploadWorker.WORK_NAME)
            is Effect.PersistSettings -> settingsManager.saveSettings(effect.settings)
            is Effect.InvalidateRepository -> {
                passphraseStore.delete(effect.repositoryId)
                repositoryUriStore.clear(effect.repositoryId)
            }
            Effect.LoadFiles -> loadFiles()
            Effect.Connect -> connect()
            Effect.OpenStorageSettings -> emit(ViewAction.OpenStorageSettings)
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
                } else if (passphraseStore.hasStoredPassphrase(settings.repositoryID())) {
                    connect()
                }
            }
            val granted = requiredPermissions().all { hasPermission(it) }
            dispatch(MainEvent.PermissionResult(granted))
            if (!granted) {
                emit(ViewAction.RequestPermissions)
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
            dispatch(MainEvent.ShowPassphrasePrompt(passphraseStore.canUseBiometric()))
        }
    }

    private fun openWith(
        passphrase: String,
        saveToKeychain: Boolean,
    ) {
        dispatch(MainEvent.ConnectStarted)
        viewModelScope.launch {
            try {
                gateway.open(_state.value.settings, passphrase) { askS3() }
                dispatch(MainEvent.ConnectSucceeded)
                if (saveToKeychain) {
                    emit(ViewAction.SavePassphrase(passphrase, _state.value.settings.repositoryID()))
                }
                scanUnscanned()
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
        val sourceDir = getSourceDirectory(settings)
        val files = withContext(ioDispatcher) { getSourceFiles(sourceDir, settings.mediaOnly) }
        val needsStoragePermission =
            files.isEmpty() &&
                sourceDir.exists() &&
                !settings.mediaOnly &&
                Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
                !Environment.isExternalStorageManager()
        dispatch(MainEvent.FilesLoaded(files, needsStoragePermission))
        scanUnscanned()
    }

    private fun scanUnscanned() {
        val s = _state.value
        if (!s.settings.isValid() || s.files.isEmpty() || !s.isConnected || scanJob != null) return
        val toCheck = s.files.filter { s.fileStatus[it.absolutePath] == null }
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
                    dispatch(MainEvent.ScanProgress(update.processedCount, update.totalFiles, update.statuses))
                },
            )
        result.fold(
            onSuccess = { dispatch(MainEvent.ScanCompleted(it.statuses)) },
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
        dispatchWork(update)
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

    class Factory(private val application: Application) : ViewModelProvider.Factory {
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
            ) as T
        }
    }
}
