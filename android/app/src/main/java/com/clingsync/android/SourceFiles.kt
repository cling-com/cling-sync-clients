package com.clingsync.android

import java.io.File

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
