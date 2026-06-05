package com.clingsync.android

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
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
    fun storeAndLookup() {
        val cache = SHA256Cache.getInstance(context)
        assertNull(cache.lookup("/sdcard/DCIM/Camera/photo.jpg", 1000, 12345))

        cache.store("/sdcard/DCIM/Camera/photo.jpg", 1000, 12345, "abc123")
        assertEquals("abc123", cache.lookup("/sdcard/DCIM/Camera/photo.jpg", 1000, 12345))
    }

    @Test
    fun lookupInvalidatedBySizeChange() {
        val cache = SHA256Cache.getInstance(context)
        cache.store("/sdcard/DCIM/Camera/photo.jpg", 1000, 12345, "abc123")
        assertNull(cache.lookup("/sdcard/DCIM/Camera/photo.jpg", 2000, 12345))
    }

    @Test
    fun lookupInvalidatedByMtimeChange() {
        val cache = SHA256Cache.getInstance(context)
        cache.store("/sdcard/DCIM/Camera/photo.jpg", 1000, 12345, "abc123")
        assertNull(cache.lookup("/sdcard/DCIM/Camera/photo.jpg", 1000, 99999))
    }

    @Test
    fun persistsToDisk() {
        val cache1 = SHA256Cache.getInstance(context)
        cache1.store("photo.jpg", 1000, 12345, "abc123")
        cache1.save()

        // Create a new instance by resetting the singleton.
        SHA256Cache.resetForTesting()
        val cache2 = SHA256Cache.getInstance(context)

        assertEquals("abc123", cache2.lookup("photo.jpg", 1000, 12345))
    }

    @Test
    fun keysDistinguishSameNameInDifferentPaths() {
        val cache = SHA256Cache.getInstance(context)
        cache.store("/sdcard/DCIM/Camera/photo.jpg", 1000, 12345, "hash1")
        cache.store("/sdcard/DCIM/Camera/subfolder/photo.jpg", 2000, 67890, "hash2")

        assertEquals("hash1", cache.lookup("/sdcard/DCIM/Camera/photo.jpg", 1000, 12345))
        assertEquals("hash2", cache.lookup("/sdcard/DCIM/Camera/subfolder/photo.jpg", 2000, 67890))
    }

    // The reminder worker reads (peek) on a background thread while a foreground
    // scan stores and saves on another. Hammer all three at once and require that
    // nothing throws and no stored entry is lost.
    @Test
    fun concurrentReadsWritesAndSavesAreSafe() {
        val cache = SHA256Cache.getInstance(context)
        val errors = java.util.Collections.synchronizedList(mutableListOf<Throwable>())
        val writerCount = 4
        val perWriter = 250

        val writers =
            (0 until writerCount).map { t ->
                Thread {
                    try {
                        repeat(perWriter) { i -> cache.store("/p/$t/$i", i.toLong(), i.toLong(), "h$t-$i") }
                    } catch (e: Throwable) {
                        errors.add(e)
                    }
                }
            }
        val readers =
            (0 until 2).map {
                Thread {
                    try {
                        repeat(perWriter) { i -> cache.peek("/p/0/$i") }
                    } catch (e: Throwable) {
                        errors.add(e)
                    }
                }
            }
        val saver =
            Thread {
                try {
                    repeat(30) { cache.save() }
                } catch (e: Throwable) {
                    errors.add(e)
                }
            }

        val all = writers + readers + saver
        all.forEach { it.start() }
        all.forEach { it.join() }

        assertTrue(errors.toString(), errors.isEmpty())
        for (t in 0 until writerCount) {
            for (i in 0 until perWriter) {
                assertNotNull(cache.peek("/p/$t/$i"))
            }
        }
    }
}
