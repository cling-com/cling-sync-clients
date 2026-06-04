package com.clingsync.android

import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import java.io.File
import java.security.MessageDigest

// Proves the whole loop end-to-end against the REAL bridge: open an S3
// repository, scan, upload, commit, and re-scan, all via bridge.Execute running
// in the host-side execute server.
@RunWith(AndroidJUnit4::class)
@Config(sdk = [28])
class RealBridgeSmokeTest {
    private lateinit var bridge: HttpGoBridge

    @Before
    fun setup() {
        bridge = RealBridge.install()
    }

    @Test
    fun openUploadCommitAndRescan() {
        val repo = RealBridge.newRepo()
        val encoded = bridge.encodeS3URI(repo.url, repo.passphrase, repo.s3KeyId, repo.s3Key)

        bridge.openRepository(encoded, repo.passphrase)
        assertTrue(bridge.checkRepositoryOpen(encoded))

        val file = File.createTempFile("smoke", ".jpg").apply { writeText("hello smoke") }
        val sha = sha256Hex(file)

        // Before upload: the file is new (empty repo path).
        assertEquals(listOf(""), bridge.checkFiles(listOf(sha)))

        val entry = bridge.uploadFile(file.absolutePath, "smoke/${file.name}")
        assertNotNull("a new file must produce a revision entry", entry)
        val revision = bridge.commit(listOf(entry!!), "Tester", "smoke commit")
        assertTrue(revision.isNotEmpty())

        // After commit: the same content is found at its repo path.
        assertEquals(listOf("smoke/${file.name}"), bridge.checkFiles(listOf(sha)))

        // Re-uploading the identical file is skipped by the real bridge.
        assertEquals(null, bridge.uploadFile(file.absolutePath, "smoke/${file.name}"))
    }

    private fun sha256Hex(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(8192)
            var read: Int
            while (input.read(buffer).also { read = it } > 0) {
                digest.update(buffer, 0, read)
            }
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }
}
