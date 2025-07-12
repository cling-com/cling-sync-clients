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
    }

    external fun Execute(
        command: String,
        params: String,
    ): String

    override fun ensureOpen(
        hostUrl: String,
        password: String,
    ) {
        val params =
            JSONObject().apply {
                put("hostUrl", hostUrl)
                put("password", password)
            }

        val result = Execute("ensureOpen", params.toString())
        val response = JSONObject(result)

        if (response.has("error")) {
            val error = response.getJSONObject("error")
            throw Exception(error.getString("message"))
        }
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

        val result = Execute("uploadFile", params.toString())
        val response = JSONObject(result)

        if (response.has("error")) {
            val error = response.getJSONObject("error")
            throw Exception(error.getString("message"))
        }

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

        val result = Execute("commit", params.toString())
        val response = JSONObject(result)

        if (response.has("error")) {
            val error = response.getJSONObject("error")
            throw Exception(error.getString("message"))
        }

        return response.getString("revisionId")
    }
}
