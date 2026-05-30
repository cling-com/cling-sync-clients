package com.clingsync.android

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.util.Log
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.LazyListState
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.lazy.rememberLazyListState
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Search
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.livedata.observeAsState
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.fragment.app.FragmentActivity
import androidx.work.WorkInfo
import androidx.work.WorkManager
import com.clingsync.android.ui.ScrollAwareTopBar
import com.clingsync.android.ui.formatFileSize
import com.clingsync.android.ui.theme.ClingSyncTheme
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.util.UUID

sealed class FileStatus {
    object Scanning : FileStatus()

    object New : FileStatus()

    data class Exists(val repoPath: String) : FileStatus()

    object Waiting : FileStatus()

    object Uploading : FileStatus()

    object Uploaded : FileStatus()

    object Committing : FileStatus()

    object Done : FileStatus()

    object Aborted : FileStatus()

    data class Failed(val error: String) : FileStatus()
}

data class UploadInfo(
    val currentFile: String? = null,
    val currentIndex: Int = 0,
    val totalFiles: Int = 0,
)

class MainActivity : FragmentActivity() {
    private val goBridge = GoBridgeProvider.getInstance()
    private lateinit var settingsManager: SettingsManager
    private lateinit var passphraseStore: PassphraseStore

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Switch from splash screen theme to normal theme.
        setTheme(R.style.Theme_ClingSync)

        settingsManager = SettingsManager(this)
        passphraseStore = PassphraseStore(this)

        WindowCompat.setDecorFitsSystemWindows(window, false)

        setContent {
            ClingSyncTheme {
                MainScreen(
                    activity = this@MainActivity,
                    goBridge = goBridge,
                    settingsManager = settingsManager,
                    passphraseStore = passphraseStore,
                    workManager = WorkManager.getInstance(this@MainActivity),
                )
            }
        }
    }
}

@Composable
fun PermissionRequiredScreen() {
    Box(
        modifier = Modifier.fillMaxSize(),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = "Permission Required to Access Camera Files",
            style = MaterialTheme.typography.bodyLarge,
            textAlign = TextAlign.Center,
            modifier = Modifier.padding(32.dp),
        )
    }
}

@Composable
fun LoadingScreen() {
    Box(
        modifier = Modifier.fillMaxSize(),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = "Loading...",
            style = MaterialTheme.typography.bodyLarge,
        )
    }
}

@Composable
fun EmptyFilesScreen() {
    Box(
        modifier = Modifier.fillMaxSize(),
        contentAlignment = Alignment.Center,
    ) {
        Text(
            text = "No Files Found in Camera Folder",
            style = MaterialTheme.typography.bodyLarge,
        )
    }
}

