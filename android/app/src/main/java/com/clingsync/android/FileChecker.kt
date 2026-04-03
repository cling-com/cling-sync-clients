package com.clingsync.android

import android.util.Log
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.security.MessageDigest

data class FileCheckUpdate(
    val statuses: Map<String, FileStatus>,
    val processedCount: Int,
    val totalFiles: Int,
)

data class FileCheckResult(
    val statuses: Map<String, FileStatus>,
    val processedCount: Int,
    val totalFiles: Int,
)

class FileChecker(
    private val sha256Cache: SHA256Cache,
    private val dispatcher: CoroutineDispatcher = Dispatchers.IO,
) {
    private val goBridge = GoBridgeProvider.getInstance()

    suspend fun checkFiles(
        filePaths: List<String>,
        onProgress: (suspend (FileCheckUpdate) -> Unit)? = null,
    ): Result<FileCheckResult> =
        withContext(dispatcher) {
            try {
                Log.d("FileChecker", "Starting to check ${filePaths.size} files")

                val fileStatuses = mutableMapOf<String, FileStatus>()
                var processedCount = 0
                var newHashCount = 0
                var fileIndex = 0

                // Interleave SHA256 computation (cached) and bridge checks so the UI
                // updates progressively as each batch completes.
                while (fileIndex < filePaths.size) {
                    val batchPaths = mutableListOf<String>()
                    val batchSha256s = mutableListOf<String>()

                    while (fileIndex < filePaths.size && batchPaths.size < MAX_BATCH_SIZE) {
                        val filePath = filePaths[fileIndex]
                        val file = File(filePath)
                        fileIndex++

                        if (!file.exists()) {
                            fileStatuses[filePath] = FileStatus.New
                            processedCount++
                            continue
                        }

                        val cached = sha256Cache.lookup(filePath, file.length(), file.lastModified())
                        val sha256 =
                            if (cached != null) {
                                cached
                            } else {
                                calculateSHA256(file).also {
                                    sha256Cache.store(filePath, file.length(), file.lastModified(), it)
                                    newHashCount++
                                    if (newHashCount % 10 == 0) sha256Cache.save()
                                }
                            }
                        batchPaths.add(filePath)
                        batchSha256s.add(sha256)
                    }

                    if (batchSha256s.isNotEmpty()) {
                        val batchStatuses = mutableMapOf<String, FileStatus>()
                        try {
                            val results = goBridge.checkFiles(batchSha256s)
                            for (i in batchPaths.indices) {
                                val repoPath = if (i < results.size) results[i] else ""
                                val status = if (repoPath.isNotEmpty()) FileStatus.Exists(repoPath) else FileStatus.New
                                fileStatuses[batchPaths[i]] = status
                                batchStatuses[batchPaths[i]] = status
                                processedCount++
                            }
                        } catch (e: Exception) {
                            Log.e("FileChecker", "Error checking batch", e)
                            for (path in batchPaths) {
                                fileStatuses[path] = FileStatus.New
                                batchStatuses[path] = FileStatus.New
                                processedCount++
                            }
                        }
                        onProgress?.invoke(
                            FileCheckUpdate(
                                statuses = batchStatuses,
                                processedCount = processedCount,
                                totalFiles = filePaths.size,
                            ),
                        )
                    }
                }

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
            } finally {
                sha256Cache.save()
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
    }
}
