package com.clingsync.android.presentation

import android.app.Application
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.work.WorkManager
import androidx.work.testing.WorkManagerTestInitHelper
import com.clingsync.android.AppSettings
import com.clingsync.android.FileChecker
import com.clingsync.android.FileStatus
import com.clingsync.android.GoBridgeProvider
import com.clingsync.android.HttpGoBridge
import com.clingsync.android.PassphraseStore
import com.clingsync.android.RealBridge
import com.clingsync.android.RealRepo
import com.clingsync.android.RepositoryUriStore
import com.clingsync.android.SHA256Cache
import com.clingsync.android.SettingsManager
import com.clingsync.android.effect.RepositoryGateway
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.resetMain
import kotlinx.coroutines.test.setMain
import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config
import java.io.File

// The share reuses MainViewModel in share mode over a staged-files directory: it
// scans the files, marks already-present content Exists (the dedup fix), and
// auto-selects the new ones.
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(AndroidJUnit4::class)
@Config(sdk = [30])
class ShareModeTest {
    private val dispatcher = UnconfinedTestDispatcher()
    private lateinit var context: Context
    private lateinit var bridge: HttpGoBridge
    private lateinit var repo: RealRepo

    @Before
    fun setup() {
        Dispatchers.setMain(dispatcher)
        context = ApplicationProvider.getApplicationContext()
        context.getSharedPreferences("cling_sync_prefs", Context.MODE_PRIVATE).edit().clear().commit()
        context.getSharedPreferences("repository_uris", Context.MODE_PRIVATE).edit().clear().commit()
        context.getSharedPreferences("recent_share_targets", Context.MODE_PRIVATE).edit().clear().commit()
        PassphraseStore(context).deleteAll()
        SHA256Cache.resetForTesting()
        WorkManagerTestInitHelper.initializeTestWorkManager(context)

        bridge = RealBridge.install()
        repo = RealBridge.newRepo()
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
        GoBridgeProvider.reset()
        SHA256Cache.resetForTesting()
    }

    @Test
    fun scansStagedFilesMarksExistingAndAutoSelectsNew() {
        // Open the repo so the share connects without prompting, and configure settings.
        val encoded = bridge.encodeS3URI(repo.url, repo.passphrase, repo.s3KeyId, repo.s3Key)
        bridge.openRepository(encoded, repo.passphrase)
        val settings = AppSettings(hostUrl = repo.url, repoPathPrefix = "preset", author = "Tester")
        SettingsManager(context).saveSettings(settings)
        RepositoryUriStore(context).set(settings.repositoryID(), encoded)

        // Seed the repository with one file's content.
        val seedDir = File(context.cacheDir, "seed-${System.nanoTime()}").apply { mkdirs() }
        val seed = File(seedDir, "seed.txt").apply { writeText("already uploaded") }
        bridge.commit(listOf(bridge.uploadFile(seed.absolutePath, "preset/seed.txt")!!), "Tester", "seed")

        // Stage a duplicate (same content) and a brand-new file.
        val stagingDir = File(context.cacheDir, "shared_uploads/${System.nanoTime()}").apply { mkdirs() }
        val dup = File(stagingDir, "dup.txt").apply { writeText("already uploaded") }
        val fresh = File(stagingDir, "new.txt").apply { writeText("brand new content") }

        val viewModel = shareViewModel(stagingDir)
        viewModel.onStart()

        val state = viewModel.state.value
        assertTrue(state.isConnected)
        assertEquals(FileStatus.Exists, state.fileStatus[dup.absolutePath])
        assertEquals(FileStatus.New, state.fileStatus[fresh.absolutePath])
        // Auto-select picks the new file only; the already-present one is excluded.
        assertEquals(setOf(fresh.absolutePath), state.selectedPaths)
    }

    private fun shareViewModel(stagingDir: File): MainViewModel {
        val uriStore = RepositoryUriStore(context)
        return MainViewModel(
            application = context as Application,
            settingsManager = SettingsManager(context),
            passphraseStore = PassphraseStore(context),
            repositoryUriStore = uriStore,
            gateway = RepositoryGateway(bridge, uriStore, dispatcher),
            fileChecker = FileChecker(SHA256Cache.getInstance(context), dispatcher),
            workManager = WorkManager.getInstance(context),
            ioDispatcher = dispatcher,
            sourceDirOverride = stagingDir.absolutePath,
            shareMode = true,
        )
    }
}
