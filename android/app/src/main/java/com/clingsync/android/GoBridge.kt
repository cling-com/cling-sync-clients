package com.clingsync.android

import org.json.JSONObject

open class GoBridge : IGoBridge {
    companion object {
        init {
            try {
                System.loadLibrary("clingsync")
            } catch (e: UnsatisfiedLinkError) {
                // Library not found - will fall back to error messages.
            }
        }

        private val executeLock = Any()
    }

    external fun Execute(
        command: String,
        params: String,
    ): String

    private fun executeInternal(
        command: String,
        params: JSONObject,
    ): JSONObject {
        synchronized(executeLock) {
            val result = Execute(command, params.toString())
            val response = JSONObject(result)

            if (response.has("error")) {
                val error = response.getJSONObject("error")
                throw Exception(error.getString("message"))
            }

            return response
        }
    }

    override fun ensureOpen(
        hostUrl: String,
        password: String,
    ) {
        val params =
            JSONObject().apply {
                put("hostUrl", hostUrl)
                put("password", password)
            }

        executeInternal("ensureOpen", params)
    }

    override fun checkFiles(sha256s: List<String>): List<String> {
        val params =
            JSONObject().apply {
                put("sha256s", org.json.JSONArray(sha256s))
            }

        val response = executeInternal("checkFiles", params)
        val resultsArray = response.getJSONArray("results")
        return List(resultsArray.length()) { i -> resultsArray.getString(i) }
    }

    override fun uploadFile(
        filePath: String,
        repoPathPrefix: String,
    ): String {
        val params =
            JSONObject().apply {
                put("filePath", filePath)
                put("repoPathPrefix", repoPathPrefix)
            }

        val response = executeInternal("uploadFile", params)
        return response.getString("revisionEntry")
    }

    override fun commit(
        revisionEntries: List<String>,
        author: String,
        message: String,
    ): String {
        val params =
            JSONObject().apply {
                put("revisionEntries", org.json.JSONArray(revisionEntries))
                put("author", author)
                put("message", message)
            }

        val response = executeInternal("commit", params)
        return response.getString("revisionId")
    }
}
