package com.clingsync.android

import android.Manifest
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Environment
import android.provider.DocumentsContract
import android.provider.Settings
import androidx.activity.compose.rememberLauncherForActivityResult
import androidx.activity.compose.setContent
import androidx.activity.result.contract.ActivityResultContracts
import androidx.activity.viewModels
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
import androidx.compose.material3.AlertDialog
import androidx.compose.material3.Button
import androidx.compose.material3.Card
import androidx.compose.material3.CardDefaults
import androidx.compose.material3.Checkbox
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.ExposedDropdownMenuBox
import androidx.compose.material3.ExposedDropdownMenuDefaults
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.MenuAnchorType
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.TextField
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.text.style.TextAlign
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import androidx.core.content.ContextCompat
import androidx.core.view.WindowCompat
import androidx.fragment.app.FragmentActivity
import com.clingsync.android.effect.SafPathDecoder
import com.clingsync.android.presentation.MainEvent
import com.clingsync.android.presentation.MainUiState
import com.clingsync.android.presentation.MainViewModel
import com.clingsync.android.presentation.Overlay
import com.clingsync.android.presentation.ShareOutcome
import com.clingsync.android.presentation.ViewAction
import com.clingsync.android.ui.ScrollAwareTopBar
import com.clingsync.android.ui.formatFileSize
import com.clingsync.android.ui.theme.ClingSyncTheme
import java.io.File
import androidx.compose.material.icons.filled.Settings as SettingsIcon

class MainActivity : FragmentActivity() {
    private val viewModel: MainViewModel by viewModels { MainViewModel.Factory(application) }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setTheme(R.style.Theme_ClingSync)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        GoBridgeProvider.initialize(applicationContext)
        MergeReminderScheduler.ensureScheduled(applicationContext)
        setContent {
            ClingSyncTheme {
                MainRoot(activity = this, viewModel = viewModel)
            }
        }
    }
}

// Composition root: owns the permission/SAF launchers and biometric prompt (the
// Activity-scoped bits the ViewModel can't touch), turns the ViewModel's
// ViewActions into those calls, and feeds results back as events.
@Composable
fun MainRoot(
    activity: FragmentActivity,
    viewModel: MainViewModel,
) {
    val state by viewModel.state.collectAsState()
    val passphraseStore = remember { PassphraseStore(activity) }

    val permissionLauncher =
        rememberLauncherForActivityResult(ActivityResultContracts.RequestMultiplePermissions()) { permissions ->
            viewModel.dispatch(MainEvent.PermissionResult(permissions.values.all { it }))
        }

    // Notifications are optional (only the daily backup reminder uses them), so the
    // request is kept out of the file-access gate and its result is not acted on.
    val notificationPermissionLauncher =
        rememberLauncherForActivityResult(ActivityResultContracts.RequestPermission()) { }
    LaunchedEffect(Unit) {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU &&
            ContextCompat.checkSelfPermission(activity, Manifest.permission.POST_NOTIFICATIONS) !=
            PackageManager.PERMISSION_GRANTED
        ) {
            notificationPermissionLauncher.launch(Manifest.permission.POST_NOTIFICATIONS)
        }
    }

    var directoryPickerCallback by remember { mutableStateOf<((String) -> Unit)?>(null) }
    val directoryPickerLauncher =
        rememberLauncherForActivityResult(ActivityResultContracts.OpenDocumentTree()) { uri ->
            if (uri != null && uri.authority == "com.android.externalstorage.documents") {
                val docId = DocumentsContract.getTreeDocumentId(uri)
                SafPathDecoder.decode(docId, Environment.getExternalStorageDirectory().path)?.let { path ->
                    directoryPickerCallback?.invoke(path)
                }
            }
            directoryPickerCallback = null
        }

    LaunchedEffect(Unit) {
        viewModel.actions.collect { action ->
            when (action) {
                ViewAction.RequestPermissions -> permissionLauncher.launch(requiredPermissions())
                ViewAction.OpenStorageSettings -> openStorageSettings(activity)
                is ViewAction.LoadStoredPassphrase ->
                    passphraseStore.load(
                        activity = activity,
                        repositoryID = action.repositoryId,
                        onSuccess = { viewModel.dispatch(MainEvent.PassphraseLoaded(it)) },
                        onError = { viewModel.dispatch(MainEvent.PassphraseLoadFailed(it)) },
                    )
                is ViewAction.SavePassphrase ->
                    passphraseStore.save(activity, action.passphrase, action.repositoryId) {}
                // Only the share Activity finishes on this; the main app stays open.
                ViewAction.Finish -> Unit
            }
        }
    }

    LaunchedEffect(Unit) { viewModel.onStart() }

    MainScreen(
        state = state,
        onEvent = viewModel::dispatch,
        onBrowseDirectory = { onResult ->
            directoryPickerCallback = onResult
            directoryPickerLauncher.launch(null)
        },
    )
}

