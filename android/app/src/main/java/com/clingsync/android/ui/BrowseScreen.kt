package com.clingsync.android.ui

import android.annotation.SuppressLint
import android.content.ContentValues
import android.content.Context
import android.provider.MediaStore
import android.util.Log
import android.webkit.JavascriptInterface
import android.webkit.MimeTypeMap
import android.webkit.WebResourceRequest
import android.webkit.WebView
import android.webkit.WebViewClient
import android.widget.Toast
import androidx.activity.compose.BackHandler
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.ArrowBack
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.runtime.DisposableEffect
import androidx.compose.runtime.remember
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.unit.dp
import androidx.compose.ui.viewinterop.AndroidView
import com.clingsync.android.AppSettings
import com.clingsync.android.GoBrowse
import com.clingsync.android.RepositoryUriStore
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.util.UUID
import kotlin.concurrent.thread

// Full-screen browser for the repository content. There is no HTTP server:
// the page's JS calls the injected __clingAndroid object (adapted to the
// window.__cling contract by the browse module's app.js), which forwards
// every request to GoBrowse. Downloads are streamed to a cache file by Go and
// copied into MediaStore Downloads, so file bytes never cross the JS bridge.
@Composable
fun BrowseScreen(
    settings: AppSettings,
    // From the session cache; the click handler verified it exists, so a null
    // here only happens when the connection was lost in between.
    passphrase: String?,
    onClose: () -> Unit,
) {
    val context = LocalContext.current
    val session = remember { BrowseSession(context.applicationContext) }

    BackHandler(onBack = onClose)
    DisposableEffect(Unit) {
        onDispose { session.close() }
    }

    // Surface (rather than a bare Column) gives the header the proper
    // surface/onSurface pairing in both themes; without it the title renders
    // in the default content color on the window background.
    Surface(Modifier.fillMaxSize(), color = MaterialTheme.colorScheme.surface) {
        Column(Modifier.fillMaxSize()) {
            Spacer(Modifier.height(40.dp))
            Row(
                Modifier
                    .fillMaxWidth()
                    .padding(horizontal = 4.dp, vertical = 8.dp),
                verticalAlignment = Alignment.CenterVertically,
            ) {
                IconButton(onClick = onClose) {
                    Icon(Icons.AutoMirrored.Filled.ArrowBack, "Back")
                }
                Text("Browse", style = MaterialTheme.typography.titleLarge)
            }
            AndroidView(
                modifier = Modifier.fillMaxSize(),
                onRelease = { it.destroy() },
                factory = { ctx ->
                    session.createWebView(ctx).also {
                        if (passphrase != null) {
                            session.open(settings, passphrase)
                        } else {
                            session.showError("The connection was lost. Reconnect and try again.")
                        }
                    }
                },
            )
        }
    }
}

private const val BROWSE_TMP_DIR = "browse"

// Deletes all browse temp files: session snapshots and downloads. Only valid
// before any browse session is open, i.e. at process start.
fun removeBrowseTempFiles(context: Context) {
    File(context.cacheDir, BROWSE_TMP_DIR).deleteRecursively()
}

