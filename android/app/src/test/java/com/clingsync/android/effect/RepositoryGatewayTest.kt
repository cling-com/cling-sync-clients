package com.clingsync.android.effect

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import com.clingsync.android.AppSettings
import com.clingsync.android.HttpGoBridge
import com.clingsync.android.RealBridge
import com.clingsync.android.RealRepo
import com.clingsync.android.RepositoryUriStore
import com.clingsync.android.S3CredentialsResult
import kotlinx.coroutines.ExperimentalCoroutinesApi
import kotlinx.coroutines.test.UnconfinedTestDispatcher
import kotlinx.coroutines.test.runTest
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

// Drives the gateway against the REAL bridge + a freshly provisioned S3
// repository (no fake): cleartext-S3 fallback, store-after-open, and resume.
@OptIn(ExperimentalCoroutinesApi::class)
@RunWith(AndroidJUnit4::class)
@Config(sdk = [28])
class RepositoryGatewayTest {
    private val dispatcher = UnconfinedTestDispatcher()
    private lateinit var bridge: HttpGoBridge
    private lateinit var uriStore: RepositoryUriStore
    private lateinit var gateway: RepositoryGateway
    private lateinit var repo: RealRepo
    private lateinit var settings: AppSettings

    @Before
    fun setup() {
        val context = ApplicationProvider.getApplicationContext<Context>()
        context.getSharedPreferences("repository_uris", Context.MODE_PRIVATE).edit().clear().commit()
        bridge = RealBridge.install()
        uriStore = RepositoryUriStore(context)
        gateway = RepositoryGateway(bridge, uriStore, dispatcher)
        repo = RealBridge.newRepo()
        settings = AppSettings(hostUrl = repo.url, author = "Tester", sourceDirectory = "/sdcard/DCIM")
    }

    private fun creds() = S3CredentialsResult(repo.s3KeyId, repo.s3Key)

    @Test
    fun storedUriIsOpenedDirectlyWithoutPrompting() =
        runTest(dispatcher) {
            val encoded = bridge.encodeS3URI(repo.url, repo.passphrase, repo.s3KeyId, repo.s3Key)
            uriStore.set(settings.repositoryID(), encoded)
            var asked = false

            gateway.open(settings, repo.passphrase) {
                asked = true
                creds()
            }

            assertFalse("no S3 prompt when a URI is stored", asked)
            assertTrue(bridge.checkRepositoryOpen(encoded))
        }

    @Test
    fun cleartextHostPromptsEncodesPersistsAndRetries() =
        runTest(dispatcher) {
            var asked = false
            gateway.open(settings, repo.passphrase) {
                asked = true
                creds()
            }

            assertTrue(asked)
            val encoded = uriStore.get(settings.repositoryID())
            assertNotNull("the working URI is persisted", encoded)
            assertTrue(bridge.checkRepositoryOpen(encoded!!))
        }

    @Test
    fun aFailedOpenDoesNotPersistTheEncodedUri() =
        runTest(dispatcher) {
            var threw = false
            try {
                gateway.open(settings, "wrong-passphrase") { creds() }
            } catch (e: Exception) {
                threw = true
            }

            assertTrue("a wrong passphrase fails the open", threw)
            assertNull("a failed open must not poison the stored URI", uriStore.get(settings.repositoryID()))
        }

    @Test
    fun isAlreadyOpenReflectsTheBridge() =
        runTest(dispatcher) {
            assertFalse(gateway.isAlreadyOpen(settings))
            gateway.open(settings, repo.passphrase) { creds() }
            assertTrue(gateway.isAlreadyOpen(settings))
        }
}
