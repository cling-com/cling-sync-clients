package com.clingsync.android.presentation

import android.app.Application
import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import androidx.work.WorkManager
import androidx.work.testing.WorkManagerTestInitHelper
import com.clingsync.android.AppSettings
import com.clingsync.android.FileChecker
import com.clingsync.android.GoBridgeProvider
import com.clingsync.android.HttpGoBridge
import com.clingsync.android.PassphraseResult
import com.clingsync.android.PassphraseStore
import com.clingsync.android.RealBridge
import com.clingsync.android.RealRepo
import com.clingsync.android.RepositoryUriStore
import com.clingsync.android.S3CredentialsResult
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
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

// Drives the ViewModel's connect orchestration against the REAL bridge + a fresh
// S3 repository: passphrase -> S3 -> real open, and the failure paths.
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(AndroidJUnit4::class)
@Config(sdk = [30])
class MainViewModelTest {
    private val dispatcher = UnconfinedTestDispatcher()
    private lateinit var context: Context
    private lateinit var bridge: HttpGoBridge
    private lateinit var uriStore: RepositoryUriStore
    private lateinit var repo: RealRepo
    private lateinit var viewModel: MainViewModel

    @Before
    fun setup() {
        Dispatchers.setMain(dispatcher)
        context = ApplicationProvider.getApplicationContext()
        context.getSharedPreferences("cling_sync_prefs", Context.MODE_PRIVATE).edit().clear().commit()
        context.getSharedPreferences("repository_uris", Context.MODE_PRIVATE).edit().clear().commit()
        PassphraseStore(context).deleteAll()
        SHA256Cache.resetForTesting()

        bridge = RealBridge.install()
        repo = RealBridge.newRepo()
        SettingsManager(context).saveSettings(
            AppSettings(hostUrl = repo.url, author = "Tester", sourceDirectory = "/sdcard/DCIM"),
        )
        WorkManagerTestInitHelper.initializeTestWorkManager(context)

        val application = context as Application
        uriStore = RepositoryUriStore(context)
        viewModel =
            MainViewModel(
                application = application,
                settingsManager = SettingsManager(context),
                passphraseStore = PassphraseStore(context),
                repositoryUriStore = uriStore,
                gateway = RepositoryGateway(bridge, uriStore, dispatcher),
                fileChecker = FileChecker(SHA256Cache.getInstance(context), dispatcher),
                workManager = WorkManager.getInstance(context),
                ioDispatcher = dispatcher,
            )
    }

    @After
    fun tearDown() {
        Dispatchers.resetMain()
        GoBridgeProvider.reset()
        SHA256Cache.resetForTesting()
    }

    private fun s3Creds() = S3CredentialsResult(repo.s3KeyId, repo.s3Key)

    @Test
    fun initialStateComesFromSavedSettings() {
        assertEquals(repo.url, viewModel.state.value.settings.hostUrl)
        assertFalse(viewModel.state.value.isConnected)
    }

    @Test
    fun selectionDispatchesThroughTheReducer() {
        viewModel.dispatch(MainEvent.FileSelectionChanged("/sdcard/DCIM/a.jpg", true))
        assertEquals(setOf("/sdcard/DCIM/a.jpg"), viewModel.state.value.selectedPaths)
    }

    @Test
    fun connectFlowProgressesPassphraseThenS3ThenConnected() {
        viewModel.dispatch(MainEvent.ConnectClicked)
        assertTrue(viewModel.state.value.overlay is Overlay.Passphrase)

        viewModel.dispatch(MainEvent.PassphraseEntered(PassphraseResult(repo.passphrase, saveToKeychain = false)))
        // Cleartext host: the real bridge rejects it, so the S3 prompt appears.
        assertEquals(Overlay.S3Credentials, viewModel.state.value.overlay)

        viewModel.dispatch(MainEvent.S3CredentialsEntered(s3Creds()))
        // The real bridge opens the repository -> connected, URI persisted.
        assertTrue(viewModel.state.value.isConnected)
        assertEquals(Overlay.None, viewModel.state.value.overlay)
        assertNotNull(uriStore.get(viewModel.state.value.settings.repositoryID()))
    }

    @Test
    fun connectWithWrongPassphraseShowsConnectionError() {
        viewModel.dispatch(MainEvent.ConnectClicked)
        viewModel.dispatch(MainEvent.PassphraseEntered(PassphraseResult("wrong-passphrase", saveToKeychain = false)))
        viewModel.dispatch(MainEvent.S3CredentialsEntered(s3Creds()))

        val overlay = viewModel.state.value.overlay
        assertTrue(overlay is Overlay.Error)
        assertEquals("Connection Error", (overlay as Overlay.Error).title)
        assertFalse(viewModel.state.value.isConnected)
    }

    @Test
    fun cancellingTheS3PromptDeclinesWithoutAnError() {
        viewModel.dispatch(MainEvent.ConnectClicked)
        viewModel.dispatch(MainEvent.PassphraseEntered(PassphraseResult(repo.passphrase, saveToKeychain = false)))
        assertEquals(Overlay.S3Credentials, viewModel.state.value.overlay)

        viewModel.dispatch(MainEvent.S3CredentialsDismissed)

        assertFalse(viewModel.state.value.overlay is Overlay.Error)
        assertFalse(viewModel.state.value.isConnected)
        assertFalse(viewModel.state.value.isConnecting)
    }
}
