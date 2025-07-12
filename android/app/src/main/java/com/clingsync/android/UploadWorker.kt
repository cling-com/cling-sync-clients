package com.clingsync.android

import android.app.NotificationChannel
import android.app.NotificationManager
import android.content.Context
import android.content.pm.ServiceInfo
import android.os.Build
import android.util.Log
import androidx.core.app.NotificationCompat
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.ForegroundInfo
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File

data class Upload(
    val files: List<String>,
    val author: String,
    val message: String,
    val hostUrl: String,
    val password: String,
    val repoPathPrefix: String,
) {
    val revisionEntries: MutableList<String> = mutableListOf()
}

class UploadWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {
    companion object {
        const val WORK_NAME = "upload_work"
        const val KEY_FILE_PATHS_FILE = "file_paths_file"
        const val KEY_REPO_PATH_PREFIX = "repo_path_prefix"
        const val KEY_AUTHOR = "author"
        const val KEY_MESSAGE = "message"
        const val KEY_HOST_URL = "host_url"
        const val KEY_PASSWORD = "password"
        const val KEY_REVISION_ID = "revision_id"

        private const val NOTIFICATION_ID = 1
        private const val CHANNEL_ID = "upload_channel"
        private const val TEMP_FILE_NAME = "pending_upload_files.txt"

        fun enqueueUpload(
            context: Context,
            filePaths: List<String>,
            repoPathPrefix: String,
            author: String,
            message: String,
            hostUrl: String,
            password: String,
        ) {
            // Always write paths to a file to avoid size limits.
            val tempFile = File(context.cacheDir, TEMP_FILE_NAME)
            tempFile.writeText(filePaths.joinToString("\n"))

            val inputData =
                workDataOf(
                    KEY_FILE_PATHS_FILE to tempFile.absolutePath,
                    KEY_REPO_PATH_PREFIX to repoPathPrefix,
                    KEY_AUTHOR to author,
                    KEY_MESSAGE to message,
                    KEY_HOST_URL to hostUrl,
                    KEY_PASSWORD to password,
                )

            val workRequest =
                OneTimeWorkRequestBuilder<UploadWorker>()
                    .setInputData(inputData)
                    .addTag("upload")
                    .build()

            WorkManager.getInstance(context)
                .enqueueUniqueWork(WORK_NAME, ExistingWorkPolicy.KEEP, workRequest)
        }
    }

    private val goBridge = GoBridgeProvider.getInstance()

    override suspend fun doWork(): Result =
        withContext(Dispatchers.IO) {
            try {
                // Read file paths from file and delete it immediately.
                val filePath = inputData.getString(KEY_FILE_PATHS_FILE) ?: return@withContext Result.failure()
                val tempFile = File(filePath)
                val filePaths = tempFile.readText().split("\n").filter { it.isNotBlank() }.toTypedArray()
                tempFile.delete() // Delete immediately after reading.

                // Extract other parameters.
                val repoPathPrefix = inputData.getString(KEY_REPO_PATH_PREFIX) ?: return@withContext Result.failure()
                val author = inputData.getString(KEY_AUTHOR) ?: return@withContext Result.failure()
                val message = inputData.getString(KEY_MESSAGE) ?: return@withContext Result.failure()
                val hostUrl = inputData.getString(KEY_HOST_URL) ?: return@withContext Result.failure()
                val password = inputData.getString(KEY_PASSWORD) ?: return@withContext Result.failure()

                Log.d("UploadWorker", "Starting upload of ${filePaths.size} files")

                // Show foreground notification.
                setForeground(createForegroundInfo(0, filePaths.size))

                // Report initial status.
                setProgress(
                    workDataOf(
                        "total_files" to filePaths.size,
                        "status" to "waiting",
                    ),
                )

                // Ensure repository is open.
                goBridge.ensureOpen(hostUrl, password)

                // List to collect revision entries.
                val revisionEntries = mutableListOf<String>()

                // Upload each file.
                filePaths.forEachIndexed { index, filePath ->
                    val fileName = filePath.substringAfterLast("/")
                    Log.d("UploadWorker", "Uploading file ${index + 1}/${filePaths.size}: $filePath")

                    // Update progress with current file.
                    setProgress(
                        workDataOf(
                            "total_files" to filePaths.size,
                            "current_index" to (index + 1),
                            "current_file" to fileName,
                            "status" to "uploading",
                        ),
                    )

                    // Update progress notification.
                    setForeground(createForegroundInfo(index + 1, filePaths.size, fileName))

                    val revisionEntry = goBridge.uploadFile(filePath, repoPathPrefix)
                    revisionEntries.add(revisionEntry)
                }

                // Update progress to show we're committing.
                setProgress(
                    workDataOf(
                        "total_files" to filePaths.size,
                        "status" to "committing",
                    ),
                )

                // Update notification.
                setForeground(createForegroundInfo(filePaths.size, filePaths.size, "Committing..."))

                // Commit all entries.
                val revisionId = goBridge.commit(revisionEntries, author, message)
                Log.d("UploadWorker", "Commit successful: $revisionId")

                // Return success with revision ID.
                val outputData = workDataOf(KEY_REVISION_ID to revisionId)
                Result.success(outputData)
            } catch (e: Exception) {
                Log.e("UploadWorker", "Upload failed", e)

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
}
