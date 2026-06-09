package com.clingsync.android

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.work.CoroutineWorker
import androidx.work.Data
import androidx.work.ExistingWorkPolicy
import androidx.work.ForegroundInfo
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import com.clingsync.android.data.UploadProgressIo
import com.clingsync.android.data.UploadStatus
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import java.io.File

class UploadWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {
    companion object {
        const val WORK_NAME = "upload_work"
        const val KEY_FILE_PATHS_FILE = "file_paths_file"
        const val KEY_AUTHOR = "author"
        const val KEY_REVISION_ID = "revision_id"

        // Optional overrides for the share flow. When absent, the worker derives the
        // repo path prefix and source directory from the saved settings (the camera
        // backup flow). A share uploads staged files to `<prefix>/<name>` instead.
        const val KEY_REPO_PATH_PREFIX = "repo_path_prefix_override"
        const val KEY_SOURCE_DIR = "source_dir_override"

        private const val NOTIFICATION_ID = 1
        private const val CHANNEL_ID = "upload_channel"
        private const val TEMP_FILE_NAME = "pending_upload_files.txt"
        private const val STATUS_FILE_NAME = "upload_status.json"

        fun enqueueUpload(
            context: Context,
            filePaths: List<String>,
            author: String,
            repoPathPrefix: String? = null,
            sourceDir: String? = null,
        ): java.util.UUID {
            // Always write paths to a file to avoid size limits.
            val tempFile = File(context.cacheDir, TEMP_FILE_NAME)
            tempFile.writeText(filePaths.joinToString("\n"))

            val inputData =
                Data.Builder()
                    .putString(KEY_FILE_PATHS_FILE, tempFile.absolutePath)
                    .putString(KEY_AUTHOR, author)
                    .apply {
                        if (repoPathPrefix != null) putString(KEY_REPO_PATH_PREFIX, repoPathPrefix)
                        if (sourceDir != null) putString(KEY_SOURCE_DIR, sourceDir)
                    }
                    .build()

            val workRequest =
                OneTimeWorkRequestBuilder<UploadWorker>()
                    .setInputData(inputData)
                    .addTag("upload")
                    .build()

            WorkManager.getInstance(context)
                .enqueueUniqueWork(WORK_NAME, ExistingWorkPolicy.REPLACE, workRequest)

            return workRequest.id
        }
    }

    private val goBridge = GoBridgeProvider.getInstance()
    private val statusFile = File(applicationContext.cacheDir, STATUS_FILE_NAME)
    private val fileStatuses = mutableMapOf<String, UploadStatus>()
    private var uploadedBytes = 0L

