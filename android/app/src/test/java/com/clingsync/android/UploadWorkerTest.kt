package com.clingsync.android

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.work.ListenableWorker
import androidx.work.testing.TestListenableWorkerBuilder
import androidx.work.workDataOf
import kotlinx.coroutines.runBlocking
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import java.io.File
import java.security.MessageDigest

// Drives the real UploadWorker against the REAL bridge + a freshly provisioned
// S3 repository. Verification is by querying the actual repository (checkFiles)
// and the worker's own status/result output, not a fake.
@RunWith(AndroidJUnit4::class)
@Config(sdk = [28])
class UploadWorkerTest {
    private lateinit var context: Context
    private lateinit var sourceDir: File
    private lateinit var bridge: HttpGoBridge
    private lateinit var repo: RealRepo

    @Before
    fun setup() {
        context = ApplicationProvider.getApplicationContext()
        context.getSharedPreferences("cling_sync_prefs", Context.MODE_PRIVATE).edit().clear().commit()
        context.getSharedPreferences("repository_uris", Context.MODE_PRIVATE).edit().clear().commit()
        bridge = RealBridge.install()
        sourceDir = File(context.cacheDir, "upload-source-${System.nanoTime()}").apply { mkdirs() }
        repo = openAndConfigure(RealBridge.newRepo(), prefix = "/phone/")
    }

    @After
    fun tearDown() {
        sourceDir.deleteRecursively()
        GoBridgeProvider.reset()
    }

    // Opens the repo, persists its encoded URI, and saves matching settings so the
    // worker (which re-reads them) sees the repo as authenticated.
    private fun openAndConfigure(
        r: RealRepo,
        prefix: String,
        open: Boolean = true,
    ): RealRepo {
        val encoded = bridge.encodeS3URI(r.url, r.passphrase, r.s3KeyId, r.s3Key)
        if (open) {
            bridge.openRepository(encoded, r.passphrase)
        }
        val settings =
            AppSettings(
                hostUrl = r.url,
                repoPathPrefix = prefix,
                author = "Tester",
                sourceDirectory = sourceDir.absolutePath,
            )
        SettingsManager(context).saveSettings(settings)
        RepositoryUriStore(context).set(settings.repositoryID(), encoded)
        return r
    }

    private fun source(
        relativePath: String,
        content: String = relativePath,
    ): File =
        File(sourceDir, relativePath).apply {
            parentFile?.mkdirs()
            writeText(content)
        }

