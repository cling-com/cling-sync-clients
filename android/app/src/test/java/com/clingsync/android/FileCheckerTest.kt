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
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import java.io.File

// Drives FileChecker against the REAL bridge + a freshly provisioned repository.
// "Already in repo" is set up by actually uploading + committing the file, so
// the Exists path is exercised end-to-end (no fake results).
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(AndroidJUnit4::class)
@Config(sdk = [30])
class FileCheckerTest {
    private val dispatcher = UnconfinedTestDispatcher()
    private lateinit var context: Context
    private lateinit var workDir: File
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

        workDir = File(context.cacheDir, "filechecker-test-${System.nanoTime()}").apply { mkdirs() }
    }

    @After
    fun tearDown() {
        workDir.deleteRecursively()
        SHA256Cache.resetForTesting()
        GoBridgeProvider.reset()
    }

    private fun write(
        name: String,
        content: String = name,
    ): File = File(workDir, name).apply { writeText(content) }

    private fun checker() = FileChecker(cache, dispatcher)

    // Uploads + commits a file so it is genuinely present in the repository.
    private fun seedIntoRepo(
        file: File,
        repoPath: String,
    ) {
        val entry = bridge.uploadFile(file.absolutePath, repoPath)!!
        bridge.commit(listOf(entry), "Tester", "seed")
    }

    @Test
    fun allFilesAreNewWhenRepositoryIsEmpty() =
        runTest(dispatcher) {
            val files = listOf(write("a.jpg"), write("b.jpg"), write("c.jpg"))

            val result = checker().checkFiles(files.map { it.absolutePath }).getOrThrow()

            assertEquals(3, result.processedCount)
            files.forEach { assertEquals(FileStatus.New, result.statuses[it.absolutePath]) }
        }

    @Test
    fun filesAlreadyInTheRepoReportTheirRepoPath() =
        runTest(dispatcher) {
            val a = write("a.jpg", "the-a-content")
            val b = write("b.jpg", "the-b-content")
            seedIntoRepo(a, "phone/a.jpg")

            val result = checker().checkFiles(listOf(a, b).map { it.absolutePath }).getOrThrow()

            assertEquals(FileStatus.Exists, result.statuses[a.absolutePath])
            assertEquals(FileStatus.New, result.statuses[b.absolutePath])
        }

    @Test
    fun missingLocalFileIsMarkedNew() =
        runTest(dispatcher) {
            val present = write("present.jpg")
            val missing = File(workDir, "missing.jpg")

            val result =
                checker().checkFiles(listOf(present.absolutePath, missing.absolutePath)).getOrThrow()

            assertEquals(2, result.processedCount)
            assertEquals(FileStatus.New, result.statuses[present.absolutePath])
            assertEquals(FileStatus.New, result.statuses[missing.absolutePath])
        }

    @Test
    fun computedHashesAreCachedAndPersisted() =
        runTest(dispatcher) {
            val file1 = write("top.jpg", "hello")
            val nested =
                File(workDir, "sub/nested.jpg").apply {
                    parentFile?.mkdirs()
                    writeText("world")
                }

            checker().checkFiles(listOf(file1.absolutePath, nested.absolutePath)).getOrThrow()

            val sha1 = cache.lookup(file1.absolutePath, file1.length(), file1.lastModified())
            val sha2 = cache.lookup(nested.absolutePath, nested.length(), nested.lastModified())
            assertNotNull(sha1)
            assertNotNull(sha2)

            SHA256Cache.resetForTesting()
            val reloaded = SHA256Cache.getInstance(context)
            assertEquals(sha1, reloaded.lookup(file1.absolutePath, file1.length(), file1.lastModified()))
            assertEquals(sha2, reloaded.lookup(nested.absolutePath, nested.length(), nested.lastModified()))
        }

    @Test
    fun progressCallbackReportsEachBatch() =
        runTest(dispatcher) {
            val files = listOf(write("a.jpg"), write("b.jpg"))
            val updates = mutableListOf<FileCheckUpdate>()

            checker().checkFiles(files.map { it.absolutePath }, onProgress = { updates.add(it) }).getOrThrow()

            assertEquals(1, updates.size)
            assertEquals(2, updates[0].processedCount)
            assertEquals(2, updates[0].totalFiles)
        }

    @Test
    fun aLargeFileListIsCheckedAcrossBatches() =
        runTest(dispatcher) {
            // More than MAX_BATCH_SIZE (100) forces the FileChecker to batch its
            // bridge calls; all files come back New against the empty repo.
            val files = (1..101).map { write("file_$it.jpg") }

            val result = checker().checkFiles(files.map { it.absolutePath }).getOrThrow()

            assertEquals(101, result.processedCount)
            files.forEach { assertEquals(FileStatus.New, result.statuses[it.absolutePath]) }
        }
}
