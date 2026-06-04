package com.clingsync.android

import org.json.JSONObject
import java.net.HttpURLConnection
import java.net.URL

// Reuses the REAL GoBridge translation but routes the raw command/JSON to a
// host-side execute server, which calls the real bridge.Execute against an
// in-process repository. There is no fake bridge: the translation AND the Go
// logic are the production ones.
class HttpGoBridge(private val serverUrl: String) : GoBridge() {
    override fun rawExecute(
        command: String,
        params: String,
    ): String {
        val body =
            JSONObject()
                .apply {
                    put("command", command)
                    put("params", params)
                }.toString()
        val conn =
            (URL("$serverUrl/execute").openConnection() as HttpURLConnection).apply {
                requestMethod = "POST"
                doOutput = true
                connectTimeout = 10_000
                readTimeout = 60_000
                setRequestProperty("Content-Type", "application/json")
            }
        conn.outputStream.use { it.write(body.toByteArray()) }
        return conn.inputStream.use { it.readBytes().toString(Charsets.UTF_8) }
    }
}
