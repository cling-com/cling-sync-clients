package com.clingsync.android

import android.app.Notification
import android.app.NotificationManager
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.work.ListenableWorker
import androidx.work.WorkManager
import androidx.work.testing.TestListenableWorkerBuilder
import androidx.work.testing.WorkManagerTestInitHelper
import androidx.work.workDataOf
import kotlinx.coroutines.runBlocking
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import java.io.File
import java.util.concurrent.TimeUnit

// Drives the real MergeReminderWorker against the REAL bridge. "Backed up" means a
// file's content is committed to a freshly provisioned repository; the worker's
// checkFiles queries the bridge's persisted hash index.
@RunWith(AndroidJUnit4::class)
@Config(sdk = [28])
class MergeReminderWorkerTest {
    private lateinit var context: Context
    private lateinit var sourceDir: File
    private lateinit var bridge: HttpGoBridge

    @Before
    fun setup() {
        context = ApplicationProvider.getApplicationContext()
        WorkManagerTestInitHelper.initializeTestWorkManager(context)
        context.getSharedPreferences("cling_sync_prefs", Context.MODE_PRIVATE).edit().clear().commit()
        context.getSharedPreferences("merge_reminder_prefs", Context.MODE_PRIVATE).edit().clear().commit()
        File(context.filesDir, "sha256cache.json").delete()
        SHA256Cache.resetForTesting()
        bridge = RealBridge.install()
        // Init before opening the repo so the bridge's hash index uses one cache dir.
        GoBridgeProvider.initialize(context)
        val repo = RealBridge.newRepo()
        val encoded = bridge.encodeS3URI(repo.url, repo.passphrase, repo.s3KeyId, repo.s3Key)
        bridge.openRepository(encoded, repo.passphrase)
        sourceDir = File(context.cacheDir, "reminder-source-${System.nanoTime()}").apply { mkdirs() }
        notificationManager().cancelAll()
    }

    @After
    fun tearDown() {
        sourceDir.deleteRecursively()
        SHA256Cache.resetForTesting()
        File(context.filesDir, "sha256cache.json").delete()
        GoBridgeProvider.reset()
    }

    private fun notificationManager(): NotificationManager = context.getSystemService(Context.NOTIFICATION_SERVICE) as NotificationManager

    private fun configure() {
        SettingsManager(context).saveSettings(
            AppSettings(
                hostUrl = "s3+https://bucket.example.com",
                author = "Tester",
                sourceDirectory = sourceDir.absolutePath,
                mediaOnly = true,
            ),
        )
    }

    private fun source(
        name: String,
        content: String = name,
    ): File = File(sourceDir, name).apply { writeText(content) }

    private fun remember(file: File) {
        SHA256Cache.getInstance(context).store(file.absolutePath, file.length(), file.lastModified(), fileSha256(file))
    }

    // Hashes the file and commits its content to the repository.
    private fun backUp(file: File) {
        remember(file)
        val entry = bridge.uploadFile(file.absolutePath, file.name)!!
        bridge.commit(listOf(entry), "Tester", "seed")
    }

    private fun lastWeekly(millisAgo: Long) {
        MergeReminderState(context).setLastWeeklyScan(System.currentTimeMillis() - millisAgo)
    }

    private fun runWorker(forceMode: String? = null): ListenableWorker.Result {
        val builder = TestListenableWorkerBuilder<MergeReminderWorker>(context)
        if (forceMode != null) {
            builder.setInputData(workDataOf(MergeReminderWorker.KEY_FORCE_MODE to forceMode))
        }
        return runBlocking { builder.build().doWork() }
    }

    private fun postedTexts(): List<String> =
        notificationManager().activeNotifications.map {
            it.notification.extras.getCharSequence(Notification.EXTRA_TEXT)?.toString().orEmpty()
        }

    @Test
    fun dailyNotifiesForFilesNotBackedUp() {
        configure()
        lastWeekly(0)
        remember(source("photo1.jpg"))
        remember(source("photo2.jpg"))

        val result = runWorker()

        assertTrue(result is ListenableWorker.Result.Success)
        val texts = postedTexts()
        assertEquals(1, texts.size)
        assertTrue(texts[0], texts[0].contains("2 new items"))
    }

    @Test
    fun dailyDoesNotNotifyWhenAllBackedUp() {
        configure()
        lastWeekly(0)
        backUp(source("photo.jpg"))

        runWorker()

        assertEquals(0, notificationManager().activeNotifications.size)
    }

    @Test
    fun dailyIgnoresChangesToBackedUpFiles() {
        configure()
        lastWeekly(0)
        val a = source("photo.jpg", "original")
        backUp(a)
        a.writeText("edited-with-different-length")

        // Daily uses the cached hash (still in the repo); the edit is weekly's job.
        runWorker()

        assertEquals(0, notificationManager().activeNotifications.size)
    }

    @Test
    fun weeklyNotifiesForChangedFiles() {
        configure()
        lastWeekly(TimeUnit.DAYS.toMillis(8))
        val a = source("photo.jpg", "original")
        backUp(a)
        a.writeText("edited-with-clearly-different-bytes")

        val started = System.currentTimeMillis()
        val result = runWorker()

        assertTrue(result is ListenableWorker.Result.Success)
        val texts = postedTexts()
        assertEquals(1, texts.size)
        assertTrue(texts[0], texts[0].contains("1 new or changed item"))
        assertTrue(MergeReminderState(context).lastWeeklyScan() >= started)
    }

    @Test
    fun doesNotNotifyWhenNotConfigured() {
        source("photo.jpg")

        val result = runWorker()

        assertTrue(result is ListenableWorker.Result.Success)
        assertEquals(0, notificationManager().activeNotifications.size)
    }

    @Test
    fun reschedulesNextRun() {
        configure()

        runWorker()

        val infos =
            WorkManager.getInstance(context)
                .getWorkInfosForUniqueWork(MergeReminderScheduler.WORK_NAME)
                .get()
        assertEquals(1, infos.size)
    }

    @Test
    fun forcedWeeklyTakesWeeklyPathEvenWhenNotDue() {
        configure()
        lastWeekly(0)
        val a = source("photo.jpg", "original")
        backUp(a)
        a.writeText("edited-with-clearly-different-bytes")

        runWorker(MergeReminderWorker.MODE_WEEKLY)

        val texts = postedTexts()
        assertEquals(1, texts.size)
        assertTrue(texts[0], texts[0].contains("1 new or changed item"))
    }

    @Test
    fun forcedRunDoesNotTouchTheRealSchedule() {
        configure()

        runWorker(MergeReminderWorker.MODE_DAILY)

        val infos =
            WorkManager.getInstance(context)
                .getWorkInfosForUniqueWork(MergeReminderScheduler.WORK_NAME)
                .get()
        assertEquals(0, infos.size)
    }
}