@Composable
fun MainScreen(
    state: MainUiState,
    onEvent: (MainEvent) -> Unit,
    onBrowseDirectory: (onResult: (String) -> Unit) -> Unit,
    onCancel: (() -> Unit)? = null,
) {
    val lazyListState = rememberLazyListState()

    Scaffold(
        containerColor = MaterialTheme.colorScheme.background,
        topBar = { AppTopBar(state, onEvent, onCancel) },
    ) { innerPadding ->
        Column(
            modifier =
                Modifier
                    .fillMaxSize()
                    .padding(innerPadding),
        ) {
            if (state.shareMode) {
                ShareTargetPicker(state, onEvent)
            }
            if (!state.hasPermission) {
                PermissionRequiredScreen()
                return@Column
            }
            if (state.isLoadingFiles) {
                SearchingScreen()
                return@Column
            }
            if (state.files.isEmpty()) {
                EmptyFilesScreen()
                return@Column
            }

            if (state.showSearch) {
                SearchBar(state.searchQuery, onEvent)
            }

            if (!state.isBusy) {
                state.scanProgress?.let { (scanned, total) -> ScanningBanner(scanned, total) }
            }

            if (!state.isConnected && !state.isConnecting && !state.isUploading && state.settings.isValid()) {
                ConnectBanner(onEvent)
            }

            Box(modifier = Modifier.weight(1f)) {
                FileList(
                    files = state.displayedFiles,
                    selectedPaths = state.selectedPaths,
                    fileStatus = state.fileStatus,
                    isUploading = state.isUploading || !state.isConnected,
                    sourceDir = getSourceDirectory(state.settings),
                    lazyListState = lazyListState,
                    topPadding = if (state.isConnected) 88.dp else 8.dp,
                    onSelectionChange = { file, checked ->
                        onEvent(MainEvent.FileSelectionChanged(file.absolutePath, checked))
                    },
                )

                if (state.isConnected) {
                    ScrollAwareTopBar(
                        lazyListState = lazyListState,
                        selectedFiles = state.selectedFiles.toSet(),
                        isUploading = state.isBusy,
                        isScanning = state.isScanning,
                        uploadInfo = state.uploadInfo,
                        onUploadClick = { onEvent(MainEvent.UploadClicked) },
                        onSelectAllClick = { onEvent(MainEvent.SelectAllClicked) },
                        onAbortClick = { onEvent(MainEvent.AbortClicked) },
                        uploadedBytes = state.uploadedBytes,
                        canSelectAll = state.selectAllTargets.isNotEmpty(),
                    )
                }
            }
        }

        Dialogs(state, onEvent, onBrowseDirectory)

        state.shareOutcome?.let { ShareOutcomeDialog(it, onEvent) }

        if (state.isConnecting) {
            ConnectingOverlay()
        }
    }
}

@Composable
private fun ShareOutcomeDialog(
    outcome: ShareOutcome,
    onEvent: (MainEvent) -> Unit,
) {
    AlertDialog(
        onDismissRequest = { onEvent(MainEvent.ShareOutcomeAcknowledged) },
        title = { Text(if (outcome is ShareOutcome.Success) "Upload complete" else "Upload failed") },
        text = {
            Text(
                when (outcome) {
                    is ShareOutcome.Success ->
                        "Uploaded ${outcome.fileCount} file${if (outcome.fileCount == 1) "" else "s"}."
                    is ShareOutcome.Failure -> outcome.message
                },
            )
        },
        confirmButton = {
            TextButton(onClick = { onEvent(MainEvent.ShareOutcomeAcknowledged) }) { Text("OK") }
        },
    )
}

