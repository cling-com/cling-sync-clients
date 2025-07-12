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
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.selection.toggleable
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Refresh
import androidx.compose.material.icons.filled.Settings
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.LinearProgressIndicator
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
import com.clingsync.android.ui.theme.ClingSyncTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

sealed class UploadStatus {
    object Waiting : UploadStatus()

    object Uploading : UploadStatus()

    object Uploaded : UploadStatus()

    object Committing : UploadStatus()

    object Done : UploadStatus()

    object Aborted : UploadStatus()

    data class Failed(val error: String) : UploadStatus()
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
    uploadStatus: UploadStatus?,
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
            when (uploadStatus) {
                is UploadStatus.Waiting, is UploadStatus.Uploading, is UploadStatus.Uploaded, is UploadStatus.Committing -> {
                    CircularProgressIndicator(
                        modifier = Modifier.size(24.dp),
                        strokeWidth = 2.dp,
                    )
                }
                else -> {
                    Checkbox(
                        checked = isSelected,
                        onCheckedChange = onSelectionChange,
                        modifier = Modifier.testTag("checkbox_${file.name}"),
                        enabled =
                            (
                                uploadStatus == null || uploadStatus is UploadStatus.Aborted ||
                                    uploadStatus is UploadStatus.Failed || uploadStatus is UploadStatus.Done
                            ) && !isUploading,
                    )
                }
            }

            Spacer(modifier = Modifier.width(16.dp))

            Column(modifier = Modifier.weight(1f)) {
                Text(
                    text = file.name,
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.Medium,
                )
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.Start,
                ) {
                    Text(
                        text = "${file.length() / 1024} KB",
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
                                    is UploadStatus.Waiting -> "Waiting..."
                                    is UploadStatus.Uploading -> "Sending..."
                                    is UploadStatus.Uploaded -> "Processing..."
                                    is UploadStatus.Committing -> "Committing..."
                                    is UploadStatus.Done -> "Done"
                                    is UploadStatus.Aborted -> "Aborted"
                                    is UploadStatus.Failed -> "Failed: ${status.error}"
                                },
                            style = MaterialTheme.typography.bodySmall,
                            color =
                                when (status) {
                                    is UploadStatus.Failed -> MaterialTheme.colorScheme.error
                                    else -> MaterialTheme.colorScheme.primary
                                },
                            fontWeight = FontWeight.Medium,
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
    fileUploadStatus: Map<String, UploadStatus>,
    isUploading: Boolean,
    onSelectionChange: (File, Boolean) -> Unit,
) {
    LazyColumn(
        modifier =
            Modifier
                .fillMaxSize()
                .padding(horizontal = 16.dp),
        verticalArrangement = Arrangement.spacedBy(8.dp),
        contentPadding = PaddingValues(vertical = 16.dp),
    ) {
        items(files) { file ->
            val isSelected = selectedFiles.contains(file)
            FileListItem(
                file = file,
                isSelected = isSelected,
                uploadStatus = fileUploadStatus[file.name],
                isUploading = isUploading,
                onSelectionChange = { checked -> onSelectionChange(file, checked) },
            )
        }
    }
}

@Composable
fun StatusBar(
    isLoadingFiles: Boolean,
    isUploading: Boolean,
    currentUploadInfo: UploadInfo?,
    onAbort: () -> Unit,
) {
    // Guard clause - only show when there's status to report.
    if (!isLoadingFiles && !isUploading) return

    Surface(
        modifier = Modifier.fillMaxWidth().height(80.dp),
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        shadowElevation = 8.dp,
    ) {
        Box(
            modifier = Modifier.fillMaxWidth().height(80.dp),
            contentAlignment = Alignment.Center,
        ) {
            when {
                isLoadingFiles -> {
                    Row(
                        modifier =
                            Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 16.dp),
                        verticalAlignment = Alignment.CenterVertically,
                    ) {
                        CircularProgressIndicator(
                            modifier = Modifier.size(20.dp),
                            strokeWidth = 2.dp,
                        )
                        Spacer(modifier = Modifier.width(12.dp))
                        Text(
                            text = "Scanning Local Files...",
                            style = MaterialTheme.typography.bodyMedium,
                        )
                    }
                }
                isUploading && currentUploadInfo != null -> {
                    Column(
                        modifier =
                            Modifier
                                .fillMaxWidth()
                                .padding(horizontal = 16.dp),
                        verticalArrangement = Arrangement.Center,
                    ) {
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            Text(
                                text = currentUploadInfo.currentFile ?: "Preparing...",
                                style = MaterialTheme.typography.bodyMedium,
                                maxLines = 1,
                                modifier = Modifier.weight(1f, fill = false),
                            )
                            if (currentUploadInfo.fileSize != null) {
                                Text(
                                    text = " • ${currentUploadInfo.fileSize} KB",
                                    style = MaterialTheme.typography.bodySmall,
                                    color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.7f),
                                )
                            }
                            Spacer(modifier = Modifier.weight(1f))
                            TextButton(onClick = onAbort) {
                                Text(
                                    text = "Abort",
                                    color = MaterialTheme.colorScheme.error,
                                )
                            }
                        }
                        Row(
                            modifier = Modifier.fillMaxWidth(),
                            verticalAlignment = Alignment.CenterVertically,
                        ) {
                            LinearProgressIndicator(
                                progress = {
                                    if (currentUploadInfo.totalFiles > 0) {
                                        (currentUploadInfo.currentIndex - 1).toFloat() / currentUploadInfo.totalFiles
                                    } else {
                                        0f
                                    }
                                },
                                modifier =
                                    Modifier
                                        .weight(1f)
                                        .height(4.dp),
                            )
                            Spacer(modifier = Modifier.width(12.dp))
                            Text(
                                text = "${currentUploadInfo.currentIndex}/${currentUploadInfo.totalFiles}",
                                style = MaterialTheme.typography.bodySmall,
                                color = MaterialTheme.colorScheme.onSurface.copy(alpha = 0.7f),
                            )
                        }
                    }
                }
            }
        }
    }
}

