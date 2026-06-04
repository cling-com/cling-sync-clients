package com.clingsync.android

import org.json.JSONObject
import org.junit.Assume.assumeTrue
import java.net.HttpURLConnection
import java.net.URL

// A fresh, isolated repository provisioned on the execute server, with its own
// in-process S3 server.
data class RealRepo(
    val url: String,
    val passphrase: String,
    val s3KeyId: String,
    val s3Key: String,
    val controlUrl: String,
)

// Connects unit tests to the real Go bridge via the local execute server started
// by the Go driver (android/go TestAndroidUnit). When the server URL is absent
// (a plain `./gradlew test` run), bridge-backed tests are skipped via assumeTrue.
object RealBridge {
    private val serverUrl: String?
        get() = System.getProperty("clingsync.executeServerUrl")?.ifBlank { null }

    fun requireServer(): String {
        val url = serverUrl
        assumeTrue("execute server not running (run via ./build.sh android test unit)", url != null)
        return url!!
    }

    // Installs an HttpGoBridge as the process-wide bridge and returns it.
    fun install(): HttpGoBridge = HttpGoBridge(requireServer()).also { GoBridgeProvider.setInstance(it) }

    // Provisions a fresh isolated repository (+ S3 server) on the execute server.
    fun newRepo(fault: Boolean = false): RealRepo {
        val text = post("${requireServer()}/new-repo?fault=$fault")
        val json = JSONObject(text)
        return RealRepo(
            url = json.getString("url"),
            passphrase = json.getString("passphrase"),
            s3KeyId = json.getString("s3KeyId"),
            s3Key = json.getString("s3Key"),
            controlUrl = json.getString("controlUrl"),
        )
    }

    // Toggles fault injection on a repo's S3 server, e.g. "fail-writes?on=true".
    fun fault(
        repo: RealRepo,
        query: String,
    ) {
        post("${repo.controlUrl}/__test/$query")
    }

    private fun post(url: String): String {
        val conn =
            (URL(url).openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                connectTimeout = 10_000
                readTimeout = 30_000
            }
        check(conn.responseCode == 200) { "POST $url -> ${conn.responseCode}" }
        return conn.inputStream.use { it.readBytes().toString(Charsets.UTF_8) }
    }
}
