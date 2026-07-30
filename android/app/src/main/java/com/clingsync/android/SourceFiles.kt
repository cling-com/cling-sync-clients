package com.clingsync.android

import android.content.Context
import android.os.Environment
import java.io.File
import java.io.IOException

fun getSourceDirectory(settings: AppSettings): File = File(settings.sourceDirectory)

private val MEDIA_EXTENSIONS =
    setOf(
        "jpg", "jpeg", "png", "gif", "bmp", "webp", "heif", "heic",
        "mp4", "mkv", "avi", "mov", "3gp", "webm",
        "mp3", "m4a", "ogg", "wav", "flac", "aac",
    )

fun getSourceFiles(
    sourceDir: File,
    mediaOnly: Boolean = true,
): List<File> {
    if (!sourceDir.isDirectory) return emptyList()

    val files = mutableListOf<File>()

    fun walk(dir: File) {
        val entries = dir.list() ?: return
        for (name in entries) {
            if (name.startsWith(".")) continue
            val file = File(dir, name)
            if (file.isDirectory) {
                walk(file)
            } else if (!mediaOnly || name.substringAfterLast('.', "").lowercase() in MEDIA_EXTENSIONS) {
                files.add(file)
            }
        }
    }
    walk(sourceDir)

    // Read lastModified once per file for sorting (avoids repeated syscalls during sort).
    return files
        .map { it to it.lastModified() }
        .sortedByDescending { it.second }
        .map { it.first }
}

// Whether a complete backup of sourceDir requires "All files access". Scoped storage
// hides other apps' non-media files by omitting them from directory listings rather
// than failing them, so a scan cannot tell an empty folder from one whose files it
// may not see. The answer is therefore based on capability alone: any directory on a
// shared storage volume outside the app's own package directory may hold files that
// only "All files access" reveals. A missing directory never prompts: directories
// (unlike files) are not hidden by scoped storage, so it truly does not exist and
// no permission can change that.
fun needsAllFilesAccess(
    context: Context,
    sourceDir: File,
): Boolean {
    if (!sourceDir.isDirectory || Environment.isExternalStorageManager()) return false
    val dir = canonicalPath(sourceDir) + "/"
    // One app-files dir per shared storage volume (built-in, SD card), each of the
    // fixed shape <volume>/Android/data/<pkg>/files.
    for (appFilesDir in context.getExternalFilesDirs(null).filterNotNull()) {
        val appOwned = appFilesDir.parentFile!!
        val volume = appOwned.parentFile!!.parentFile!!.parentFile!!
        if (dir.startsWith(canonicalPath(appOwned) + "/")) return false
        if (dir.startsWith(canonicalPath(volume) + "/")) return true
    }
    return false
}

// Resolves symlinks like /sdcard so the prefix checks against the shared root work.
private fun canonicalPath(file: File): String =
    try {
        file.canonicalPath
    } catch (e: IOException) {
        file.absolutePath
    }

fun getFileFolder(
    file: File,
    sourceDir: File,
): String? {
    if (!file.absolutePath.startsWith(sourceDir.absolutePath)) return null
    val relative = file.relativeTo(sourceDir).path
    val parts = relative.split(File.separator)
    val folder = parts.dropLast(1).joinToString(File.separator.toString())
    return folder.ifEmpty { null }
}