private class BrowseSession(private val context: Context) {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)

    // Never cancelled: a download in flight when the screen closes should
    // still finish (or report its failure) instead of dying silently.
    private val downloadScope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    // Guarded by `this`: an open finishing after close() must close its
    // session instead of storing it.
    @Volatile
    private var handle: Int? = null
    private var closed = false
    private var webView: WebView? = null

    @SuppressLint("SetJavaScriptEnabled")
    fun createWebView(ctx: Context): WebView {
        val webView = WebView(ctx)
        webView.settings.javaScriptEnabled = true
        webView.settings.allowFileAccess = false
        webView.settings.allowContentAccess = false
        // The JS interface is attached to every page the WebView loads, so
        // the only content it may ever show is what loadDataWithBaseURL
        // hands over. Every navigation is refused.
        webView.webViewClient =
            object : WebViewClient() {
                override fun shouldOverrideUrlLoading(
                    view: WebView,
                    request: WebResourceRequest,
                ) = true
            }
        webView.addJavascriptInterface(JsBridge(), "__clingAndroid")
        this.webView = webView
        return webView
    }

    fun open(
        settings: AppSettings,
        passphrase: String,
    ) {
        scope.launch {
            try {
                val uri = RepositoryUriStore(context).get(settings.repositoryID()) ?: settings.hostUrl
                // The JNI call is not interruptible, and withContext discards
                // the result of a block whose caller was cancelled meanwhile.
                // So the handle is handed over (or closed) inside the block.
                val opened =
                    withContext(Dispatchers.IO + NonCancellable) {
                        val newHandle =
                            GoBrowse.execute(
                                "open",
                                JSONObject()
                                    .put("repositoryUri", uri)
                                    .put("passphrase", passphrase)
                                    // The app stores the prefix like "/phone/"; the browse
                                    // session takes cling-sync's canonical form ("phone/").
                                    .put("pathPrefix", settings.repoPathPrefix.trim('/').let { if (it.isEmpty()) it else "$it/" })
                                    .put("tmpDir", browseTmpDir()),
                            ).getInt("handle")
                        synchronized(this@BrowseSession) {
                            if (closed) {
                                closeHandle(newHandle)
                                false
                            } else {
                                handle = newHandle
                                true
                            }
                        }
                    }
                if (!opened) {
                    return@launch
                }
                val page = withContext(Dispatchers.IO) { call("/") }
                webView?.loadDataWithBaseURL(null, page, "text/html", "utf-8", null)
            } catch (e: CancellationException) {
                throw e
            } catch (e: Exception) {
                showError(e.message ?: "Failed to open the repository.")
            }
        }
    }

    fun showError(message: String) {
        Log.w("BrowseSession", "Showing error page: $message")
        webView?.loadDataWithBaseURL(null, errorPage(message), "text/html", "utf-8", null)
    }

    // Closing is fire-and-forget on a plain thread: the scope is cancelled
    // right after, and the screen is already gone. Downloads run on their own
    // scope and are not cancelled; the Go side waits for in-flight streams.
    fun close() {
        val closingHandle =
            synchronized(this) {
                closed = true
                handle.also { handle = null }
            }
        scope.cancel()
        webView = null
        if (closingHandle != null) {
            closeHandle(closingHandle)
        }
    }

    private fun closeHandle(closingHandle: Int) {
        thread {
            runCatching { GoBrowse.execute("close", JSONObject().put("handle", closingHandle)) }
        }
    }

    private fun call(target: String): String {
        val currentHandle = handle ?: throw IOException("No open session")
        val result = GoBrowse.execute("call", JSONObject().put("handle", currentHandle).put("target", target))
        return result.optString("body", "")
    }

    private fun browseTmpDir(): String {
        val dir = File(context.cacheDir, BROWSE_TMP_DIR)
        dir.mkdirs()
        return dir.path
    }

    inner class JsBridge {
        // Runs on the WebView's dedicated background thread, so blocking on the
        // synchronous Go call only stalls the page's JS, never the UI thread.
        @JavascriptInterface
        fun request(url: String): String =
            try {
                JSONObject().put("body", call(url)).toString()
            } catch (e: Exception) {
                JSONObject().put("error", e.message ?: "Request failed").toString()
            }

        @JavascriptInterface
        fun download(path: String) {
            val currentHandle = handle
            if (currentHandle == null) {
                downloadScope.launch { toast("Download failed: the repository is closed") }
                return
            }
            downloadScope.launch {
                val name = path.substringAfterLast('/')
                try {
                    val dest = File(browseTmpDir(), "download-${UUID.randomUUID()}")
                    try {
                        GoBrowse.execute(
                            "download",
                            JSONObject().put("handle", currentHandle).put("path", path).put("destPath", dest.path),
                        )
                        saveToDownloads(context, dest, name)
                    } finally {
                        dest.delete()
                    }
                    toast("Saved $name to Downloads")
                } catch (e: Exception) {
                    toast("Download failed: ${e.message}")
                }
            }
        }
    }

    private suspend fun toast(message: String) {
        withContext(Dispatchers.Main) {
            Toast.makeText(context, message, Toast.LENGTH_LONG).show()
        }
    }
}

private fun saveToDownloads(
    context: Context,
    source: File,
    name: String,
) {
    val resolver = context.contentResolver
    val values =
        ContentValues().apply {
            put(MediaStore.Downloads.DISPLAY_NAME, name)
            put(
                MediaStore.Downloads.MIME_TYPE,
                MimeTypeMap.getSingleton().getMimeTypeFromExtension(name.substringAfterLast('.', "").lowercase())
                    ?: "application/octet-stream",
            )
            put(MediaStore.Downloads.IS_PENDING, 1)
        }
    val uri =
        resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values)
            ?: throw IOException("Failed to create download entry")
    try {
        val output = resolver.openOutputStream(uri) ?: throw IOException("Failed to open download for writing")
        output.use { out -> source.inputStream().use { it.copyTo(out) } }
        values.clear()
        values.put(MediaStore.Downloads.IS_PENDING, 0)
        resolver.update(uri, values, null, null)
    } catch (e: Exception) {
        // Never leave an invisible IS_PENDING row behind, it would squat on
        // the display name until the system purges it days later.
        resolver.delete(uri, null, null)
        throw e
    }
}

private fun errorPage(message: String): String {
    val escaped =
        message
            .replace("&", "&amp;")
            .replace("<", "&lt;")
            .replace(">", "&gt;")
    return "<!doctype html><html><body><p>$escaped</p></body></html>"
}
