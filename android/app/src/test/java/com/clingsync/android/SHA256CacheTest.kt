package com.clingsync.android

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import java.io.File

@RunWith(AndroidJUnit4::class)
@Config(sdk = [28])
class SHA256CacheTest {
    private lateinit var context: Context
    private lateinit var cacheFile: File

    @Before
    fun setup() {
        context = ApplicationProvider.getApplicationContext()
        cacheFile = File(context.filesDir, "sha256cache.json")
        cacheFile.delete()
        // Reset the singleton so each test starts fresh.
        SHA256Cache.resetForTesting()
    }

    @After
    fun tearDown() {
        cacheFile.delete()
        SHA256Cache.resetForTesting()
    }

    @Test
    fun testStoreAndLookup() {
        val cache = SHA256Cache.getInstance(context)
        assertNull(cache.lookup("/sdcard/DCIM/Camera/photo.jpg", 1000, 12345))

        cache.store("/sdcard/DCIM/Camera/photo.jpg", 1000, 12345, "abc123")
        assertEquals("abc123", cache.lookup("/sdcard/DCIM/Camera/photo.jpg", 1000, 12345))
    }

    @Test
    fun testInvalidatedBySizeChange() {
        val cache = SHA256Cache.getInstance(context)
        cache.store("/sdcard/DCIM/Camera/photo.jpg", 1000, 12345, "abc123")
        assertNull(cache.lookup("/sdcard/DCIM/Camera/photo.jpg", 2000, 12345))
    }

    @Test
    fun testInvalidatedByMtimeChange() {
        val cache = SHA256Cache.getInstance(context)
        cache.store("/sdcard/DCIM/Camera/photo.jpg", 1000, 12345, "abc123")
        assertNull(cache.lookup("/sdcard/DCIM/Camera/photo.jpg", 1000, 99999))
    }

    @Test
    fun testPersistsToDisk() {
        val cache1 = SHA256Cache.getInstance(context)
        cache1.store("photo.jpg", 1000, 12345, "abc123")
        cache1.save()

        // Create a new instance by resetting the singleton.
        SHA256Cache.resetForTesting()
        val cache2 = SHA256Cache.getInstance(context)

        assertEquals("abc123", cache2.lookup("photo.jpg", 1000, 12345))
    }

    @Test
    fun testSameNameDifferentPaths() {
        val cache = SHA256Cache.getInstance(context)
        cache.store("/sdcard/DCIM/Camera/photo.jpg", 1000, 12345, "hash1")
        cache.store("/sdcard/DCIM/Camera/subfolder/photo.jpg", 2000, 67890, "hash2")

        assertEquals("hash1", cache.lookup("/sdcard/DCIM/Camera/photo.jpg", 1000, 12345))
        assertEquals("hash2", cache.lookup("/sdcard/DCIM/Camera/subfolder/photo.jpg", 2000, 67890))
    }

    @OptIn(ExperimentalCoroutinesApi::class)
    @Test
    fun testFileCheckerCachesAndPersists() =
        runTest(UnconfinedTestDispatcher()) {
            val mockBridge = MockGoBridge()
            mockBridge.isOpen = true
            GoBridgeProvider.setInstance(mockBridge)

            val cache = SHA256Cache.getInstance(context)
            val checker = FileChecker(cache, UnconfinedTestDispatcher())

            // Create test files in a subfolder.
            val dir = File(context.cacheDir, "testfiles")
            val subDir = File(dir, "subfolder")
            subDir.mkdirs()
            val file1 = File(dir, "test.jpg").apply { writeText("hello") }
            val file2 = File(subDir, "nested.jpg").apply { writeText("world") }

            // First check: computes SHA256 for both files.
            checker.checkFiles(listOf(file1.absolutePath, file2.absolutePath))

            val sha1 = cache.lookup(file1.absolutePath, file1.length(), file1.lastModified())
            val sha2 = cache.lookup(file2.absolutePath, file2.length(), file2.lastModified())
            assertNotNull("SHA256 should be cached for top-level file", sha1)
            assertNotNull("SHA256 should be cached for nested file", sha2)

            // Verify cache persists to disk (saved by finally block).
            SHA256Cache.resetForTesting()
            val cache2 = SHA256Cache.getInstance(context)
            assertEquals(sha1, cache2.lookup(file1.absolutePath, file1.length(), file1.lastModified()))
            assertEquals(sha2, cache2.lookup(file2.absolutePath, file2.length(), file2.lastModified()))

            // Clean up.
            file1.delete()
            file2.delete()
            subDir.delete()
            dir.delete()
        }

    @Test
    fun testGetFileFolder() {
        val camera = File("/sdcard/DCIM/Camera")

        // Direct file in source → no folder header.
        assertNull(getFileFolder(File("/sdcard/DCIM/Camera/photo.jpg"), camera))

        // File in subfolder → show subfolder.
        assertEquals("vacation", getFileFolder(File("/sdcard/DCIM/Camera/vacation/photo.jpg"), camera))
        assertEquals("2024/summer", getFileFolder(File("/sdcard/DCIM/Camera/2024/summer/photo.jpg"), camera))
    }

    @Test
    fun testGetFileFolderWithCustomSource() {
        val customDir = File("/sdcard/Documents/backup")

        assertNull(getFileFolder(File("/sdcard/Documents/backup/photo.jpg"), customDir))
        assertEquals("photos", getFileFolder(File("/sdcard/Documents/backup/photos/photo.jpg"), customDir))
        assertEquals(
            "photos/2024",
            getFileFolder(File("/sdcard/Documents/backup/photos/2024/photo.jpg"), customDir),
        )
    }

    @Test
    fun testGetSourceFiles() {
        val dir = File(context.cacheDir, "testSource")
        val subDir = File(dir, "subfolder")
        subDir.mkdirs()
        val file1 = File(dir, "a.jpg").apply { writeText("a") }
        val file2 = File(subDir, "b.jpg").apply { writeText("b") }
        val hidden = File(dir, ".hidden").apply { writeText("h") }

        val files = getSourceFiles(dir)
        assertEquals(2, files.size)
        assertEquals(setOf("a.jpg", "b.jpg"), files.map { it.name }.toSet())

        hidden.delete()
        file1.delete()
        file2.delete()
        subDir.delete()
        dir.delete()
    }
}