    override suspend fun doWork(): Result =
        withContext(Dispatchers.IO) {
            GoBridgeProvider.initialize(applicationContext)

            // Setup a coroutine to periodically update progress
            val progressJob =
                launch {
                    while (true) {
                        updateProgressFile()
                        delay(1000) // Update every second
                    }
                }

            try {
                // Read file paths from file and delete it immediately.
                val filePath = inputData.getString(KEY_FILE_PATHS_FILE) ?: return@withContext Result.failure()
                val tempFile = File(filePath)
                val filePaths = tempFile.readText().split("\n").filter { it.isNotBlank() }.toTypedArray()
                tempFile.delete() // Delete immediately after reading.

                // Extract other parameters.
                val author = inputData.getString(KEY_AUTHOR) ?: return@withContext Result.failure()

                Log.d("Worker", "Starting upload of ${filePaths.size} files")

                // Show foreground notification.
                setForeground(createForegroundInfo(0, filePaths.size))

                // Initialize all files as waiting (keyed by absolute path).
                filePaths.forEach { path ->
                    fileStatuses[path] = UploadStatus.WAITING
                }

                // Verify repository is open. The UI must open it before starting the worker.
                val settings = SettingsManager(applicationContext).getSettings()
                val repositoryUri =
                    RepositoryUriStore(applicationContext).get(settings.repositoryID()) ?: settings.hostUrl
                if (!goBridge.checkRepositoryOpen(repositoryUri)) {
                    return@withContext Result.failure(
                        workDataOf("error" to "Repository not authenticated. Please open the app and try again."),
                    )
                }

                // List to collect revision entries.
                val revisionEntries = mutableListOf<String>()

                // Upload each file. The share flow overrides the prefix + source
                // directory so staged files land under the chosen target directory.
                val sourceDir = inputData.getString(KEY_SOURCE_DIR)?.let(::File) ?: getSourceDirectory(settings)
                val prefix = (inputData.getString(KEY_REPO_PATH_PREFIX) ?: settings.repoPathPrefix).trim('/')
                filePaths.forEachIndexed { index, filePath ->
                    val fileSize = File(filePath).length()
                    Log.d("Worker", "Uploading file ${index + 1}/${filePaths.size}: $filePath")

                    fileStatuses[filePath] = UploadStatus.UPLOADING

                    // Update progress notification.
                    setForeground(createForegroundInfo(index + 1, filePaths.size, File(filePath).name))

                    val relativePath = File(filePath).relativeTo(sourceDir).path
                    val repoFilePath = if (prefix.isEmpty()) relativePath else "$prefix/$relativePath"
                    val revisionEntry = goBridge.uploadFile(filePath, repoFilePath)
                    if (revisionEntry != null) {
                        revisionEntries.add(revisionEntry)
                        uploadedBytes += fileSize
                        fileStatuses[filePath] = UploadStatus.UPLOADED
                    } else {
                        Log.d("Worker", "Skipped file $filePath - already exists with same hash")
                        fileStatuses[filePath] = UploadStatus.SKIPPED
                        uploadedBytes += fileSize
                    }
                }

                // Mark all files as committing.
                filePaths.forEach { path ->
                    if (fileStatuses[path] == UploadStatus.UPLOADING || fileStatuses[path] == UploadStatus.UPLOADED) {
                        fileStatuses[path] = UploadStatus.COMMITTING
                    }
                }

                // Update notification.
                setForeground(createForegroundInfo(filePaths.size, filePaths.size, "Committing..."))

                // Only commit if we have revision entries
                val revisionId =
                    if (revisionEntries.isNotEmpty()) {
                        // Use actual upload count in commit message.
                        val count = revisionEntries.size
                        val actualMessage =
                            "Backup $count file${if (count == 1) "" else "s"}" +
                                " from ${Build.MANUFACTURER} ${Build.MODEL}"
                        val id = goBridge.commit(revisionEntries, author, actualMessage)
                        Log.d("Worker", "Commit successful: $id")
                        id
                    } else {
                        Log.d("Worker", "No files to commit - all files already exist with same hash")
                        ""
                    }

                // Build complete status file and send as result
                val resultFile = File(applicationContext.cacheDir, "upload_result_${System.currentTimeMillis()}.json")
                UploadProgressIo.write(resultFile, fileStatuses)

                // Return success with revision ID and result file.
                val outputData =
                    workDataOf(
                        KEY_REVISION_ID to revisionId,
                        "result_file" to resultFile.absolutePath,
                    )

                Result.success(outputData)
            } catch (e: Exception) {
                Log.e("Worker", "Upload failed", e)

                // Build detailed error message with stack trace.
                val errorMessage =
                    buildString {
                        appendLine("Error: ${e.message}")
                        appendLine()
                        appendLine("Type: ${e.javaClass.simpleName}")
                        appendLine()
                        appendLine("Stack trace:")
                        e.stackTrace.take(20).forEach { element ->
                            appendLine("  at $element")
                        }
                        if (e.stackTrace.size > 20) {
                            appendLine("  ... ${e.stackTrace.size - 20} more")
                        }
                    }

                Result.failure(
                    workDataOf("error" to errorMessage),
                )
            } finally {
                // Stop the periodic updater and write the final status. This must
                // run on every exit path, including the early `return@withContext`
                // failures above, or the infinite progress loop would keep the
                // enclosing withContext from ever completing.
                progressJob.cancel()
                updateProgressFile()
                // A share upload stages its files in a cache subdir it owns; reclaim
                // it here (tied to the worker, which outlives the share screen) rather
                // than in the UI, so cancelling the screen mid-upload can't leak it.
                inputData
                    .getString(KEY_SOURCE_DIR)
                    ?.let(::File)
                    ?.takeIf { it.absolutePath.startsWith(applicationContext.cacheDir.absolutePath) }
                    ?.deleteRecursively()
            }
        }

    private fun createForegroundInfo(
        current: Int,
        total: Int,
        currentFile: String? = null,
    ): ForegroundInfo {
        createNotificationChannel()

        val title = "Backing up files"
        val text =
            if (currentFile != null) {
                if (currentFile == "Committing...") {
                    "Committing $total files..."
                } else {
                    "Uploading $current of $total: $currentFile"
                }
            } else {
                "Preparing upload..."
            }

        val notification =
            NotificationCompat.Builder(applicationContext, CHANNEL_ID)
                .setContentTitle(title)
                .setContentText(text)
                .setSmallIcon(android.R.drawable.ic_menu_upload)
                .setProgress(total, current, false)
                .setOngoing(true)
                .build()

        return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            ForegroundInfo(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_DATA_SYNC,
            )
        } else {
            ForegroundInfo(NOTIFICATION_ID, notification)
        }
    }

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            val channel =
                NotificationChannel(
                    CHANNEL_ID,
                    "File Upload",
                    NotificationManager.IMPORTANCE_LOW,
                ).apply {
                    description = "Shows progress of file uploads"
                }

            val notificationManager = applicationContext.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager
            notificationManager.createNotificationChannel(channel)
        }
    }

    private suspend fun updateProgressFile() {
        try {
            UploadProgressIo.write(statusFile, fileStatuses)

            // Send progress update with just the filename
            setProgress(
                workDataOf(
                    "status_file" to statusFile.absolutePath,
                    "uploaded_bytes" to uploadedBytes,
                ),
            )
        } catch (e: Exception) {
            Log.e("Worker", "Failed to update progress file", e)
        }
    }
}
