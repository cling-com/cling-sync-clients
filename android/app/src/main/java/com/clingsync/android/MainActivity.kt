package com.clingsync.android

import android.Manifest
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.util.Log
import androidx.activity.ComponentActivity
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
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
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
import androidx.compose.ui.tooling.preview.Preview
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.work.WorkInfo
import androidx.work.WorkManager
import com.clingsync.android.ui.ScrollAwareTopBar
import com.clingsync.android.ui.formatFileSize
import com.clingsync.android.ui.theme.ClingSyncTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File

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
    val fileSize: Long? = null,
    val currentIndex: Int = 0,
    val totalFiles: Int = 0,
)

class MainActivity : ComponentActivity() {
    private val goBridge = GoBridgeProvider.getInstance()
    private lateinit var settingsManager: SettingsManager

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // Switch from splash screen theme to normal theme.
        setTheme(R.style.Theme_ClingSync)

        settingsManager = SettingsManager(this)

        WindowCompat.setDecorFitsSystemWindows(window, false)

        setContent {
            ClingSyncTheme {
                MainScreen(
                    goBridge = goBridge,
                    settingsManager = settingsManager,
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
                        Text(
                            text = " • ",
                            style = MaterialTheme.typography.bodySmall,
                            color = MaterialTheme.colorScheme.onSurfaceVariant,
                        )
                        Text(
                            text =
                                when (status) {
                                    is FileStatus.Scanning -> "Scanning..."
                                    is FileStatus.New -> "New"
                                    is FileStatus.Exists -> ""
                                    is FileStatus.Waiting -> "Waiting..."
                                    is FileStatus.Uploading -> "Sending..."
                                    is FileStatus.Uploaded -> "Processing..."
                                    is FileStatus.Committing -> "Committing..."
                                    is FileStatus.Done -> ""
                                    is FileStatus.Aborted -> "Aborted"
                                    is FileStatus.Failed -> "Failed: ${status.error}"
                                },
                            style = MaterialTheme.typography.bodySmall,
                            color =
                                when (status) {
                                    is FileStatus.Failed -> MaterialTheme.colorScheme.error
                                    is FileStatus.Exists -> MaterialTheme.colorScheme.onSurfaceVariant
                                    is FileStatus.New -> MaterialTheme.colorScheme.primary
                                    is FileStatus.Done -> MaterialTheme.colorScheme.onSurfaceVariant
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

@Composable
fun FileList(
    files: List<File>,
    selectedFiles: Set<File>,
    fileStatus: Map<String, FileStatus>,
    isUploading: Boolean,
    onSelectionChange: (File, Boolean) -> Unit,
    lazyListState: LazyListState = rememberLazyListState(),
) {
    LazyColumn(
        state = lazyListState,
        modifier =
            Modifier
                .fillMaxSize()
                .padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
        contentPadding = PaddingValues(top = 88.dp, bottom = 16.dp),
    ) {
        items(files) { file ->
            val isSelected = selectedFiles.contains(file)
            FileListItem(
                file = file,
                isSelected = isSelected,
                uploadStatus = fileStatus[file.name],
                isUploading = isUploading,
                onSelectionChange = { checked -> onSelectionChange(file, checked) },
            )
        }
    }
}

@Composable
fun MainScreen(
    goBridge: IGoBridge,
    settingsManager: SettingsManager,
    workManager: WorkManager = WorkManager.getInstance(LocalContext.current),
) {
    var cameraFiles by remember { mutableStateOf<List<File>>(emptyList()) }
    var selectedFiles by remember { mutableStateOf<Set<File>>(emptySet()) }
    var fileStatus by remember { mutableStateOf<Map<String, FileStatus>>(emptyMap()) }
    var hasPermission by remember { mutableStateOf(false) }
    var settings by remember { mutableStateOf(settingsManager.getSettings()) }
    var showSettingsDialog by remember { mutableStateOf(!settings.isValid()) }
    var currentErrorDialog by remember { mutableStateOf<ErrorDialogState?>(null) }
    var isLoadingFiles by remember { mutableStateOf(false) }
    val context = LocalContext.current
    val coroutineScope = rememberCoroutineScope()
    var currentUploadInfo by remember { mutableStateOf<UploadInfo?>(null) }
    var isUploading by remember { mutableStateOf(false) }
    var isUploadInitiated by remember { mutableStateOf(false) }
    val lazyListState = rememberLazyListState()
    var checkFilesJob by remember { mutableStateOf<Job?>(null) }
    val fileChecker = remember { FileChecker() }
    var isConnecting by remember { mutableStateOf(false) }
    var isConnected by remember { mutableStateOf(false) }
    var actualUploadedBytes by remember { mutableStateOf(0L) }

    // Track uploaded bytes
    val uploadedSizeMB =
        remember(actualUploadedBytes) {
            actualUploadedBytes / (1024 * 1024)
        }

    // Function to check files that haven't been scanned
    fun checkUnscannedFiles() {
        if (!settings.isValid() || cameraFiles.isEmpty() || !isConnected) return

        val filesToCheck =
            cameraFiles.filter { file ->
                val status = fileStatus[file.name]
                // Check files that haven't been scanned or weren't successfully uploaded
                status == null ||
                    status is FileStatus.Scanning ||
                    status is FileStatus.New ||
                    status is FileStatus.Failed ||
                    status is FileStatus.Aborted
            }

        if (filesToCheck.isEmpty()) return

        Log.d("MainActivity", "Starting file check for ${filesToCheck.size} files")

        // Cancel any existing check job first
        checkFilesJob?.cancel()

        // Set files to scanning status
        filesToCheck.forEach { file ->
            fileStatus = fileStatus + (file.name to FileStatus.Scanning)
        }

        // Start a single file check coroutine
        checkFilesJob =
            coroutineScope.launch {
                // First collect updates in a separate coroutine
                val updateJob =
                    launch {
                        fileChecker.updates.collectLatest { update ->
                            fileStatus = fileStatus + (update.fileName to update.status)
                        }
                    }

                // Run the check
                val result =
                    fileChecker.checkFiles(
                        filePaths = filesToCheck.map { it.absolutePath },
                        hostUrl = settings.hostUrl,
                        password = settings.password,
                        repoPathPrefix = settings.repoPathPrefix,
                    )

                // Cancel update collection
                updateJob.cancel()

                // Handle result
                result.fold(
                    onSuccess = { checkResult ->
                        // Apply final result
                        checkResult.statuses.forEach { (fileName, status) ->
                            fileStatus = fileStatus + (fileName to status)
                        }
                        Log.d("MainActivity", "File check completed: ${checkResult.processedCount}/${checkResult.totalFiles}")
                    },
                    onFailure = { error ->
                        Log.e("MainActivity", "File check failed", error)
                        // Only show error dialog if no other error is showing
                        if (currentErrorDialog == null) {
                            currentErrorDialog =
                                ErrorDialogState(
                                    title = "File Scanning Error",
                                    message = "Some files could not be scanned: ${error.message}",
                                )
                        }
                        // Reset scanning files to new
                        filesToCheck.forEach { file ->
                            if (fileStatus[file.name] is FileStatus.Scanning) {
                                fileStatus = fileStatus + (file.name to FileStatus.New)
                            }
                        }
                    },
                )
            }
    }

    // Function to load files.
    fun loadFiles() {
        coroutineScope.launch {
            isLoadingFiles = true
            cameraFiles = withContext(Dispatchers.IO) { getCameraFiles() }
            isLoadingFiles = false

            // Only start checking files if we're connected
            if (isConnected) {
                checkUnscannedFiles()
            }
        }
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

    LaunchedEffect(uploadWorkInfos) {
        val workInfo =
            uploadWorkInfos?.lastOrNull {
                it.state == WorkInfo.State.RUNNING || it.state == WorkInfo.State.ENQUEUED
            } ?: uploadWorkInfos?.lastOrNull()

        workInfo?.let { info ->
            // Only process recent work (ignore old failed work from previous sessions).
            if (info.state == WorkInfo.State.FAILED && !isUploading) {
                // Skip showing old errors on app start.
                return@let
            }
            when (info.state) {
                WorkInfo.State.RUNNING -> {
                    isUploading = true

                    // Read status from file
                    val statusFilePath = info.progress.getString("status_file")
                    val uploadedBytesFromWorker = info.progress.getLong("uploaded_bytes", 0)
                    val totalBytesFromWorker = info.progress.getLong("total_bytes", 0)

                    if (statusFilePath != null) {
                        // Process status update in background
                        coroutineScope.launch(Dispatchers.IO) {
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
                                        // Update UI state on main thread
                                        fileStatus = newFileStatus

                                        // Find current uploading file
                                        val uploadingFiles = fileStatus.filter { it.value is FileStatus.Uploading }
                                        val currentFileName = uploadingFiles.keys.firstOrNull()

                                        // Count completed files
                                        val completedFiles =
                                            fileStatus.count {
                                                it.value is FileStatus.Uploaded ||
                                                    it.value is FileStatus.Exists ||
                                                    it.value is FileStatus.Committing
                                            }
                                        val totalFiles = fileStatus.size

                                        // Update upload info
                                        currentUploadInfo =
                                            if (fileStatus.any { it.value is FileStatus.Committing }) {
                                                UploadInfo(
                                                    currentFile = "Committing changes...",
                                                    fileSize = null,
                                                    currentIndex = completedFiles,
                                                    totalFiles = totalFiles,
                                                )
                                            } else if (currentFileName != null) {
                                                val file = cameraFiles.find { it.name == currentFileName }
                                                UploadInfo(
                                                    currentFile = currentFileName,
                                                    fileSize = file?.length()?.div(1024),
                                                    currentIndex = completedFiles,
                                                    totalFiles = totalFiles,
                                                )
                                            } else {
                                                UploadInfo(
                                                    currentFile = null,
                                                    fileSize = null,
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

                                // Mark all files from result as Done
                                resultJson.keys().forEach { fileName ->
                                    val statusValue = resultJson.getString(fileName)
                                    if (statusValue == "committing") {
                                        fileStatus = fileStatus + (fileName to FileStatus.Done)
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
                    currentUploadInfo = null
                    actualUploadedBytes = 0L
                    fileStatus.forEach { (fileName, status) ->
                        if (status !is FileStatus.Done && status !is FileStatus.Failed && status !is FileStatus.Aborted) {
                            fileStatus = fileStatus + (fileName to FileStatus.Aborted)
                        }
                    }
                }
                WorkInfo.State.FAILED -> {
                    isUploading = false
                    isUploadInitiated = false
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

                    fileStatus.forEach { (fileName, status) ->
                        if (status !is FileStatus.Done && status !is FileStatus.Failed && status !is FileStatus.Aborted) {
                            fileStatus = fileStatus + (fileName to FileStatus.Failed("Error"))
                        }
                    }
                }
                else -> {
                    isUploading = false
                    isUploadInitiated = false
                    currentUploadInfo = null
                }
            }

            // After upload is done (succeeded, failed, or cancelled), check files still in Scanning status
            if ((
                    info.state == WorkInfo.State.SUCCEEDED ||
                        info.state == WorkInfo.State.FAILED ||
                        info.state == WorkInfo.State.CANCELLED
                ) &&
                settings.isValid() && cameraFiles.isNotEmpty()
            ) {
                // Check files that are still in Scanning status
                checkUnscannedFiles()
            }
        }
    }

    LaunchedEffect(Unit) {
        if (settings.isValid()) {
            withContext(Dispatchers.IO) {
                try {
                    goBridge.ensureOpen(settings.hostUrl, settings.password, settings.repoPathPrefix)
                    Log.d("ClingSync", "Connected to repository")
                    withContext(Dispatchers.Main) {
                        isConnected = true
                    }
                } catch (e: Exception) {
                    Log.e("ClingSync", "Failed to open repository", e)
                    withContext(Dispatchers.Main) {
                        isConnected = false
                        // Only show error dialog if no other error is showing
                        if (currentErrorDialog == null) {
                            currentErrorDialog =
                                ErrorDialogState(
                                    title = "Connection Error",
                                    message = "Failed to connect to repository: ${e.message}",
                                )
                        }
                    }
                }
            }
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
            loadFiles()
        } else if (!hasPermission) {
            permissionLauncher.launch(permissions)
        }
    }

    // Watch for connection status changes
    LaunchedEffect(isConnected) {
        if (isConnected && cameraFiles.isNotEmpty()) {
            // When we become connected, check any unscanned files
            checkUnscannedFiles()
        }
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

                        Row {
                            IconButton(onClick = { loadFiles() }) {
                                Icon(
                                    Icons.Default.Refresh,
                                    contentDescription = "Refresh",
                                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
                                    modifier = Modifier.size(24.dp),
                                )
                            }

                            IconButton(
                                onClick = { showSettingsDialog = true },
                                enabled = !(isUploading || isUploadInitiated),
                            ) {
                                Icon(
                                    Icons.Default.Settings,
                                    contentDescription = "Settings",
                                    tint =
                                        if (isUploading || isUploadInitiated) {
                                            MaterialTheme.colorScheme.onSurface.copy(alpha = 0.38f)
                                        } else {
                                            MaterialTheme.colorScheme.onSurfaceVariant
                                        },
                                    modifier = Modifier.size(24.dp),
                                )
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

            // Calculate selectable files and select all state.
            val selectableFiles =
                remember(cameraFiles, fileStatus) {
                    cameraFiles.filter { file ->
                        val status = fileStatus[file.name]
                        status is FileStatus.New ||
                            status is FileStatus.Failed ||
                            status is FileStatus.Aborted ||
                            status == null
                    }
                }

            val selectAllChecked =
                remember(selectableFiles, selectedFiles) {
                    selectableFiles.isNotEmpty() && selectedFiles.containsAll(selectableFiles)
                }

            // Main content with unified top bar.
            Box(modifier = Modifier.weight(1f)) {
                FileList(
                    files = cameraFiles,
                    selectedFiles = selectedFiles,
                    fileStatus = fileStatus,
                    isUploading = isUploading,
                    lazyListState = lazyListState,
                    onSelectionChange = { file, checked ->
                        selectedFiles =
                            if (checked) {
                                selectedFiles + file
                            } else {
                                selectedFiles - file
                            }
                    },
                )

                // Unified top bar with scroll behavior.
                ScrollAwareTopBar(
                    lazyListState = lazyListState,
                    selectedFiles = selectedFiles,
                    isUploading = isUploading || isUploadInitiated,
                    uploadInfo = currentUploadInfo,
                    selectAllChecked = selectAllChecked,
                    onSelectAllChange = { checked ->
                        selectedFiles =
                            if (checked) {
                                selectableFiles.toSet()
                            } else {
                                emptySet()
                            }
                    },
                    onUploadClick = {
                        // Cancel any file checking in progress
                        checkFilesJob?.cancel()

                        // Preserve the order from cameraFiles (newest first)
                        val filePaths = cameraFiles.filter { it in selectedFiles }.map { it.absolutePath }
                        Log.d("ClingSync", "Scheduling upload for files: $filePaths")

                        // Immediately switch to upload mode
                        isUploadInitiated = true
                        currentUploadInfo =
                            UploadInfo(
                                // Will show "Preparing..."
                                currentFile = null,
                                fileSize = null,
                                currentIndex = 0,
                                totalFiles = selectedFiles.size,
                            )

                        selectedFiles.forEach { file ->
                            fileStatus = fileStatus + (file.name to FileStatus.Waiting)
                        }

                        UploadWorker.enqueueUpload(
                            context = context,
                            filePaths = filePaths,
                            repoPathPrefix = settings.repoPathPrefix,
                            author = settings.author,
                            message =
                                "Backup ${selectedFiles.size} file${if (selectedFiles.size == 1) "" else "s"}" +
                                    " from ${Build.MANUFACTURER} ${Build.MODEL}",
                            hostUrl = settings.hostUrl,
                            password = settings.password,
                        )
                    },
                    onUploadAllClick = {
                        // Cancel any file checking in progress
                        checkFilesJob?.cancel()

                        // Upload all camera files
                        val allFiles = cameraFiles
                        Log.d(
                            "ClingSync",
                            "Upload All clicked - ${allFiles.size} files, " +
                                "isUploadInitiated=$isUploadInitiated, isUploading=$isUploading",
                        )

                        // Clear any selected files to ensure clean state
                        selectedFiles = emptySet()

                        // Immediately switch to upload mode
                        isUploadInitiated = true
                        currentUploadInfo =
                            UploadInfo(
                                currentFile = null,
                                fileSize = null,
                                currentIndex = 0,
                                totalFiles = allFiles.size,
                            )

                        // Mark all files as waiting
                        allFiles.forEach { file ->
                            fileStatus = fileStatus + (file.name to FileStatus.Waiting)
                        }

                        UploadWorker.enqueueUpload(
                            context = context,
                            // allFiles is already in correct order
                            filePaths = allFiles.map { it.absolutePath },
                            repoPathPrefix = settings.repoPathPrefix,
                            author = settings.author,
                            message =
                                "Backup ${allFiles.size} file${if (allFiles.size == 1) "" else "s"}" +
                                    " from ${Build.MANUFACTURER} ${Build.MODEL}",
                            hostUrl = settings.hostUrl,
                            password = settings.password,
                        )
                    },
                    onAbortClick = {
                        workManager.cancelUniqueWork(UploadWorker.WORK_NAME)
                        isUploadInitiated = false
                    },
                    isSelectAllEnabled = !(isUploading || isUploadInitiated),
                    uploadedSizeMB = uploadedSizeMB,
                )
            }
        }

        // Dialogs.
        if (showSettingsDialog) {
            SettingsDialog(
                settings = settings,
                onSave = { newSettings ->
                    isConnecting = true

                    coroutineScope.launch {
                        // Dismiss dialog and save settings immediately
                        showSettingsDialog = false

                        // Check if host URL changed
                        val hostUrlChanged = settings.hostUrl != newSettings.hostUrl

                        // Always save settings
                        settings = newSettings
                        settingsManager.saveSettings(newSettings)

                        if (hostUrlChanged) {
                            // Clear all file statuses when host URL changes
                            fileStatus = emptyMap()
                            Log.d("MainActivity", "Host URL changed, clearing file statuses")
                        }

                        try {
                            withContext(Dispatchers.IO) {
                                goBridge.ensureOpen(newSettings.hostUrl, newSettings.password, newSettings.repoPathPrefix)
                            }

                            isConnecting = false
                            isConnected = true
                            Log.d("ClingSync", "Connected to repository via settings")

                            // File checking will be triggered by the LaunchedEffect watching isConnected
                        } catch (e: Exception) {
                            Log.e("ClingSync", "Failed to open repository with new settings", e)
                            isConnecting = false
                            isConnected = false
                            // Reopen settings dialog on connection failure
                            showSettingsDialog = true
                            // Only show error dialog if no other error is showing
                            if (currentErrorDialog == null) {
                                currentErrorDialog =
                                    ErrorDialogState(
                                        title = "Connection Error",
                                        message = "Failed to connect to repository: ${e.message}",
                                    )
                            }
                        }
                    }
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

fun getCameraFiles(): List<File> {
    val cameraDir =
        File(
            Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DCIM),
            "Camera",
        )

    return if (cameraDir.exists() && cameraDir.isDirectory) {
        cameraDir.listFiles()?.filter { file ->
            file.isFile && !file.name.startsWith(".") && file.canRead()
        }?.sortedByDescending { it.lastModified() } ?: emptyList()
    } else {
        emptyList()
    }
}

@Preview(showBackground = true)
@Composable
fun MainScreenPreview() {
    ClingSyncTheme {
        MainScreen(
            goBridge = GoBridgeProvider.getInstance(),
            settingsManager = SettingsManager(androidx.compose.ui.platform.LocalContext.current),
        )
    }
}