@Composable
fun FileListItem(
    file: File,
    folder: String?,
    isSelected: Boolean,
    uploadStatus: FileStatus?,
    isUploading: Boolean,
    onSelectionChange: (Boolean) -> Unit,
) {
    Card(
        modifier =
            Modifier
                .fillMaxWidth()
                .toggleable(
                    value = isSelected,
                    enabled = !isUploading,
                    onValueChange = onSelectionChange,
                ),
        elevation = CardDefaults.cardElevation(defaultElevation = 2.dp),
        colors =
            if (isSelected) {
                CardDefaults.cardColors(
                    containerColor = MaterialTheme.colorScheme.primaryContainer,
                )
            } else {
                CardDefaults.cardColors(
                    containerColor = MaterialTheme.colorScheme.surfaceContainer,
                )
            },
    ) {
        Row(
            modifier =
                Modifier
                    .fillMaxWidth()
                    .padding(16.dp),
            verticalAlignment = Alignment.CenterVertically,
        ) {
            Box(
                modifier = Modifier.size(40.dp),
                contentAlignment = Alignment.Center,
            ) {
                when (uploadStatus) {
                    is FileStatus.Scanning -> {
                        CircularProgressIndicator(
                            modifier = Modifier.size(24.dp),
                            strokeWidth = 2.dp,
                        )
                    }
                    is FileStatus.Waiting, is FileStatus.Uploading, is FileStatus.Committing -> {
                        CircularProgressIndicator(
                            modifier = Modifier.size(24.dp),
                            strokeWidth = 2.dp,
                        )
                    }
                    is FileStatus.Uploaded -> {
                        // Show a static full circle for "Processing" state
                        CircularProgressIndicator(
                            progress = { 1f },
                            modifier = Modifier.size(24.dp),
                            strokeWidth = 2.dp,
                        )
                    }
                    is FileStatus.Exists, is FileStatus.Done -> {
                        Icon(
                            Icons.Default.CheckCircle,
                            contentDescription = "Synced",
                            modifier = Modifier.size(24.dp),
                            tint = MaterialTheme.colorScheme.primary,
                        )
                    }
                    else -> {
                        Checkbox(
                            checked = isSelected,
                            onCheckedChange = onSelectionChange,
                            modifier = Modifier.testTag("checkbox_${file.name}"),
                            enabled =
                                (
                                    uploadStatus is FileStatus.New ||
                                        uploadStatus is FileStatus.Failed ||
                                        uploadStatus is FileStatus.Aborted ||
                                        uploadStatus == null
                                ) && !isUploading,
                        )
                    }
                }
            }

            Spacer(modifier = Modifier.width(8.dp))

            Column(modifier = Modifier.weight(1f)) {
                if (folder != null) {
                    Text(
                        text = folder,
                        style = MaterialTheme.typography.labelSmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                        maxLines = 1,
                        overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                Text(
                    text = file.name,
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.Medium,
                    maxLines = 1,
                    overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                    modifier = Modifier.fillMaxWidth(),
                )
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.Start,
                ) {
                    Text(
                        text = formatFileSize(file.length()),
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                    uploadStatus?.let { status ->
                        val statusText =
                            when (status) {
                                is FileStatus.Scanning -> "Scanning..."
                                is FileStatus.New -> "New"
                                is FileStatus.Exists, is FileStatus.Done -> null
                                is FileStatus.Waiting -> "Waiting..."
                                is FileStatus.Uploading -> "Sending..."
                                is FileStatus.Uploaded -> "Processing..."
                                is FileStatus.Committing -> "Committing..."
                                is FileStatus.Aborted -> "Aborted"
                                is FileStatus.Failed -> "Failed: ${status.error}"
                            }
                        if (statusText != null) {
                            Text(
                                text = " • ",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurfaceVariant,
                            )
                            Text(
                                text = statusText,
                                style = MaterialTheme.typography.bodySmall,
                                color =
                                    when (status) {
                                        is FileStatus.Failed -> MaterialTheme.colorScheme.error
                                        is FileStatus.New -> MaterialTheme.colorScheme.primary
                                        else -> MaterialTheme.colorScheme.primary
                                    },
                                fontWeight = FontWeight.Medium,
                                maxLines = 1,
                                overflow = androidx.compose.ui.text.style.TextOverflow.Ellipsis,
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
fun FileList(
    files: List<File>,
    selectedFiles: Set<File>,
    fileStatus: Map<String, FileStatus>,
    isUploading: Boolean,
    sourceDir: File,
    onSelectionChange: (File, Boolean) -> Unit,
    lazyListState: LazyListState = rememberLazyListState(),
    topPadding: Dp = 88.dp,
) {
    LazyColumn(
        state = lazyListState,
        modifier =
            Modifier
                .fillMaxSize()
                .padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
        contentPadding = PaddingValues(top = topPadding, bottom = 16.dp),
    ) {
        items(files, key = { it.absolutePath }) { file ->
            val isSelected = selectedFiles.contains(file)
            val status = fileStatus[file.absolutePath]
            FileListItem(
                file = file,
                folder = getFileFolder(file, sourceDir),
                isSelected = isSelected,
                uploadStatus = status,
                isUploading = isUploading,
                onSelectionChange = { checked -> onSelectionChange(file, checked) },
            )
        }
    }
}

@Composable
fun MainScreen(
    activity: FragmentActivity,
    goBridge: IGoBridge,
    settingsManager: SettingsManager,
    passphraseStore: PassphraseStore,
    workManager: WorkManager = WorkManager.getInstance(LocalContext.current),
    ioDispatcher: CoroutineDispatcher = Dispatchers.IO,
) {
    var cameraFiles by remember { mutableStateOf<List<File>>(emptyList()) }
    var selectedFiles by remember { mutableStateOf<Set<File>>(emptySet()) }
    var fileStatus by remember { mutableStateOf(mapOf<String, FileStatus>()) }
    var hasPermission by remember { mutableStateOf(false) }
    var settings by remember { mutableStateOf(settingsManager.getSettings()) }
    var showSettingsDialog by remember { mutableStateOf(!settings.isValid()) }
    var currentErrorDialog by remember { mutableStateOf<ErrorDialogState?>(null) }
    var isLoadingFiles by remember { mutableStateOf(false) }
    var showStoragePermissionDialog by remember { mutableStateOf(false) }
    var searchQuery by remember { mutableStateOf("") }
    var showSearch by remember { mutableStateOf(false) }
    val context = LocalContext.current
    val coroutineScope = rememberCoroutineScope()
    var currentUploadInfo by remember { mutableStateOf<UploadInfo?>(null) }
    var isUploading by remember { mutableStateOf(false) }
    var isUploadInitiated by remember { mutableStateOf(false) }
    var currentUploadId by remember { mutableStateOf<UUID?>(null) }
    var currentUploadPaths by remember { mutableStateOf<Set<String>>(emptySet()) }
    val lazyListState = rememberLazyListState()
    var checkFilesJob by remember { mutableStateOf<Job?>(null) }
    var scanProgress by remember { mutableStateOf<Pair<Int, Int>?>(null) }
    val sha256Cache = remember { SHA256Cache.getInstance(context) }
    val fileChecker = remember { FileChecker(sha256Cache, ioDispatcher) }
    var isConnecting by remember { mutableStateOf(false) }
    var isConnected by remember { mutableStateOf(false) }
    var actualUploadedBytes by remember { mutableStateOf(0L) }
    // When non-null, the passphrase prompt dialog is shown. The callback receives the passphrase.
    var passphraseCallback by remember { mutableStateOf<((PassphraseResult) -> Unit)?>(null) }
    // When non-null, the S3 credentials prompt is shown.
    var s3CredentialsRequest by remember { mutableStateOf<S3CredentialsRequest?>(null) }
    // Callbacks to invoke when connection succeeds.
    val pendingOnConnected = remember { mutableListOf<() -> Unit>() }

    // Opens the repository with the given passphrase. On the first attempt the
    // bridge may report that S3 credentials are missing for this URL. We then
    // prompt for them, store them, and retry.
    fun openRepository(
        passphrase: String,
        saveToKeychain: Boolean,
    ) {
        isConnecting = true
        coroutineScope.launch {
            try {
                try {
                    withContext(ioDispatcher) {
                        goBridge.openRepository(settings.hostUrl, passphrase)
                    }
                } catch (_: S3CredentialsRequiredException) {
                    // Ask the user for S3 key / access key, store, and retry once.
                    val creds =
                        awaitS3Credentials { request -> s3CredentialsRequest = request }
                    withContext(ioDispatcher) {
                        goBridge.encryptAndStoreS3Credentials(
                            hostUrl = settings.hostUrl,
                            passphrase = passphrase,
                            accessKeyId = creds.accessKeyId,
                            accessKey = creds.accessKey,
                        )
                        goBridge.openRepository(settings.hostUrl, passphrase)
                    }
                }
                isConnecting = false
                isConnected = true
                val runPending = {
                    pendingOnConnected.forEach { it() }
                    pendingOnConnected.clear()
                }
                if (saveToKeychain) {
                    passphraseStore.save(activity, passphrase, settings.repositoryID()) {
                        runPending()
                    }
                } else {
                    runPending()
                }
            } catch (e: Exception) {
                isConnecting = false
                isConnected = false
                pendingOnConnected.clear()
                if (currentErrorDialog == null) {
                    currentErrorDialog =
                        ErrorDialogState(
                            title = "Connection Error",
                            message = "Failed to connect: ${e.message}",
                        )
                }
            }
        }
    }

    // Resolves the passphrase and opens the repository.
    // If stored in keychain → biometric prompt. Otherwise → passphrase dialog.
    fun openRepositoryIfNeeded(onConnected: () -> Unit = {}) {
        if (isConnected) {
            onConnected()
            return
        }
        pendingOnConnected.add(onConnected)
        if (isConnecting) {
            // Connection already in progress, callback queued.
            return
        }
        if (passphraseStore.hasStoredPassphrase(settings.repositoryID())) {
            passphraseStore.load(
                activity = activity,
                repositoryID = settings.repositoryID(),
                onSuccess = { passphrase -> openRepository(passphrase, saveToKeychain = false) },
                onError = { error ->
                    pendingOnConnected.clear()
                    if (error.contains("re-enter", ignoreCase = true)) {
                        passphraseCallback = { result ->
                            openRepository(result.passphrase, result.saveToKeychain)
                        }
                    }
                },
            )
        } else {
            passphraseCallback = { result ->
                openRepository(result.passphrase, result.saveToKeychain)
            }
        }
    }

    // Starts an upload, opening the repository first if needed.
    fun startUpload(filesToUpload: List<File>) {
        openRepositoryIfNeeded {
            checkFilesJob?.cancel()
            selectedFiles = emptySet()

            isUploadInitiated = true
            scanProgress = null
            currentUploadInfo = UploadInfo(currentFile = null, currentIndex = 0, totalFiles = filesToUpload.size)

            currentUploadPaths = filesToUpload.map { it.absolutePath }.toSet()
            fileStatus = fileStatus + filesToUpload.associate { it.absolutePath to FileStatus.Waiting as FileStatus }

            currentUploadId =
                UploadWorker.enqueueUpload(
                    context = context,
                    filePaths = filesToUpload.map { it.absolutePath },
                    author = settings.author,
                )
        }
    }

    suspend fun runFileCheck(filesToCheck: List<File>) {
        scanProgress = 0 to filesToCheck.size
        fileStatus = fileStatus + filesToCheck.associate { it.absolutePath to FileStatus.Scanning as FileStatus }

        val result =
            fileChecker.checkFiles(
                filePaths = filesToCheck.map { it.absolutePath },
                onProgress = { update ->
                    withContext(Dispatchers.Main) {
                        if (update.statuses.isNotEmpty()) {
                            fileStatus = fileStatus + update.statuses
                        }
                        scanProgress = update.processedCount to update.totalFiles
                    }
                },
            )

        result.fold(
            onSuccess = { checkResult ->
                fileStatus = fileStatus + checkResult.statuses
            },
            onFailure = { error ->
                Log.e("MainActivity", "File check failed", error)
                if (currentErrorDialog == null) {
                    currentErrorDialog =
                        ErrorDialogState(
                            title = "File Scanning Error",
                            message = "Some files could not be scanned: ${error.message}",
                        )
                }
                filesToCheck.forEach { file ->
                    if (fileStatus[file.absolutePath] is FileStatus.Scanning) {
                        fileStatus = fileStatus + (file.absolutePath to FileStatus.New)
                    }
                }
            },
        )
        scanProgress = null
    }

    fun checkUnscannedFiles() {
        if (!settings.isValid() || cameraFiles.isEmpty() || !isConnected) return
        if (checkFilesJob != null) return

        val filesToCheck = cameraFiles.filter { fileStatus[it.absolutePath] == null }
        if (filesToCheck.isEmpty()) return

        checkFilesJob =
            coroutineScope.launch {
                runFileCheck(filesToCheck)
                checkFilesJob = null
            }
    }

    // Function to load files.
    suspend fun loadAndScanFiles() {
        isLoadingFiles = true
        val sourceDir = getSourceDirectory(settings)
        cameraFiles = withContext(ioDispatcher) { getSourceFiles(sourceDir, settings.mediaOnly) }
        isLoadingFiles = false

        if (cameraFiles.isEmpty() &&
            sourceDir.exists() &&
            !settings.mediaOnly &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.R &&
            !Environment.isExternalStorageManager()
        ) {
            showStoragePermissionDialog = true
        }

        if (isConnected) {
            val filesToCheck = cameraFiles.filter { fileStatus[it.absolutePath] == null }
            if (filesToCheck.isNotEmpty()) {
                runFileCheck(filesToCheck)
            }
        }
    }

    fun loadFiles() {
        coroutineScope.launch { loadAndScanFiles() }
    }

    var directoryPickerCallback by remember { mutableStateOf<((String) -> Unit)?>(null) }
    val directoryPickerLauncher =
        rememberLauncherForActivityResult(
            ActivityResultContracts.OpenDocumentTree(),
        ) { uri ->
            if (uri != null) {
                if (uri.authority == "com.android.externalstorage.documents") {
                    val docId = android.provider.DocumentsContract.getTreeDocumentId(uri)
                    val parts = docId.split(":")
                    if (parts.size == 2 && parts[0] == "primary") {
                        val path = "${Environment.getExternalStorageDirectory().path}/${parts[1]}"
                        directoryPickerCallback?.invoke(path)
                    }
                }
            }
            directoryPickerCallback = null
        }

    val permissionLauncher =
        rememberLauncherForActivityResult(
            ActivityResultContracts.RequestMultiplePermissions(),
        ) { permissions ->
            hasPermission = permissions.values.all { it }
            if (hasPermission) {
                loadFiles()
            }
        }

    // Upload work observer effect.
    val uploadWorkInfos by workManager.getWorkInfosForUniqueWorkLiveData(UploadWorker.WORK_NAME).observeAsState()

    LaunchedEffect(uploadWorkInfos, currentUploadId) {
        // 1. Try to find the exact work info if we have an ID.
        // 2. Otherwise, find any active work (e.g. app restart).
        // 3. Fallback to the latest terminal work info if we were already uploading.
        val workInfo =
            uploadWorkInfos?.find { it.id == currentUploadId }
                ?: uploadWorkInfos?.lastOrNull {
                    it.state == WorkInfo.State.RUNNING || it.state == WorkInfo.State.ENQUEUED
                } ?: if (isUploading || isUploadInitiated) uploadWorkInfos?.lastOrNull() else null

        workInfo?.let { info ->
            // Update current upload ID if we found an active job but didn't have the ID yet.
            if (currentUploadId == null && (info.state == WorkInfo.State.RUNNING || info.state == WorkInfo.State.ENQUEUED)) {
                currentUploadId = info.id
            }

            // Only process terminal work info if it belongs to our current upload.
            val isStaleTerminalState =
                (info.state == WorkInfo.State.SUCCEEDED || info.state == WorkInfo.State.FAILED || info.state == WorkInfo.State.CANCELLED) &&
                    info.id != currentUploadId &&
                    !isUploading

            if (isStaleTerminalState) return@let

            when (info.state) {
                WorkInfo.State.ENQUEUED, WorkInfo.State.BLOCKED -> {
                    // Just wait, don't reset isUploadInitiated
                }
                WorkInfo.State.RUNNING -> {
                    isUploading = true

                    // Read status from file
                    val statusFilePath = info.progress.getString("status_file")
                    val uploadedBytesFromWorker = info.progress.getLong("uploaded_bytes", 0)
                    val totalBytesFromWorker = info.progress.getLong("total_bytes", 0)

                    if (statusFilePath != null) {
                        // Process status update in background
                        coroutineScope.launch(ioDispatcher) {
                            try {
                                val statusFile = File(statusFilePath)
                                if (statusFile.exists()) {
                                    val statusJson = JSONObject(statusFile.readText())

                                    // Build new status map
                                    val newFileStatus = mutableMapOf<String, FileStatus>()
                                    statusJson.keys().forEach { fileName ->
                                        val status = statusJson.getString(fileName)
                                        newFileStatus[fileName] =
                                            when (status) {
                                                "waiting" -> FileStatus.Waiting
                                                "uploading" -> FileStatus.Uploading
                                                "uploaded" -> FileStatus.Uploaded
                                                "skipped" -> FileStatus.Exists("")
                                                "committing" -> FileStatus.Committing
                                                else -> FileStatus.New
                                            }
                                    }

                                    withContext(Dispatchers.Main) {
                                        // Merge worker statuses into existing map (preserve non-upload file statuses).
                                        fileStatus = fileStatus + newFileStatus

                                        // Find current uploading file
                                        val uploadingPath = newFileStatus.entries.firstOrNull { it.value is FileStatus.Uploading }?.key
                                        val currentFileName = uploadingPath?.let { File(it).name }

                                        // Count completed files in this upload
                                        val completedFiles =
                                            newFileStatus.count {
                                                it.value is FileStatus.Uploaded ||
                                                    it.value is FileStatus.Exists ||
                                                    it.value is FileStatus.Committing
                                            }
                                        val totalFiles = newFileStatus.size

                                        // Update upload info
                                        currentUploadInfo =
                                            if (newFileStatus.any { it.value is FileStatus.Committing }) {
                                                UploadInfo(
                                                    currentFile = "Committing changes...",
                                                    currentIndex = completedFiles,
                                                    totalFiles = totalFiles,
                                                )
                                            } else if (currentFileName != null) {
                                                UploadInfo(
                                                    currentFile = currentFileName,
                                                    currentIndex = completedFiles,
                                                    totalFiles = totalFiles,
                                                )
                                            } else {
                                                UploadInfo(
                                                    currentFile = null,
                                                    currentIndex = completedFiles,
                                                    totalFiles = totalFiles,
                                                )
                                            }

                                        // Update uploaded bytes
                                        actualUploadedBytes = uploadedBytesFromWorker
                                    }
                                }
                            } catch (e: Exception) {
                                // Ignore file IO errors - file might be being written
                                Log.d("MainActivity", "Error reading status file: ${e.message}")
                            }
                        }
                    }
                }
                WorkInfo.State.SUCCEEDED -> {
                    isUploading = false
                    isUploadInitiated = false
                    currentUploadId = null
                    currentUploadPaths = emptySet()
                    currentUploadInfo = null
                    actualUploadedBytes = 0L

                    // Apply complete result from file
                    val resultFilePath = info.outputData.getString("result_file")
                    if (resultFilePath != null) {
                        try {
                            val resultFile = File(resultFilePath)
                            if (resultFile.exists()) {
                                val resultJson = JSONObject(resultFile.readText())
                                resultFile.delete() // Clean up the file

                                // Mark all files from result with their final status.
                                resultJson.keys().forEach { fileName ->
                                    val statusValue = resultJson.getString(fileName)
                                    val finalStatus =
                                        when (statusValue) {
                                            "committing", "uploaded" -> FileStatus.Done
                                            "skipped" -> FileStatus.Exists("")
                                            else -> null
                                        }
                                    if (finalStatus != null) {
                                        fileStatus = fileStatus + (fileName to finalStatus)
                                    }
                                }

                                val totalFiles = info.outputData.getInt("total_files", 0)
                                Log.d("MainActivity", "Upload completed for $totalFiles files")
                            }
                        } catch (e: Exception) {
                            Log.e("MainActivity", "Failed to read upload result file", e)
                            // Fallback: mark all uploading files as Done
                            fileStatus.forEach { (fileName, status) ->
                                if (status is FileStatus.Waiting ||
                                    status is FileStatus.Uploading ||
                                    status is FileStatus.Uploaded ||
                                    status is FileStatus.Committing
                                ) {
                                    fileStatus = fileStatus + (fileName to FileStatus.Done)
                                }
                            }
                        }
                    }
                    selectedFiles = emptySet()
                }
                WorkInfo.State.CANCELLED -> {
                    isUploading = false
                    isUploadInitiated = false
                    currentUploadId = null
                    currentUploadInfo = null
                    actualUploadedBytes = 0L
                    for (path in currentUploadPaths) {
                        val status = fileStatus[path]
                        if (status !is FileStatus.Done && status !is FileStatus.Exists) {
                            fileStatus = fileStatus + (path to FileStatus.Aborted)
                        }
                    }
                    currentUploadPaths = emptySet()
                }
                WorkInfo.State.FAILED -> {
                    isUploading = false
                    isUploadInitiated = false
                    currentUploadId = null
                    currentUploadInfo = null
                    actualUploadedBytes = 0L
                    val fullErrorMsg = info.outputData.getString("error") ?: "Upload failed"

                    // Only show error dialog if no other error is showing
                    if (currentErrorDialog == null) {
                        currentErrorDialog =
                            ErrorDialogState(
                                title = "Upload Failed",
                                message = fullErrorMsg,
                            )
                    }

                    for (path in currentUploadPaths) {
                        val status = fileStatus[path]
                        if (status !is FileStatus.Done && status !is FileStatus.Exists) {
                            fileStatus = fileStatus + (path to FileStatus.Failed("Error"))
                        }
                    }
                    currentUploadPaths = emptySet()
                }
                else -> {
                    isUploading = false
                    isUploadInitiated = false
                    currentUploadId = null
                    currentUploadPaths = emptySet()
                    currentUploadInfo = null
                }
            }
        }
    }

    LaunchedEffect(Unit) {
        // Give the bridge a writable directory for its credentials map.
        withContext(ioDispatcher) {
            try {
                goBridge.initBridge(context.filesDir.absolutePath)
            } catch (e: Exception) {
                Log.e("MainActivity", "Failed to init bridge: ${e.message}", e)
            }
        }
        if (settings.isValid()) {
            // Check if repo is already open (e.g. coming back to the app).
            val alreadyOpen =
                withContext(ioDispatcher) {
                    try {
                        goBridge.checkRepositoryOpen(settings.hostUrl)
                    } catch (e: Exception) {
                        false
                    }
                }
            if (alreadyOpen) {
                isConnected = true
            } else if (passphraseStore.hasStoredPassphrase(settings.repositoryID())) {
                // Passphrase stored — try biometric silently.
                openRepositoryIfNeeded()
            }
            // Otherwise: stay disconnected, show "Connect" banner.
        }

        val permissions =
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO)
            } else {
                arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
            }

        hasPermission =
            permissions.all {
                ContextCompat.checkSelfPermission(context, it) == PackageManager.PERMISSION_GRANTED
            }

        if (hasPermission && cameraFiles.isEmpty()) {
            loadAndScanFiles()
        } else if (!hasPermission) {
            permissionLauncher.launch(permissions)
        }
    }

    // When we become connected and files are loaded, scan them.
    LaunchedEffect(isConnected, cameraFiles) {
        checkUnscannedFiles()
    }

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = {
            Surface(
                modifier = Modifier.fillMaxWidth(),
                color = MaterialTheme.colorScheme.surface,
            ) {
                Column {
                    Spacer(modifier = Modifier.height(40.dp))
                    Row(
                        modifier =
                            Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 16.dp, vertical = 12.dp),
                        horizontalArrangement = Arrangement.SpaceBetween,
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        Text(
                            text = "Cling Sync",
                            style = MaterialTheme.typography.headlineSmall,
                            fontWeight = FontWeight.Bold,
                            color = MaterialTheme.colorScheme.onSurface,
                        )

                        val topBarDisabled = isUploading || isUploadInitiated
                        val iconTint =
                            if (topBarDisabled) {
                                MaterialTheme.colorScheme.onSurface.copy(alpha = 0.38f)
                            } else {
                                MaterialTheme.colorScheme.onSurfaceVariant
                            }

                        Row {
                            IconButton(
                                onClick = {
                                    showSearch = !showSearch
                                    if (!showSearch) searchQuery = "" else selectedFiles = emptySet()
                                },
                                enabled = !topBarDisabled,
                            ) {
                                Icon(
                                    if (showSearch) Icons.Default.Close else Icons.Default.Search,
                                    if (showSearch) "Close search" else "Search",
                                    Modifier.size(24.dp),
                                    iconTint,
                                )
                            }
                            IconButton(onClick = { loadFiles() }, enabled = !topBarDisabled) {
                                Icon(Icons.Default.Refresh, "Refresh", Modifier.size(24.dp), iconTint)
                            }
                            IconButton(onClick = { showSettingsDialog = true }, enabled = !topBarDisabled) {
                                Icon(Icons.Default.Settings, "Settings", Modifier.size(24.dp), iconTint)
                            }
                        }
                    }
                }
            }
        },
    ) { innerPadding ->
        Column(
            modifier =
                Modifier
                    .fillMaxSize()
                    .padding(innerPadding),
        ) {
            // Guard clause for permission.
            if (!hasPermission) {
                PermissionRequiredScreen()
                return@Column
            }

            // Guard clause for loading.
            if (isLoadingFiles) {
                Box(
                    modifier = Modifier.fillMaxSize(),
                    contentAlignment = Alignment.Center,
                ) {
                    Column(
                        horizontalAlignment = Alignment.CenterHorizontally,
                        verticalArrangement = Arrangement.Center,
                    ) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(48.dp),
                        )
                        Spacer(modifier = Modifier.height(16.dp))
                        Text(
                            text = "Searching files...",
                            style = MaterialTheme.typography.bodyLarge,
                        )
                    }
                }
                return@Column
            }

            // Guard clause for empty files.
            if (cameraFiles.isEmpty()) {
                EmptyFilesScreen()
                return@Column
            }

            // Search bar.
            if (showSearch) {
                androidx.compose.material3.TextField(
                    value = searchQuery,
                    onValueChange = {
                        searchQuery = it
                        selectedFiles = emptySet()
                    },
                    placeholder = { Text("Filter files...") },
                    singleLine = true,
                    leadingIcon = { Icon(Icons.Default.Search, "Search", Modifier.size(20.dp)) },
                    trailingIcon = {
                        if (searchQuery.isNotEmpty()) {
                            IconButton(onClick = { searchQuery = "" }) {
                                Icon(Icons.Default.Close, "Clear", Modifier.size(20.dp))
                            }
                        }
                    },
                    modifier =
                        Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 16.dp, vertical = 4.dp),
                )
            }

            // Filter files by search query.
            val displayedFiles =
                remember(cameraFiles, searchQuery, settings) {
                    if (searchQuery.isBlank()) {
                        cameraFiles
                    } else {
                        val query = searchQuery.lowercase()
                        val srcDir = getSourceDirectory(settings)
                        cameraFiles.filter { file ->
                            val folder = getFileFolder(file, srcDir)
                            val displayName =
                                if (folder != null) "$folder/${file.name}" else file.name
                            displayName.lowercase().contains(query)
                        }
                    }
                }

            // Scanning progress banner (hidden during upload).
            if (!isUploading && !isUploadInitiated) {
                scanProgress?.let { (scanned, total) ->
                    Surface(
                        color = MaterialTheme.colorScheme.surfaceContainerHigh,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Row(
                            modifier =
                                Modifier
                                    .fillMaxWidth()
                                    .padding(horizontal = 16.dp, vertical = 12.dp),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            CircularProgressIndicator(
                                modifier = Modifier.size(16.dp),
                                strokeWidth = 2.dp,
                            )
                            Spacer(modifier = Modifier.width(12.dp))
                            Text(
                                text = "Scanning $scanned/$total files",
                                style = MaterialTheme.typography.bodyMedium,
                                color = MaterialTheme.colorScheme.onSurface,
                            )
                        }
                    }
                }
            }

            // "Repository access needed" banner when not connected.
            if (!isConnected && !isConnecting && !isUploading && settings.isValid()) {
                Surface(
                    color = MaterialTheme.colorScheme.tertiaryContainer,
                    modifier = Modifier.fillMaxWidth(),
                ) {
                    Row(
                        modifier =
                            Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 16.dp, vertical = 12.dp),
                        verticalAlignment = Alignment.CenterVertically,
                        horizontalArrangement = Arrangement.SpaceBetween,
                    ) {
                        Text(
                            text = "Repository access needed",
                            style = MaterialTheme.typography.bodyMedium,
                            color = MaterialTheme.colorScheme.onTertiaryContainer,
                        )
                        Button(onClick = { openRepositoryIfNeeded() }) {
                            Text("Connect")
                        }
                    }
                }
            }

            // Main content with unified top bar.
            Box(modifier = Modifier.weight(1f)) {
                val sourceDir = getSourceDirectory(settings)

                FileList(
                    files = displayedFiles,
                    selectedFiles = selectedFiles,
                    fileStatus = fileStatus,
                    isUploading = isUploading || !isConnected,
                    sourceDir = sourceDir,
                    lazyListState = lazyListState,
                    topPadding = if (isConnected) 88.dp else 8.dp,
                    onSelectionChange = { file, checked ->
                        selectedFiles =
                            if (checked) {
                                selectedFiles + file
                            } else {
                                selectedFiles - file
                            }
                    },
                )

                // Hide top bar when not connected (banner is shown instead).
                if (isConnected) {
                    ScrollAwareTopBar(
                        lazyListState = lazyListState,
                        selectedFiles = selectedFiles,
                        isUploading = isUploading || isUploadInitiated,
                        isScanning = checkFilesJob != null,
                        uploadInfo = currentUploadInfo,
                        onUploadClick = {
                            startUpload(displayedFiles.filter { it in selectedFiles })
                        },
                        onSelectAllClick = {
                            selectedFiles =
                                displayedFiles.filter { file ->
                                    val status = fileStatus[file.absolutePath]
                                    status is FileStatus.New ||
                                        status is FileStatus.Failed ||
                                        status is FileStatus.Aborted ||
                                        status == null
                                }.toSet()
                        },
                        onAbortClick = {
                            workManager.cancelUniqueWork(UploadWorker.WORK_NAME)
                            isUploadInitiated = false
                        },
                        uploadedBytes = actualUploadedBytes,
                    )
                }
            }
        }

        fun showInvalidHostUrlDialog(message: String) {
            currentErrorDialog =
                ErrorDialogState(title = "Invalid Host URL", message = message)
        }

        // Dialogs.
        if (showSettingsDialog) {
            SettingsDialog(
                settings = settings,
                onSave = { newSettings ->
                    val urlError = validateHostUrl(newSettings.hostUrl)
                    if (urlError != null) {
                        showInvalidHostUrlDialog(urlError)
                        return@SettingsDialog
                    }
                    val oldRepositoryID = settings.repositoryID()
                    val repositoryChanged = oldRepositoryID != newSettings.repositoryID()
                    val sourceChanged =
                        settings.sourceDirectory != newSettings.sourceDirectory ||
                            settings.mediaOnly != newSettings.mediaOnly

                    settings = newSettings
                    settingsManager.saveSettings(newSettings)
                    showSettingsDialog = false

                    if (repositoryChanged) {
                        passphraseStore.delete(oldRepositoryID)
                        coroutineScope.launch {
                            try {
                                withContext(ioDispatcher) {
                                    goBridge.clearStoredS3Credentials(oldRepositoryID)
                                }
                            } catch (_: Exception) {
                                // Best-effort cleanup. Ignore.
                            }
                        }
                        fileStatus = emptyMap()
                        isConnected = false
                        selectedFiles = emptySet()
                        loadFiles()
                    } else if (sourceChanged) {
                        fileStatus = emptyMap()
                        selectedFiles = emptySet()
                        loadFiles()
                    }
                },
                onTestConnection = { testSettings ->
                    val urlError = validateHostUrl(testSettings.hostUrl)
                    if (urlError != null) {
                        showInvalidHostUrlDialog(urlError)
                        return@SettingsDialog
                    }
                    // Update settings in memory only. The user must click Save to persist.
                    settings = testSettings
                    openRepositoryIfNeeded()
                },
                onBrowseDirectory = { onResult ->
                    directoryPickerCallback = onResult
                    directoryPickerLauncher.launch(null)
                },
                onDismiss =
                    if (settings.isValid()) {
                        { showSettingsDialog = false }
                    } else {
                        null
                    },
            )
        }

        // Unified error dialog
        UnifiedErrorDialog(
            errorState = currentErrorDialog,
            onDismiss = {
                currentErrorDialog = null
            },
        )

        // Storage permission dialog.
        if (showStoragePermissionDialog) {
            androidx.compose.material3.AlertDialog(
                onDismissRequest = { showStoragePermissionDialog = false },
                title = { Text("Storage Permission Required") },
                text = {
                    Text(
                        "To access all file types, enable \"All files access\" for Cling Sync.",
                    )
                },
                confirmButton = {
                    Button(onClick = {
                        showStoragePermissionDialog = false
                        try {
                            context.startActivity(
                                android.content.Intent(
                                    android.provider.Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                                    android.net.Uri.parse("package:${context.packageName}"),
                                ),
                            )
                        } catch (_: Exception) {
                            context.startActivity(
                                android.content.Intent(
                                    android.provider.Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION,
                                ),
                            )
                        }
                    }) {
                        Text("Open Settings")
                    }
                },
                dismissButton = {
                    TextButton(onClick = { showStoragePermissionDialog = false }) {
                        Text("Cancel")
                    }
                },
            )
        }

        // Passphrase prompt dialog.
        passphraseCallback?.let { callback ->
            PassphrasePromptDialog(
                showKeychainOption = passphraseStore.canUseBiometric(),
                onConfirm = { result ->
                    passphraseCallback = null
                    callback(result)
                },
                onDismiss = {
                    passphraseCallback = null
                    pendingOnConnected.clear()
                },
            )
        }

        // S3 credentials prompt, shown when the bridge reports that no S3 key
        // is stored yet for the current host URL.
        s3CredentialsRequest?.let { request ->
            S3CredentialsPromptDialog(
                onConfirm = { result ->
                    s3CredentialsRequest = null
                    request.onConfirm(result)
                },
                onDismiss = {
                    s3CredentialsRequest = null
                    request.onCancel()
                },
            )
        }

        // Connecting overlay
        if (isConnecting) {
            Box(
                modifier =
                    Modifier
                        .fillMaxSize()
                        .background(Color.Black.copy(alpha = 0.5f)),
                contentAlignment = Alignment.Center,
            ) {
                Card(
                    modifier = Modifier.padding(32.dp),
                    elevation = CardDefaults.cardElevation(defaultElevation = 8.dp),
                ) {
                    Row(
                        modifier = Modifier.padding(24.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(24.dp),
                            strokeWidth = 2.dp,
                        )
                        Spacer(modifier = Modifier.width(16.dp))
                        Text(
                            text = "Connecting to server...",
                            style = MaterialTheme.typography.bodyLarge,
                        )
                    }
                }
            }
        }
    }
}

fun getSourceDirectory(settings: AppSettings): File = File(settings.sourceDirectory)

private val MEDIA_EXTENSIONS =
    setOf(
        "jpg", "jpeg", "png", "gif", "bmp", "webp", "heif", "heic",
        "mp4", "mkv", "avi", "mov", "3gp", "webm",
        "mp3", "m4a", "ogg", "wav", "flac", "aac",
    )

fun getSourceFiles(
    sourceDir: File,
    mediaOnly: Boolean = true,
): List<File> {
    if (!sourceDir.isDirectory) return emptyList()

    val files = mutableListOf<File>()

    fun walk(dir: File) {
        val entries = dir.list() ?: return
        for (name in entries) {
            if (name.startsWith(".")) continue
            val file = File(dir, name)
            if (file.isDirectory) {
                walk(file)
            } else if (!mediaOnly || name.substringAfterLast('.', "").lowercase() in MEDIA_EXTENSIONS) {
                files.add(file)
            }
        }
    }
    walk(sourceDir)

    // Read lastModified once per file for sorting (avoids repeated syscalls during sort).
    return files
        .map { it to it.lastModified() }
        .sortedByDescending { it.second }
        .map { it.first }
}

fun getFileFolder(
    file: File,
    sourceDir: File,
): String? {
    if (!file.absolutePath.startsWith(sourceDir.absolutePath)) return null
    val relative = file.relativeTo(sourceDir).path
    val parts = relative.split(File.separator)
    val folder = parts.dropLast(1).joinToString(File.separator.toString())
    return folder.ifEmpty { null }
}
