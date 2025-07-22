package com.clingsync.android

import android.util.Log
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.withContext
import java.io.File
import java.security.MessageDigest

data class FileCheckUpdate(
    val fileName: String,
    val status: FileStatus,
    val processedCount: Int,
    val totalFiles: Int,
)

data class FileCheckResult(
    val statuses: Map<String, FileStatus>,
    val processedCount: Int,
    val totalFiles: Int,
)

class FileChecker {
    private val goBridge = GoBridgeProvider.getInstance()

    private val _updates = MutableSharedFlow<FileCheckUpdate>()
    val updates: SharedFlow<FileCheckUpdate> = _updates

    suspend fun checkFiles(
        filePaths: List<String>,
        hostUrl: String,
        password: String,
    ): Result<FileCheckResult> =
        withContext(Dispatchers.IO) {
            try {
                Log.d("FileChecker", "Starting check of ${filePaths.size} files")

                // Ensure repository is open
                goBridge.ensureOpen(hostUrl, password)

                Log.d("FileChecker", "Starting to process ${filePaths.size} files")

                // Build complete status map for all files
                val fileStatuses = mutableMapOf<String, FileStatus>()
                var processedCount = 0

                // Process files in batches
                var fileIndex = 0
                while (fileIndex < filePaths.size) {
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
                            fileStatuses[fileName] = FileStatus.New
                            processedCount++

                            // Send individual file update with delay
                            delay(10) // Prevent overwhelming the UI
                            _updates.emit(
                                FileCheckUpdate(
                                    fileName = fileName,
                                    status = FileStatus.New,
                                    processedCount = processedCount,
                                    totalFiles = filePaths.size,
                                ),
                            )

                            fileIndex++
                            continue
                        }

                        // Calculate SHA256
                        val sha256 = calculateSHA256(file)
                        Log.d("FileChecker", "Calculated SHA256 for $fileName: $sha256")

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
                                "FileChecker",
                                "Batch of ${batchSha256s.size} files checked in ${elapsedMs}ms, got ${results.size} results",
                            )

                            // Process results
                            for (i in batchFileNames.indices) {
                                val fileName = batchFileNames[i]
                                val repoPath = if (i < results.size) results[i] else ""

                                val status =
                                    if (repoPath.isNotEmpty()) {
                                        FileStatus.Exists(repoPath)
                                    } else {
                                        FileStatus.New
                                    }

                                fileStatuses[fileName] = status
                                processedCount++

                                // Send individual file update with delay
                                delay(10) // Prevent overwhelming the UI
                                _updates.emit(
                                    FileCheckUpdate(
                                        fileName = fileName,
                                        status = status,
                                        processedCount = processedCount,
                                        totalFiles = filePaths.size,
                                    ),
                                )
                            }
                        } catch (e: Exception) {
                            Log.e("FileChecker", "Error checking batch", e)
                            // On error, mark all batch files as new
                            for (fileName in batchFileNames) {
                                fileStatuses[fileName] = FileStatus.New
                                processedCount++

                                delay(10)
                                _updates.emit(
                                    FileCheckUpdate(
                                        fileName = fileName,
                                        status = FileStatus.New,
                                        processedCount = processedCount,
                                        totalFiles = filePaths.size,
                                    ),
                                )
                            }
                        }
                    }

                    // Log progress every 10 files
                    if (processedCount % 10 == 0) {
                        Log.d("FileChecker", "Progress: $processedCount/${filePaths.size} files processed")
                    }
                }

                // Final status
                Log.d("FileChecker", "Check completed. Total: ${filePaths.size}, Processed: $processedCount")

                Result.success(
                    FileCheckResult(
                        statuses = fileStatuses,
                        processedCount = processedCount,
                        totalFiles = filePaths.size,
                    ),
                )
            } catch (e: Exception) {
                Log.e("FileChecker", "Check failed", e)
                Result.failure(e)
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

    companion object {
        private const val MAX_BATCH_SIZE = 100
        private const val BATCH_TIME_LIMIT_MS = 1000L
    }
}