    private fun sha256(file: File): String {
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(8192)
            var read: Int
            while (input.read(buffer).also { read = it } > 0) digest.update(buffer, 0, read)
        }
        return digest.digest().joinToString("") { "%02x".format(it) }
    }

    private fun runWorker(
        files: List<File>,
        author: String = "Tester",
        includeFilePaths: Boolean = true,
        includeAuthor: Boolean = true,
    ): ListenableWorker.Result {
        val data = mutableMapOf<String, Any>()
        if (includeFilePaths) {
            val pathsFile = File(context.cacheDir, "paths-${System.nanoTime()}.txt")
            pathsFile.writeText(files.joinToString("\n") { it.absolutePath })
            data[UploadWorker.KEY_FILE_PATHS_FILE] = pathsFile.absolutePath
        }
        if (includeAuthor) data[UploadWorker.KEY_AUTHOR] = author
        val worker =
            TestListenableWorkerBuilder<UploadWorker>(context)
                .setInputData(workDataOf(*data.map { it.key to it.value }.toTypedArray()))
                .build()
        return runBlocking { worker.doWork() }
    }

    private fun resultStatuses(result: ListenableWorker.Result): Map<String, String> {
        val out = (result as ListenableWorker.Result.Success).outputData
        val json = JSONObject(File(out.getString("result_file")!!).readText())
        return json.keys().asSequence().associateWith { json.getString(it) }
    }

    @Test
    fun uploadsAllFilesToTheirPrefixedPaths() {
        val a = source("a.jpg")
        val b = source("b.jpg")

        val result = runWorker(listOf(a, b))

        assertTrue(result is ListenableWorker.Result.Success)
        // The files are genuinely in the repository at the prefixed paths.
        assertEquals(
            listOf("phone/a.jpg", "phone/b.jpg"),
            bridge.checkFiles(listOf(sha256(a), sha256(b))),
        )
    }

    @Test
    fun repoPathPreservesSubfolders() {
        val nested = source("vacation/sunset.jpg")
        openAndConfigure(repo, prefix = "/backup/")

        runWorker(listOf(nested))

        assertEquals(listOf("backup/vacation/sunset.jpg"), bridge.checkFiles(listOf(sha256(nested))))
    }

    @Test
    fun emptyPrefixUploadsAtRoot() {
        val a = source("a.jpg")
        openAndConfigure(repo, prefix = "")

        runWorker(listOf(a))

        assertEquals(listOf("a.jpg"), bridge.checkFiles(listOf(sha256(a))))
    }

    @Test
    fun alreadyPresentFilesAreSkippedNotReuploaded() {
        val a = source("a.jpg")
        val b = source("b.jpg")
        // Seed 'a' at the path the worker will use, so the bridge skips it.
        bridge.commit(listOf(bridge.uploadFile(a.absolutePath, "phone/a.jpg")!!), "Tester", "seed")

        val result = runWorker(listOf(a, b))

        val statuses = resultStatuses(result)
        assertEquals("skipped", statuses[a.absolutePath])
        assertEquals("committing", statuses[b.absolutePath])
        assertEquals(listOf("phone/a.jpg", "phone/b.jpg"), bridge.checkFiles(listOf(sha256(a), sha256(b))))
    }

    @Test
    fun allFilesSkippedProducesNoCommit() {
        val a = source("a.jpg")
        bridge.commit(listOf(bridge.uploadFile(a.absolutePath, "phone/a.jpg")!!), "Tester", "seed")

        val result = runWorker(listOf(a))

        assertTrue(result is ListenableWorker.Result.Success)
        // No new revision entries -> the worker reports an empty revision id.
        assertEquals("", (result as ListenableWorker.Result.Success).outputData.getString(UploadWorker.KEY_REVISION_ID))
    }

    @Test
    fun failsWhenRepositoryNotOpen() {
        // A second repo whose URI is stored but never opened: the worker's
        // checkRepositoryOpen sees the (still-open) first repo's URL mismatch.
        openAndConfigure(RealBridge.newRepo(), prefix = "/phone/", open = false)
        val a = source("a.jpg")

        val result = runWorker(listOf(a))

        assertTrue(result is ListenableWorker.Result.Failure)
        assertTrue(
            (result as ListenableWorker.Result.Failure).outputData.getString("error")!!.contains("not authenticated"),
        )
    }

    @Test
    fun failsWhenFilePathsInputMissing() {
        val result = runWorker(emptyList(), includeFilePaths = false)
        assertTrue(result is ListenableWorker.Result.Failure)
    }

    @Test
    fun failsWhenAuthorInputMissing() {
        val result = runWorker(listOf(source("a.jpg")), includeAuthor = false)
        assertTrue(result is ListenableWorker.Result.Failure)
    }

    @Test
    fun uploadFailureIsReportedAsFailure() {
        val faultRepo = RealBridge.newRepo(fault = true)
        openAndConfigure(faultRepo, prefix = "/phone/")
        RealBridge.fault(faultRepo, "fail-writes?on=true")

        val result = runWorker(listOf(source("a.jpg")))

        RealBridge.fault(faultRepo, "reset")
        assertTrue(result is ListenableWorker.Result.Failure)
        assertFalse((result as ListenableWorker.Result.Failure).outputData.getString("error").isNullOrBlank())
    }
}
