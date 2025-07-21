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
                    is FileStatus.Waiting, is FileStatus.Uploading, is FileStatus.Uploaded, is FileStatus.Committing -> {
                        CircularProgressIndicator(
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
                                    is FileStatus.Uploaded -> ""
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
                                    is FileStatus.Done, is FileStatus.Uploaded -> MaterialTheme.colorScheme.onSurfaceVariant
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
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var isLoadingFiles by remember { mutableStateOf(false) }
    val context = LocalContext.current
    val coroutineScope = rememberCoroutineScope()
    var currentUploadInfo by remember { mutableStateOf<UploadInfo?>(null) }
    var isUploading by remember { mutableStateOf(false) }
    var uploadError by remember { mutableStateOf<String?>(null) }
    val lazyListState = rememberLazyListState()

    // Calculate total size for selected files and uploaded size.
    val totalSizeMB =
        remember(selectedFiles) {
            selectedFiles.sumOf { it.length() } / (1024 * 1024)
        }
    val uploadedSizeMB =
        remember(selectedFiles, currentUploadInfo) {
            val info = currentUploadInfo
            if (info != null && info.totalFiles > 0) {
                // Estimate based on completed files
                val filesUploaded = (info.currentIndex - 1).coerceAtLeast(0)
                val avgFileSize =
                    if (selectedFiles.isNotEmpty()) {
                        selectedFiles.sumOf { it.length() } / selectedFiles.size
                    } else {
                        0L
                    }
                (filesUploaded * avgFileSize) / (1024 * 1024)
            } else {
                0L
            }
        }

    // Function to load files.
    fun loadFiles() {
        coroutineScope.launch {
            isLoadingFiles = true
            cameraFiles = withContext(Dispatchers.IO) { getCameraFiles() }
            isLoadingFiles = false

            // Start checking files if we have settings
            if (settings.isValid() && cameraFiles.isNotEmpty()) {
                // Only check files that haven't been scanned yet
                val filesToCheck =
                    cameraFiles.filter { file ->
                        fileStatus[file.name] == null
                    }

                if (filesToCheck.isNotEmpty()) {
                    Log.d("MainActivity", "Starting file check for ${filesToCheck.size} new files")

                    // Set files to scanning status
                    filesToCheck.forEach { file ->
                        fileStatus = fileStatus + (file.name to FileStatus.Scanning)
                    }

                    Log.d("MainActivity", "Set ${filesToCheck.size} files to Scanning status")

                    // Start the check worker
                    CheckFilesWorker.enqueueCheck(
                        context = context,
                        filePaths = filesToCheck.map { it.absolutePath },
                        hostUrl = settings.hostUrl,
                        password = settings.password,
                    )

                    Log.d("MainActivity", "Enqueued CheckFilesWorker")
                }
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

    // Check files work observer effect.
    val checkWorkInfos by workManager.getWorkInfosForUniqueWorkLiveData(CheckFilesWorker.WORK_NAME).observeAsState()

    LaunchedEffect(uploadWorkInfos) {
        val workInfo =
            uploadWorkInfos?.lastOrNull {
                it.state == WorkInfo.State.RUNNING || it.state == WorkInfo.State.ENQUEUED
            } ?: uploadWorkInfos?.lastOrNull()

        workInfo?.let { info ->
            // Only process recent work (ignore old failed work from previous sessions).
            if (info.state == WorkInfo.State.FAILED && uploadError == null && !isUploading) {
                // Skip showing old errors on app start.
                return@let
            }
            when (info.state) {
                WorkInfo.State.RUNNING -> {
                    isUploading = true

                    // Process complete file statuses
                    val fileStatusesJson = info.progress.getString("file_statuses")
                    val totalFiles = info.progress.getInt("total_files", selectedFiles.size)
                    val currentIndex = info.progress.getInt("current_index", 0)
                    val status = info.progress.getString("status")
                    val currentFile = info.progress.getString("current_file")

                    // Update file statuses from JSON
                    if (fileStatusesJson != null) {
                        try {
                            val statusesObj = JSONObject(fileStatusesJson)
                            statusesObj.keys().forEach { fileName ->
                                val statusValue = statusesObj.getString(fileName)
                                when (statusValue) {
                                    "waiting" -> fileStatus = fileStatus + (fileName to FileStatus.Waiting)
                                    "uploading" -> fileStatus = fileStatus + (fileName to FileStatus.Uploading)
                                    "uploaded" -> fileStatus = fileStatus + (fileName to FileStatus.Uploaded)
                                    "committing" -> fileStatus = fileStatus + (fileName to FileStatus.Committing)
                                }
                            }
                        } catch (e: Exception) {
                            Log.e("MainActivity", "Failed to parse upload file statuses", e)
                        }
                    }

                    var currentFileSize: Long? = null
                    if (currentFile != null) {
                        val file = cameraFiles.find { it.name == currentFile }
                        currentFileSize = file?.length()?.div(1024)
                    }

                    currentUploadInfo =
                        UploadInfo(
                            currentFile = if (status == "committing") "Committing changes..." else currentFile,
                            fileSize = currentFileSize,
                            currentIndex = currentIndex,
                            totalFiles = totalFiles,
                        )
                }
                WorkInfo.State.SUCCEEDED -> {
                    isUploading = false
                    currentUploadInfo = null
                    // Only mark files that were being uploaded as Done
                    fileStatus.forEach { (fileName, status) ->
                        if (status is FileStatus.Waiting ||
                            status is FileStatus.Uploading ||
                            status is FileStatus.Uploaded ||
                            status is FileStatus.Committing
                        ) {
                            fileStatus = fileStatus + (fileName to FileStatus.Done)
                        }
                    }
                    selectedFiles = emptySet()
                }
                WorkInfo.State.CANCELLED -> {
                    isUploading = false
                    currentUploadInfo = null
                    fileStatus.forEach { (fileName, status) ->
                        if (status !is FileStatus.Done && status !is FileStatus.Failed && status !is FileStatus.Aborted) {
                            fileStatus = fileStatus + (fileName to FileStatus.Aborted)
                        }
                    }
                }
                WorkInfo.State.FAILED -> {
                    isUploading = false
                    currentUploadInfo = null
                    val fullErrorMsg = info.outputData.getString("error") ?: "Upload failed"
                    uploadError = fullErrorMsg

                    fileStatus.forEach { (fileName, status) ->
                        if (status !is FileStatus.Done && status !is FileStatus.Failed && status !is FileStatus.Aborted) {
                            fileStatus = fileStatus + (fileName to FileStatus.Failed("Error"))
                        }
                    }
                }
                else -> {
                    isUploading = false
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
                // Only check files that are still in Scanning status
                val filesToCheck =
                    cameraFiles.filter { file ->
                        fileStatus[file.name] is FileStatus.Scanning
                    }

                if (filesToCheck.isNotEmpty()) {
                    Log.d("MainActivity", "Checking ${filesToCheck.size} files still in Scanning status after upload")

                    // Start the check worker
                    CheckFilesWorker.enqueueCheck(
                        context = context,
                        filePaths = filesToCheck.map { it.absolutePath },
                        hostUrl = settings.hostUrl,
                        password = settings.password,
                    )
                }
            }
        }
    }

    // Observer for check files work - properly observe ALL updates
    LaunchedEffect(checkWorkInfos) {
        val workInfo = checkWorkInfos?.lastOrNull()

        workInfo?.let { info ->
            Log.d("MainActivity", "Check work state: ${info.state}")

            // Process progress updates - now contains all file statuses
            val fileStatusesJson = info.progress.getString("file_statuses")
            val processedCount = info.progress.getInt("processed_count", 0)
            val totalFiles = info.progress.getInt("total_files", 0)

            if (fileStatusesJson != null) {
                try {
                    val statusesObj = JSONObject(fileStatusesJson)

                    // Update all file statuses at once
                    statusesObj.keys().forEach { fileName ->
                        val statusAndPath = statusesObj.getString(fileName)
                        val parts = statusAndPath.split(":", limit = 2)
                        val statusType = parts[0]
                        val repoPath = if (parts.size > 1) parts[1] else ""

                        when (statusType) {
                            "exists" -> {
                                fileStatus = fileStatus + (fileName to FileStatus.Exists(repoPath))
                            }
                            "new" -> {
                                fileStatus = fileStatus + (fileName to FileStatus.New)
                            }
                            "not_found" -> {
                                // File doesn't exist, remove from status
                                fileStatus = fileStatus - fileName
                            }
                        }
                    }

                    Log.d("MainActivity", "Updated statuses for $processedCount/$totalFiles files")
                } catch (e: Exception) {
                    Log.e("MainActivity", "Failed to parse file statuses", e)
                }
            }

            // Handle state changes
            when (info.state) {
                WorkInfo.State.SUCCEEDED -> {
                    // Check completed - any files still in Scanning state should be marked as New
                    Log.d("MainActivity", "Check work succeeded")
                    fileStatus.forEach { (fileName, status) ->
                        if (status is FileStatus.Scanning) {
                            Log.w("MainActivity", "File $fileName still in Scanning state after completion, marking as New")
                            fileStatus = fileStatus + (fileName to FileStatus.New)
                        }
                    }
                }
                WorkInfo.State.FAILED -> {
                    // Check failed - mark all scanning files as new
                    Log.e("MainActivity", "Check work failed")
                    fileStatus.forEach { (fileName, status) ->
                        if (status is FileStatus.Scanning) {
                            fileStatus = fileStatus + (fileName to FileStatus.New)
                        }
                    }
                }
                else -> {
                    // Other states
                }
            }
        }
    }

    LaunchedEffect(Unit) {
        if (settings.isValid()) {
            try {
                goBridge.ensureOpen(settings.hostUrl, settings.password)
                Log.d("ClingSync", "Connected to repository")
            } catch (e: Exception) {
                Log.e("ClingSync", "Failed to open repository", e)
                errorMessage = "Failed to connect to repository: ${e.message}"
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

                            IconButton(onClick = { showSettingsDialog = true }) {
                                Icon(
                                    Icons.Default.Settings,
                                    contentDescription = "Settings",
                                    tint = MaterialTheme.colorScheme.onSurfaceVariant,
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
                    isUploading = isUploading,
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
                        val filePaths = selectedFiles.map { it.absolutePath }
                        Log.d("ClingSync", "Scheduling upload for files: $filePaths")

                        // Cancel any ongoing file checking
                        workManager.cancelUniqueWork(CheckFilesWorker.WORK_NAME)

                        selectedFiles.forEach { file ->
                            fileStatus = fileStatus + (file.name to FileStatus.Waiting)
                        }

                        UploadWorker.enqueueUpload(
                            context = context,
                            filePaths = filePaths,
                            repoPathPrefix = settings.repoPathPrefix,
                            author = "Android User",
                            message = "Backup ${selectedFiles.size} file${if (selectedFiles.size == 1) "" else "s"} from camera",
                            hostUrl = settings.hostUrl,
                            password = settings.password,
                        )
                    },
                    onAbortClick = {
                        workManager.cancelUniqueWork(UploadWorker.WORK_NAME)
                    },
                    isSelectAllEnabled = !isUploading,
                    totalSizeMB = totalSizeMB,
                    uploadedSizeMB = uploadedSizeMB,
                )
            }
        }

        // Dialogs.
        if (showSettingsDialog) {
            SettingsDialog(
                settings = settings,
                onSave = { newSettings ->
                    try {
                        goBridge.ensureOpen(newSettings.hostUrl, newSettings.password)
                        settings = newSettings
                        settingsManager.saveSettings(newSettings)
                        showSettingsDialog = false
                        Log.d("ClingSync", "Connected to repository via settings")
                    } catch (e: Exception) {
                        Log.e("ClingSync", "Failed to open repository with new settings", e)
                        errorMessage = "Failed to connect to repository: ${e.message}"
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

        errorMessage?.let { message ->
            ErrorDialog(
                title = "Connection Error",
                message = message,
                onDismiss = {
                    errorMessage = null
                    showSettingsDialog = true
                },
            )
        }

        uploadError?.let { error ->
            ErrorDialog(
                title = "Upload Failed",
                message = error,
                onDismiss = {
                    uploadError = null
                },
            )
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