@Composable
private fun AppTopBar(
    state: MainUiState,
    onEvent: (MainEvent) -> Unit,
    onCancel: (() -> Unit)?,
) {
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
                    text = if (state.shareMode) "Share with Cling Sync" else "Cling Sync",
                    style = MaterialTheme.typography.headlineSmall,
                    fontWeight = FontWeight.Bold,
                    color = MaterialTheme.colorScheme.onSurface,
                )

                if (state.shareMode) {
                    TextButton(onClick = { onCancel?.invoke() }) { Text("Cancel") }
                } else {
                    val disabled = state.isBusy
                    val iconTint =
                        if (disabled) {
                            MaterialTheme.colorScheme.onSurface.copy(alpha = 0.38f)
                        } else {
                            MaterialTheme.colorScheme.onSurfaceVariant
                        }

                    Row {
                        IconButton(onClick = { onEvent(MainEvent.SearchToggled) }, enabled = !disabled) {
                            Icon(
                                if (state.showSearch) Icons.Default.Close else Icons.Default.Search,
                                if (state.showSearch) "Close search" else "Search",
                                Modifier.size(24.dp),
                                iconTint,
                            )
                        }
                        IconButton(onClick = { onEvent(MainEvent.RefreshClicked) }, enabled = !disabled) {
                            Icon(Icons.Default.Refresh, "Refresh", Modifier.size(24.dp), iconTint)
                        }
                        IconButton(onClick = { onEvent(MainEvent.SettingsClicked) }, enabled = !disabled) {
                            Icon(Icons.Default.SettingsIcon, "Settings", Modifier.size(24.dp), iconTint)
                        }
                    }
                }
            }
        }
    }
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
private fun ShareTargetPicker(
    state: MainUiState,
    onEvent: (MainEvent) -> Unit,
) {
    var expanded by remember { mutableStateOf(false) }
    val enabled = !state.isBusy
    ExposedDropdownMenuBox(
        expanded = expanded,
        onExpandedChange = { if (enabled) expanded = it },
        modifier = Modifier.padding(horizontal = 16.dp, vertical = 8.dp),
    ) {
        OutlinedTextField(
            value = state.settings.repoPathPrefix,
            onValueChange = { onEvent(MainEvent.RepoPathPrefixChanged(it)) },
            enabled = enabled,
            singleLine = true,
            label = { Text("Target directory") },
            placeholder = { Text("Repository root") },
            trailingIcon = { ExposedDropdownMenuDefaults.TrailingIcon(expanded = expanded) },
            modifier =
                Modifier
                    .fillMaxWidth()
                    .menuAnchor(MenuAnchorType.PrimaryEditable),
        )
        ExposedDropdownMenu(expanded = expanded, onDismissRequest = { expanded = false }) {
            state.shareTargetOptions.forEach { option ->
                DropdownMenuItem(
                    text = { Text(option.ifBlank { "Repository root" }) },
                    onClick = {
                        onEvent(MainEvent.RepoPathPrefixChanged(option))
                        expanded = false
                    },
                )
            }
        }
    }
}

