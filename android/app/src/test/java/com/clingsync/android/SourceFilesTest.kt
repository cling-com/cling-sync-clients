package com.clingsync.android

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class SourceFilesTest {
    @get:Rule
    val tmp = TemporaryFolder()

    private fun write(
        relativePath: String,
        content: String = "x",
    ): File {
        val file = File(tmp.root, relativePath)
        file.parentFile?.mkdirs()
        file.writeText(content)
        return file
    }

    @Test
    fun nonDirectoryReturnsEmpty() {
        assertTrue(getSourceFiles(File(tmp.root, "does-not-exist")).isEmpty())
        val file = write("plain.jpg")
        assertTrue(getSourceFiles(file).isEmpty())
    }

    @Test
    fun mediaOnlyKeepsMediaAndRecursesSkippingHidden() {
        write("photo.jpg")
        write("clip.mp4")
        write("song.MP3") // extension match is case-insensitive
        write("notes.txt")
        write("report.pdf")
        write(".hidden.jpg")
        write("vacation/sunset.jpg")
        write(".thumbnails/cache.jpg") // hidden directory is skipped entirely

        val names = getSourceFiles(tmp.root, mediaOnly = true).map { it.name }.toSet()

        assertEquals(setOf("photo.jpg", "clip.mp4", "song.MP3", "sunset.jpg"), names)
    }

    @Test
    fun mediaOnlyFalseIncludesAllNonHiddenFiles() {
        write("photo.jpg")
        write("notes.txt")
        write("report.pdf")
        write(".hidden")
        write("docs/manual.pdf")

        val names = getSourceFiles(tmp.root, mediaOnly = false).map { it.name }.toSet()

        assertEquals(setOf("photo.jpg", "notes.txt", "report.pdf", "manual.pdf"), names)
    }

    @Test
    fun filesAreSortedByMostRecentlyModifiedFirst() {
        val old = write("old.jpg")
        val mid = write("mid.jpg")
        val recent = write("recent.jpg")
        // Far-apart whole-second mtimes survive filesystems with second granularity.
        old.setLastModified(100_000_000)
        mid.setLastModified(200_000_000)
        recent.setLastModified(300_000_000)

        val ordered = getSourceFiles(tmp.root).map { it.name }

        assertEquals(listOf("recent.jpg", "mid.jpg", "old.jpg"), ordered)
    }

    @Test
    fun fileFolderIsNullForDirectChild() {
        val camera = File("/sdcard/DCIM/Camera")
        assertNull(getFileFolder(File("/sdcard/DCIM/Camera/photo.jpg"), camera))
    }

    @Test
    fun fileFolderReportsRelativeSubfolder() {
        val camera = File("/sdcard/DCIM/Camera")
        assertEquals("vacation", getFileFolder(File("/sdcard/DCIM/Camera/vacation/photo.jpg"), camera))
        assertEquals("2024/summer", getFileFolder(File("/sdcard/DCIM/Camera/2024/summer/photo.jpg"), camera))
    }

    @Test
    fun fileFolderHonorsCustomSource() {
        val custom = File("/sdcard/Documents/backup")
        assertNull(getFileFolder(File("/sdcard/Documents/backup/photo.jpg"), custom))
        assertEquals("photos/2024", getFileFolder(File("/sdcard/Documents/backup/photos/2024/photo.jpg"), custom))
    }

    @Test
    fun fileFolderIsNullWhenFileIsOutsideSource() {
        val camera = File("/sdcard/DCIM/Camera")
        assertNull(getFileFolder(File("/sdcard/Pictures/photo.jpg"), camera))
    }
}
