package com.clingsync.android

import android.content.ContentResolver
import android.content.Intent
import android.net.Uri
import android.os.Bundle
import android.provider.DocumentsContract
import android.provider.OpenableColumns
import android.system.Os
import androidx.activity.compose.setContent
import androidx.activity.viewModels
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.collectAsState
import androidx.compose.runtime.getValue
import androidx.compose.runtime.remember
import androidx.core.content.IntentCompat
import androidx.core.view.WindowCompat
import androidx.fragment.app.FragmentActivity
import com.clingsync.android.presentation.MainEvent
import com.clingsync.android.presentation.MainViewModel
import com.clingsync.android.presentation.ViewAction
import com.clingsync.android.ui.theme.ClingSyncTheme
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID

// Entry point for files shared into the app (ACTION_SEND / ACTION_SEND_MULTIPLE).
// It stages the shared files into a per-launch cache dir and reuses the main backup
// screen (MainViewModel + MainScreen in share mode), so they are scanned, deduped,
// (de)selectable and uploaded exactly like the camera backup, with a target picker
// on top. The upload worker reclaims the staging dir when it finishes.
class ShareActivity : FragmentActivity() {
    private val stagingDir by lazy { File(cacheDir, "shared_uploads/${UUID.randomUUID()}") }
    private val viewModel: MainViewModel by viewModels {
        MainViewModel.Factory(application, sourceDirOverride = stagingDir.absolutePath, shareMode = true)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        setTheme(R.style.Theme_ClingSync)
        WindowCompat.setDecorFitsSystemWindows(window, false)
        GoBridgeProvider.initialize(applicationContext)
        val uris = incomingUris()
        setContent {
            ClingSyncTheme {
                ShareRoot(activity = this, viewModel = viewModel, uris = uris, stagingDir = stagingDir)
            }
        }
    }

    private fun incomingUris(): List<Uri> =
        when (intent?.action) {
            Intent.ACTION_SEND ->
                listOfNotNull(IntentCompat.getParcelableExtra(intent, Intent.EXTRA_STREAM, Uri::class.java))
            Intent.ACTION_SEND_MULTIPLE ->
                IntentCompat.getParcelableArrayListExtra(intent, Intent.EXTRA_STREAM, Uri::class.java) ?: emptyList()
            else -> emptyList()
        }
}

@Composable
private fun ShareRoot(
    activity: FragmentActivity,
    viewModel: MainViewModel,
    uris: List<Uri>,
    stagingDir: File,
) {
    val passphraseStore = remember { PassphraseStore(activity) }
    val state by viewModel.state.collectAsState()

    LaunchedEffect(Unit) {
        viewModel.actions.collect { action ->
            when (action) {
                is ViewAction.LoadStoredPassphrase ->
                    passphraseStore.load(
                        activity = activity,
                        repositoryID = action.repositoryId,
                        onSuccess = { viewModel.dispatch(MainEvent.PassphraseLoaded(it)) },
                        onError = { viewModel.dispatch(MainEvent.PassphraseLoadFailed(it)) },
                    )
                is ViewAction.SavePassphrase ->
                    passphraseStore.save(activity, action.passphrase, action.repositoryId) {}
                ViewAction.Finish -> activity.finish()
                // RequestPermissions / OpenStorageSettings don't apply to a share.
                else -> Unit
            }
        }
    }

    // Stage the shared files into the per-launch dir, then start the ViewModel (which
    // loads + scans them). Staging first keeps the worker's source directory complete.
    LaunchedEffect(Unit) {
        withContext(Dispatchers.IO) { stageInto(activity.contentResolver, uris, stagingDir) }
        viewModel.onStart()
    }

    MainScreen(
        state = state,
        onEvent = viewModel::dispatch,
        onBrowseDirectory = {},
        onCancel = activity::finish,
    )
}

private fun stageInto(
    resolver: ContentResolver,
    uris: List<Uri>,
    stagingDir: File,
) {
    stagingDir.mkdirs()
    val used = mutableSetOf<String>()
    for (uri in uris) {
        val dest = File(stagingDir, uniqueName(queryName(resolver, uri), used))
        try {
            resolver.openInputStream(uri)?.use { input ->
                dest.outputStream().use { output -> input.copyTo(output) }
            } ?: dest.delete()
            // Preserve the original modification time so the repository records it (and a
            // re-share dedups), not the copy time.
            sourceMtimeMillis(resolver, uri).takeIf { it > 0 }?.let { dest.setLastModified(it) }
        } catch (e: Exception) {
            dest.delete()
        }
    }
}

// The shared file's modification time in epoch millis, or 0 when it can't be read.
// fstat on the descriptor works for file-backed providers (FileProvider, MediaStore,
// SAF) where the LAST_MODIFIED column is absent (FileProvider only exposes name/size);
// the column query is a fallback for providers that don't hand out a real descriptor.
private fun sourceMtimeMillis(
    resolver: ContentResolver,
    uri: Uri,
): Long {
    val viaFd =
        try {
            resolver.openFileDescriptor(uri, "r")?.use { pfd -> Os.fstat(pfd.fileDescriptor).st_mtime * 1000L } ?: 0L
        } catch (e: Exception) {
            0L
        }
    if (viaFd > 0) return viaFd
    return try {
        resolver
            .query(uri, arrayOf(DocumentsContract.Document.COLUMN_LAST_MODIFIED), null, null, null)
            ?.use { cursor -> if (cursor.moveToFirst() && !cursor.isNull(0)) cursor.getLong(0) else 0L } ?: 0L
    } catch (e: Exception) {
        0L
    }
}

private fun queryName(
    resolver: ContentResolver,
    uri: Uri,
): String {
    var name = uri.lastPathSegment ?: "shared-file"
    resolver
        .query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
        ?.use { cursor ->
            if (cursor.moveToFirst()) {
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0 && !cursor.isNull(index)) name = cursor.getString(index)
            }
        }
    return name
}

private fun uniqueName(
    rawName: String,
    used: MutableSet<String>,
): String {
    val safe = rawName.substringAfterLast('/').ifBlank { "shared-file" }
    if (used.add(safe)) return safe
    val dot = safe.lastIndexOf('.')
    val base = if (dot > 0) safe.substring(0, dot) else safe
    val ext = if (dot > 0) safe.substring(dot) else ""
    var index = 1
    while (true) {
        val candidate = "$base ($index)$ext"
        if (used.add(candidate)) return candidate
        index++
    }
}
