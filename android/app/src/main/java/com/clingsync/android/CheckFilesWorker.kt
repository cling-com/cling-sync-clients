package com.clingsync.android

import android.content.Context
import android.util.Log
import androidx.work.CoroutineWorker
import androidx.work.ExistingWorkPolicy
import androidx.work.OneTimeWorkRequestBuilder
import androidx.work.WorkManager
import androidx.work.WorkerParameters
import androidx.work.workDataOf
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest

class CheckFilesWorker(
    context: Context,
    params: WorkerParameters,
) : CoroutineWorker(context, params) {
    companion object {
        const val WORK_NAME = "check_files_work"
        const val KEY_FILE_PATHS_FILE = "file_paths_file"
        const val KEY_HOST_URL = "host_url"
        const val KEY_PASSWORD = "password"

        private const val TEMP_FILE_NAME = "pending_check_files.txt"
        private const val MAX_BATCH_SIZE = 100
        private const val BATCH_TIME_LIMIT_MS = 1000L

        fun enqueueCheck(
            context: Context,
            filePaths: List<String>,
            hostUrl: String,
            password: String,
        ) {
            // Always write paths to a file to avoid size limits.
            val tempFile = File(context.cacheDir, TEMP_FILE_NAME)
            tempFile.writeText(filePaths.joinToString("\n"))

            val inputData =
                workDataOf(
                    KEY_FILE_PATHS_FILE to tempFile.absolutePath,
                    KEY_HOST_URL to hostUrl,
                    KEY_PASSWORD to password,
                )

            val workRequest =
                OneTimeWorkRequestBuilder<CheckFilesWorker>()
                    .setInputData(inputData)
                    .addTag("check")
                    .build()

            WorkManager.getInstance(context)
                .enqueueUniqueWork(WORK_NAME, ExistingWorkPolicy.REPLACE, workRequest)
        }
    }

    private val goBridge = GoBridgeProvider.getInstance()

    override suspend fun doWork(): Result =
        withContext(Dispatchers.IO) {
            try {
                // Read file paths from file and delete it immediately.
                val filePath = inputData.getString(KEY_FILE_PATHS_FILE) ?: return@withContext Result.failure()
                val tempFile = File(filePath)
                val filePaths = tempFile.readText().split("\n").filter { it.isNotBlank() }
                tempFile.delete() // Delete immediately after reading.

                // Extract other parameters.
                val hostUrl = inputData.getString(KEY_HOST_URL) ?: return@withContext Result.failure()
                val password = inputData.getString(KEY_PASSWORD) ?: return@withContext Result.failure()

                Log.d("CheckFilesWorker", "Starting check of ${filePaths.size} files")

                // Ensure repository is open.
                goBridge.ensureOpen(hostUrl, password)

                Log.d("CheckFilesWorker", "Starting to process ${filePaths.size} files")

                // Build complete status map for all files
                val fileStatuses = mutableMapOf<String, String>() // filename -> status:repoPath
                var processedCount = 0

                // Process files in batches
                var fileIndex = 0
                while (fileIndex < filePaths.size) {
                    // Check if we should stop
                    if (isStopped) {
                        Log.d("CheckFilesWorker", "Check cancelled at file $fileIndex")
                        return@withContext Result.success()
                    }

                    // Build a batch
                    val batchFiles = mutableListOf<String>()
                    val batchSha256s = mutableListOf<String>()
                    val batchFileNames = mutableListOf<String>()
                    val batchStartTime = System.currentTimeMillis()

                    // Fill the batch - calculate SHA256s for up to 5 seconds or MAX_BATCH_SIZE files
                    while (fileIndex < filePaths.size &&
                        batchFiles.size < MAX_BATCH_SIZE &&
                        (batchFiles.isEmpty() || (System.currentTimeMillis() - batchStartTime) < BATCH_TIME_LIMIT_MS)
                    ) {
                        val filePath = filePaths[fileIndex]
                        val file = File(filePath)
                        val fileName = file.name

                        if (!file.exists()) {
                            // File doesn't exist - remove from UI
                            fileStatuses[fileName] = "not_found:"
                            processedCount++
                            fileIndex++
                            continue
                        }

                        // Calculate SHA256
                        val sha256 = calculateSHA256(file)
                        Log.d("CheckFilesWorker", "Calculated SHA256 for $fileName: $sha256")

                        batchFiles.add(filePath)
                        batchSha256s.add(sha256)
                        batchFileNames.add(fileName)
                        fileIndex++
                    }

                    // Process batch if we have files
                    if (batchSha256s.isNotEmpty()) {
                        try {
                            val results = goBridge.checkFiles(batchSha256s)
                            val elapsedMs = System.currentTimeMillis() - batchStartTime
                            Log.d(
                                "CheckFilesWorker",
                                "Batch of ${batchSha256s.size} files checked in ${elapsedMs}ms, got ${results.size} results",
                            )

                            // Process results
                            for (i in batchFileNames.indices) {
                                val fileName = batchFileNames[i]
                                val repoPath = if (i < results.size) results[i] else ""

                                if (repoPath.isNotEmpty()) {
                                    fileStatuses[fileName] = "exists:$repoPath"
                                } else {
                                    fileStatuses[fileName] = "new:"
                                }
                                processedCount++
                            }
                        } catch (e: Exception) {
                            Log.e("CheckFilesWorker", "Error checking batch", e)
                            // On error, mark all batch files as new
                            for (fileName in batchFileNames) {
                                fileStatuses[fileName] = "new:"
                                processedCount++
                            }
                        }

                        // Send progress update after each batch
                        sendProgressUpdate(fileStatuses, processedCount, filePaths.size)
                    }

                    // Log progress every 10 files
                    if (processedCount % 10 == 0) {
                        Log.d("CheckFilesWorker", "Progress: $processedCount/${filePaths.size} files processed")
                    }
                }

                // Send final progress update
                sendProgressUpdate(fileStatuses, processedCount, filePaths.size)

                // Final status
                Log.d("CheckFilesWorker", "Check completed. Total: ${filePaths.size}, Processed: $processedCount")

                // Return success
                Result.success()
            } catch (e: Exception) {
                Log.e("CheckFilesWorker", "Check failed", e)
                Result.failure(
                    workDataOf("error" to e.message),
                )
            }
        }

    private fun calculateSHA256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { fis ->
            val buffer = ByteArray(8192)
            var read: Int
            while (fis.read(buffer).also { read = it } > 0) {
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private suspend fun sendProgressUpdate(
        fileStatuses: Map<String, String>,
        processedCount: Int,
        totalFiles: Int,
    ) {
        // Convert map to JSON for efficient transfer
        val statusJson =
            JSONObject().apply {
                fileStatuses.forEach { (fileName, statusAndPath) ->
                    put(fileName, statusAndPath)
                }
            }

        setProgress(
            workDataOf(
                "file_statuses" to statusJson.toString(),
                "processed_count" to processedCount,
                "total_files" to totalFiles,
            ),
        )
    }
}