@Composable
fun UploadButton(
    selectedFiles: Set<File>,
    isUploading: Boolean,
    onClick: () -> Unit,
) {
    // Guard clause - only show when files are selected and not uploading.
    if (selectedFiles.isEmpty() || isUploading) return

    Surface(
        modifier = Modifier.fillMaxWidth().height(80.dp),
        color = MaterialTheme.colorScheme.surfaceContainerLow,
        shadowElevation = 8.dp,
    ) {
        Box(
            modifier = Modifier.fillMaxWidth().height(80.dp),
            contentAlignment = Alignment.Center,
        ) {
            Button(
                onClick = onClick,
                modifier =
                    Modifier
                        .fillMaxWidth()
                        .padding(16.dp)
                        .height(48.dp)
                        .testTag("upload_button"),
            ) {
                Text(
                    text = "Upload ${selectedFiles.size} file${if (selectedFiles.size == 1) "" else "s"}",
                )
            }
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
    var fileUploadStatus by remember { mutableStateOf<Map<String, UploadStatus>>(emptyMap()) }
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

    // Function to load files.
    fun loadFiles() {
        coroutineScope.launch {
            isLoadingFiles = true
            cameraFiles = withContext(Dispatchers.IO) { getCameraFiles() }
            isLoadingFiles = false
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

    // Work observer effect.
    val workInfos by workManager.getWorkInfosForUniqueWorkLiveData(UploadWorker.WORK_NAME).observeAsState()
    LaunchedEffect(workInfos) {
        val workInfo =
            workInfos?.lastOrNull {
                it.state == WorkInfo.State.RUNNING || it.state == WorkInfo.State.ENQUEUED
            } ?: workInfos?.lastOrNull()

        workInfo?.let { info ->
            // Only process recent work (ignore old failed work from previous sessions).
            if (info.state == WorkInfo.State.FAILED && uploadError == null && !isUploading) {
                // Skip showing old errors on app start.
                return@let
            }
            when (info.state) {
                WorkInfo.State.RUNNING -> {
                    isUploading = true
                    val totalFiles = info.progress.getInt("total_files", selectedFiles.size)
                    val currentIndex = info.progress.getInt("current_index", 0)
                    val status = info.progress.getString("status")
                    val currentFile = info.progress.getString("current_file")

                    var currentFileSize: Long? = null
                    if (currentFile != null) {
                        val file = cameraFiles.find { it.name == currentFile }
                        currentFileSize = file?.length()?.div(1024)
                    }

                    currentUploadInfo =
                        UploadInfo(
                            currentFile = currentFile,
                            fileSize = currentFileSize,
                            currentIndex = currentIndex,
                            totalFiles = totalFiles,
                        )

                    when (status) {
                        "waiting" -> {
                            // Mark all selected files as waiting.
                            selectedFiles.forEach { file ->
                                fileUploadStatus = fileUploadStatus + (file.name to UploadStatus.Waiting)
                            }
                        }
                        "uploading" -> {
                            if (currentFile != null) {
                                // Mark current file as uploading.
                                fileUploadStatus = fileUploadStatus + (currentFile to UploadStatus.Uploading)

                                // Mark previous files as uploaded based on index.
                                var uploadedCount = 0
                                selectedFiles.forEach { file ->
                                    if (uploadedCount < currentIndex - 1) {
                                        val currentStatus = fileUploadStatus[file.name]
                                        if (currentStatus !is UploadStatus.Done &&
                                            currentStatus !is UploadStatus.Failed &&
                                            currentStatus !is UploadStatus.Uploaded
                                        ) {
                                            fileUploadStatus = fileUploadStatus + (file.name to UploadStatus.Uploaded)
                                        }
                                        uploadedCount++
                                    }
                                }
                            }
                        }
                        "committing" -> {
                            currentUploadInfo =
                                UploadInfo(
                                    currentFile = "Committing changes...",
                                    currentIndex = totalFiles,
                                    totalFiles = totalFiles,
                                )
                            // Mark all selected files as committing.
                            selectedFiles.forEach { file ->
                                fileUploadStatus = fileUploadStatus + (file.name to UploadStatus.Committing)
                            }
                        }
                    }
                }
                WorkInfo.State.SUCCEEDED -> {
                    isUploading = false
                    currentUploadInfo = null
                    fileUploadStatus.forEach { (fileName, status) ->
                        if (status !is UploadStatus.Done && status !is UploadStatus.Failed) {
                            fileUploadStatus = fileUploadStatus + (fileName to UploadStatus.Done)
                        }
                    }
                    selectedFiles = emptySet()
                }
                WorkInfo.State.CANCELLED -> {
                    isUploading = false
                    currentUploadInfo = null
                    fileUploadStatus.forEach { (fileName, status) ->
                        if (status !is UploadStatus.Done && status !is UploadStatus.Failed && status !is UploadStatus.Aborted) {
                            fileUploadStatus = fileUploadStatus + (fileName to UploadStatus.Aborted)
                        }
                    }
                }
                WorkInfo.State.FAILED -> {
                    isUploading = false
                    currentUploadInfo = null
                    val fullErrorMsg = info.outputData.getString("error") ?: "Upload failed"
                    uploadError = fullErrorMsg

                    fileUploadStatus.forEach { (fileName, status) ->
                        if (status !is UploadStatus.Done && status !is UploadStatus.Failed && status !is UploadStatus.Aborted) {
                            fileUploadStatus = fileUploadStatus + (fileName to UploadStatus.Failed("Error"))
                        }
                    }
                }
                else -> {
                    isUploading = false
                    currentUploadInfo = null
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
                Box(modifier = Modifier.weight(1f))
                StatusBar(isLoadingFiles, isUploading, currentUploadInfo, onAbort = {})
                return@Column
            }

            // Guard clause for empty files.
            if (cameraFiles.isEmpty()) {
                EmptyFilesScreen()
                return@Column
            }

            // Select all header.
            Surface(
                modifier = Modifier.fillMaxWidth(),
                color = MaterialTheme.colorScheme.surfaceContainerLow,
            ) {
                Row(
                    modifier =
                        Modifier
                            .fillMaxWidth()
                            .padding(horizontal = 32.dp, vertical = 16.dp),
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Checkbox(
                        checked = selectedFiles.size == cameraFiles.size && cameraFiles.isNotEmpty(),
                        modifier = Modifier.testTag("select_all"),
                        onCheckedChange = { checked ->
                            selectedFiles =
                                if (checked) {
                                    cameraFiles.toSet()
                                } else {
                                    emptySet()
                                }
                        },
                        enabled = !isUploading,
                    )
                    Spacer(modifier = Modifier.width(16.dp))
                    Text(
                        text = "Select All",
                        style = MaterialTheme.typography.bodyMedium,
                        fontWeight = FontWeight.Medium,
                    )
                    Spacer(modifier = Modifier.weight(1f))
                    Text(
                        text = "${selectedFiles.size} of ${cameraFiles.size} selected",
                        style = MaterialTheme.typography.bodySmall,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
            }

            // Main content.
            Box(modifier = Modifier.weight(1f)) {
                FileList(
                    files = cameraFiles,
                    selectedFiles = selectedFiles,
                    fileUploadStatus = fileUploadStatus,
                    isUploading = isUploading,
                    onSelectionChange = { file, checked ->
                        selectedFiles =
                            if (checked) {
                                selectedFiles + file
                            } else {
                                selectedFiles - file
                            }
                    },
                )

                // Status bar overlays at bottom.
                Box(modifier = Modifier.align(Alignment.BottomCenter)) {
                    StatusBar(
                        isLoadingFiles = isLoadingFiles,
                        isUploading = isUploading,
                        currentUploadInfo = currentUploadInfo,
                        onAbort = { workManager.cancelUniqueWork(UploadWorker.WORK_NAME) },
                    )
                }
            }

            // Upload button at bottom of column.
            UploadButton(
                selectedFiles = selectedFiles,
                isUploading = isUploading,
                onClick = {
                    val filePaths = selectedFiles.map { it.absolutePath }
                    Log.d("ClingSync", "Scheduling upload for files: $filePaths")

                    selectedFiles.forEach { file ->
                        fileUploadStatus = fileUploadStatus + (file.name to UploadStatus.Waiting)
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
            )
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
