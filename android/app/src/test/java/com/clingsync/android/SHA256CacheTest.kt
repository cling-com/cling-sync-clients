package com.clingsync.android

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.After
import org.junit.Assert.assertEquals
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
}