@Composable
private fun SearchBar(
    query: String,
    onEvent: (MainEvent) -> Unit,
) {
    TextField(
        value = query,
        onValueChange = { onEvent(MainEvent.SearchQueryChanged(it)) },
        placeholder = { Text("Filter files...") },
        singleLine = true,
        leadingIcon = { Icon(Icons.Default.Search, "Search", Modifier.size(20.dp)) },
        trailingIcon = {
            if (query.isNotEmpty()) {
                IconButton(onClick = { onEvent(MainEvent.SearchCleared) }) {
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

@Composable
private fun ScanningBanner(
    scanned: Int,
    total: Int,
) {
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
            CircularProgressIndicator(modifier = Modifier.size(16.dp), strokeWidth = 2.dp)
            Spacer(modifier = Modifier.width(12.dp))
            Text(
                text = "Scanning $scanned/$total files",
                style = MaterialTheme.typography.bodyMedium,
                color = MaterialTheme.colorScheme.onSurface,
            )
        }
    }
}

@Composable
private fun ConnectBanner(onEvent: (MainEvent) -> Unit) {
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
            Button(onClick = { onEvent(MainEvent.ConnectClicked) }) {
                Text("Connect")
            }
        }
    }
}

@Composable
private fun Dialogs(
    state: MainUiState,
    onEvent: (MainEvent) -> Unit,
    onBrowseDirectory: (onResult: (String) -> Unit) -> Unit,
) {
    if (state.showSettings) {
        SettingsDialog(
            settings = state.settings,
            onSave = { onEvent(MainEvent.SettingsSaved(it)) },
            onTestConnection = { onEvent(MainEvent.SettingsTestConnection(it)) },
            onBrowseDirectory = onBrowseDirectory,
            onDismiss = if (state.settings.isValid()) ({ onEvent(MainEvent.SettingsDismissed) }) else null,
        )
    }

    when (val overlay = state.overlay) {
        Overlay.None -> Unit
        is Overlay.Error ->
            UnifiedErrorDialog(
                errorState = ErrorDialogState(overlay.title, overlay.message),
                onDismiss = { onEvent(MainEvent.ErrorDismissed) },
            )
        Overlay.StoragePermission ->
            StoragePermissionDialog(
                onConfirm = { onEvent(MainEvent.OpenStorageSettingsClicked) },
                onDismiss = { onEvent(MainEvent.StoragePermissionDismissed) },
            )
        is Overlay.Passphrase ->
            PassphrasePromptDialog(
                showKeychainOption = overlay.showKeychainOption,
                onConfirm = { onEvent(MainEvent.PassphraseEntered(it)) },
                onDismiss = { onEvent(MainEvent.PassphraseDismissed) },
            )
        Overlay.S3Credentials ->
            S3CredentialsPromptDialog(
                onConfirm = { onEvent(MainEvent.S3CredentialsEntered(it)) },
                onDismiss = { onEvent(MainEvent.S3CredentialsDismissed) },
            )
    }
}

@Composable
private fun StoragePermissionDialog(
    onConfirm: () -> Unit,
    onDismiss: () -> Unit,
) {
    AlertDialog(
        onDismissRequest = onDismiss,
        title = { Text("Storage Permission Required") },
        text = { Text("To access all file types, enable \"All files access\" for Cling Sync.") },
        confirmButton = {
            Button(onClick = onConfirm) { Text("Open Settings") }
        },
        dismissButton = {
            TextButton(onClick = onDismiss) { Text("Cancel") }
        },
    )
}

@Composable
private fun ConnectingOverlay() {
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
                CircularProgressIndicator(modifier = Modifier.size(24.dp), strokeWidth = 2.dp)
                Spacer(modifier = Modifier.width(16.dp))
                Text(text = "Connecting to server...", style = MaterialTheme.typography.bodyLarge)
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
fun SearchingScreen() {
    Box(
        modifier = Modifier.fillMaxSize(),
        contentAlignment = Alignment.Center,
    ) {
        Column(
            horizontalAlignment = Alignment.CenterHorizontally,
            verticalArrangement = Arrangement.Center,
        ) {
            CircularProgressIndicator(modifier = Modifier.size(48.dp))
            Spacer(modifier = Modifier.height(16.dp))
            Text(text = "Searching files...", style = MaterialTheme.typography.bodyLarge)
        }
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
    // Only not-yet-uploaded rows are interactive; tapping a synced/in-progress
    // row must not select it (the whole Card is toggleable, not just the box).
    val selectable = isSelectable(uploadStatus) && !isUploading
    Card(
        modifier =
            Modifier
                .fillMaxWidth()
                .toggleable(
                    value = isSelected,
                    enabled = selectable,
                    onValueChange = onSelectionChange,
                ),
        elevation = CardDefaults.cardElevation(defaultElevation = 2.dp),
        colors =
            if (isSelected) {
                CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.primaryContainer)
            } else {
                CardDefaults.cardColors(containerColor = MaterialTheme.colorScheme.surfaceContainer)
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
                    is FileStatus.Scanning ->
                        CircularProgressIndicator(modifier = Modifier.size(24.dp), strokeWidth = 2.dp)
                    is FileStatus.Waiting, is FileStatus.Uploading, is FileStatus.Committing ->
                        CircularProgressIndicator(modifier = Modifier.size(24.dp), strokeWidth = 2.dp)
                    is FileStatus.Uploaded ->
                        CircularProgressIndicator(
                            progress = { 1f },
                            modifier = Modifier.size(24.dp),
                            strokeWidth = 2.dp,
                        )
                    is FileStatus.Exists, is FileStatus.Done ->
                        Icon(
                            Icons.Default.CheckCircle,
                            contentDescription = "Synced",
                            modifier = Modifier.size(24.dp),
                            tint = MaterialTheme.colorScheme.primary,
                        )
                    else ->
                        Checkbox(
                            checked = isSelected,
                            onCheckedChange = onSelectionChange,
                            modifier = Modifier.testTag("checkbox_${file.name}"),
                            enabled = selectable,
                        )
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
                        overflow = TextOverflow.Ellipsis,
                        modifier = Modifier.fillMaxWidth(),
                    )
                }
                Text(
                    text = file.name,
                    style = MaterialTheme.typography.bodyMedium,
                    fontWeight = FontWeight.Medium,
                    maxLines = 1,
                    overflow = TextOverflow.Ellipsis,
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
                                        else -> MaterialTheme.colorScheme.primary
                                    },
                                fontWeight = FontWeight.Medium,
                                maxLines = 1,
                                overflow = TextOverflow.Ellipsis,
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
    selectedPaths: Set<String>,
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
            FileListItem(
                file = file,
                folder = getFileFolder(file, sourceDir),
                isSelected = file.absolutePath in selectedPaths,
                uploadStatus = fileStatus[file.absolutePath],
                isUploading = isUploading,
                onSelectionChange = { checked -> onSelectionChange(file, checked) },
            )
        }
    }
}

private fun requiredPermissions(): Array<String> =
    if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        arrayOf(Manifest.permission.READ_MEDIA_IMAGES, Manifest.permission.READ_MEDIA_VIDEO)
    } else {
        arrayOf(Manifest.permission.READ_EXTERNAL_STORAGE)
    }

private fun openStorageSettings(context: Context) {
    try {
        context.startActivity(
            Intent(
                Settings.ACTION_MANAGE_APP_ALL_FILES_ACCESS_PERMISSION,
                Uri.parse("package:${context.packageName}"),
            ),
        )
    } catch (_: Exception) {
        context.startActivity(Intent(Settings.ACTION_MANAGE_ALL_FILES_ACCESS_PERMISSION))
    }
}
