package com.clingsync.android.effect

import com.clingsync.android.AppSettings
import com.clingsync.android.IGoBridge
import com.clingsync.android.RepositoryUri
import com.clingsync.android.RepositoryUriStore
import com.clingsync.android.S3CredentialsResult
import kotlinx.coroutines.CoroutineDispatcher
import kotlinx.coroutines.withContext

// The one place a repository is opened. Encapsulates the cleartext-S3 fallback
// (prompt for credentials, encrypt them into the URI, persist, retry) and the
// resume-on-launch check. Constructor-injected so tests can drive it against the
// real bridge over the execute server.
class RepositoryGateway(
    private val bridge: IGoBridge,
    private val uriStore: RepositoryUriStore,
    private val dispatcher: CoroutineDispatcher,
) {
    // Opens the repository for [settings] using [passphrase]. When the host is a
    // cleartext S3 URL with no stored credentials, [askS3] is invoked to collect
    // them. The passphrase flows straight into the bridge and is never retained.
    suspend fun open(
        settings: AppSettings,
        passphrase: String,
        askS3: suspend () -> S3CredentialsResult,
    ) {
        val stored = uriStore.get(settings.repositoryID())
        if (stored != null) {
            withContext(dispatcher) { bridge.openRepository(stored, passphrase) }
            return
        }
        try {
            withContext(dispatcher) { bridge.openRepository(settings.hostUrl, passphrase) }
        } catch (e: Exception) {
            if (!RepositoryUri.isCleartextS3(settings.hostUrl)) {
                throw e
            }
            val creds = askS3()
            val encoded =
                withContext(dispatcher) {
                    bridge.encodeS3URI(
                        hostUrl = settings.hostUrl,
                        passphrase = passphrase,
                        accessKeyId = creds.accessKeyId,
                        accessKey = creds.accessKey,
                    )
                }
            // Open before persisting: a wrong passphrase must not leave behind an
            // encoded URI that would then be reused and lock the user out.
            withContext(dispatcher) { bridge.openRepository(encoded, passphrase) }
            uriStore.set(settings.repositoryID(), encoded)
        }
    }

    // Whether the repository is already open in the bridge (e.g. returning to the
    // app within the same process), so no passphrase is needed.
    suspend fun isAlreadyOpen(settings: AppSettings): Boolean {
        val uri = uriStore.get(settings.repositoryID()) ?: settings.hostUrl
        return withContext(dispatcher) {
            try {
                bridge.checkRepositoryOpen(uri)
            } catch (e: Exception) {
                false
            }
        }
    }
}
