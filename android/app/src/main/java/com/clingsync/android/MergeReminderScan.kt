package com.clingsync.android

import java.io.File

// Decides whether the source files contain anything worth a backup reminder.
// "Backed up" is answered by the bridge's checkFiles, which reads the persisted
// repository hash index, so this works without an open repository or passphrase.
class MergeReminderScan(
    private val cache: SHA256Cache,
    private val goBridge: IGoBridge,
) {
    // Daily: a file needs backing up unless its cached hash is already in the
    // repository. Files never hashed count as new. Reads no file content.
    fun countUnsynced(files: List<File>): Int {
        val cachedShas = mutableListOf<String>()
        var unhashed = 0
        for (file in files) {
            val sha = cache.peek(file.absolutePath)?.sha256
            if (sha == null) {
                unhashed++
            } else {
                cachedShas.add(sha)
            }
        }
        return unhashed + countMissing(cachedShas)
    }

    // Weekly: hash every file (reusing the cache when size/mtime are unchanged) and
    // count those whose current content is not in the repository.
    fun countUnsyncedOrChanged(files: List<File>): Int {
        val shas =
            files.map { file ->
                val cached = cache.peek(file.absolutePath)
                if (cached != null && cached.size == file.length() && cached.lastModified == file.lastModified()) {
                    cached.sha256
                } else {
                    fileSha256(file)
                }
            }
        return countMissing(shas)
    }

    private fun countMissing(sha256s: List<String>): Int {
        if (sha256s.isEmpty()) {
            return 0
        }
        return goBridge.checkFiles(sha256s).count { !it }
    }
}
