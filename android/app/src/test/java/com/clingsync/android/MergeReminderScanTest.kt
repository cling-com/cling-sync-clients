package com.clingsync.android

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import java.io.File

// Drives MergeReminderScan against the REAL bridge: "backed up" means the file's
// content hash is in a freshly provisioned repository (seeded by uploading +
// committing), as answered by the bridge's checkFiles.
@RunWith(AndroidJUnit4::class)
@Config(sdk = [30])
class MergeReminderScanTest {
    private lateinit var context: Context
    private lateinit var dir: File
    private lateinit var cache: SHA256Cache
    private lateinit var bridge: HttpGoBridge

    @Before
    fun setup() {
        context = ApplicationProvider.getApplicationContext()
        SHA256Cache.resetForTesting()
        cache = SHA256Cache.getInstance(context)
        bridge = RealBridge.install()
        val repo = RealBridge.newRepo()
        val encoded = bridge.encodeS3URI(repo.url, repo.passphrase, repo.s3KeyId, repo.s3Key)
        bridge.openRepository(encoded, repo.passphrase)
        dir = File(context.cacheDir, "scan-${System.nanoTime()}").apply { mkdirs() }
    }

    @After
    fun tearDown() {
        dir.deleteRecursively()
        SHA256Cache.resetForTesting()
        GoBridgeProvider.reset()
    }

    private fun file(
        name: String,
        content: String = name,
    ): File = File(dir, name).apply { writeText(content) }

    private fun remember(file: File) {
        cache.store(file.absolutePath, file.length(), file.lastModified(), fileSha256(file))
    }

    // Uploads + commits a file so its content is genuinely in the repository.
    private fun backUp(file: File) {
        val entry = bridge.uploadFile(file.absolutePath, file.name)!!
        bridge.commit(listOf(entry), "Tester", "seed")
    }

    private fun scan() = MergeReminderScan(cache, bridge)

    @Test
    fun countUnsyncedCountsHashedFilesNotInRepo() {
        val backed = file("backed.jpg", "alpha")
        val pending = file("pending.jpg", "beta")
        remember(backed)
        remember(pending)
        backUp(backed)

        assertEquals(1, scan().countUnsynced(listOf(backed, pending)))
    }

    @Test
    fun countUnsyncedCountsUnhashedFilesAsNew() {
        // Never hashed -> no cached hash -> treated as new without a repo lookup.
        assertEquals(2, scan().countUnsynced(listOf(file("a.jpg"), file("b.jpg"))))
    }

    @Test
    fun countUnsyncedIsZeroWhenEverythingIsBackedUp() {
        val a = file("a.jpg", "alpha")
        remember(a)
        backUp(a)

        assertEquals(0, scan().countUnsynced(listOf(a)))
    }

    @Test
    fun countUnsyncedOrChangedDetectsNewAndChanged() {
        val unchanged = file("unchanged.jpg", "keep-me")
        val changed = file("changed.jpg", "before")
        val fresh = file("fresh.jpg", "brand-new")
        remember(unchanged)
        remember(changed)
        backUp(unchanged)
        backUp(changed)
        // Edit `changed` so its current content is no longer the committed one.
        changed.writeText("after-the-edit-with-different-bytes")

        assertEquals(2, scan().countUnsyncedOrChanged(listOf(unchanged, changed, fresh)))
    }

    @Test
    fun countUnsyncedOrChangedIgnoresTouchThatPreservesContent() {
        val a = file("a.jpg", "stable")
        remember(a)
        backUp(a)
        a.setLastModified(a.lastModified() + 60_000)

        assertEquals(0, scan().countUnsyncedOrChanged(listOf(a)))
    }
}
