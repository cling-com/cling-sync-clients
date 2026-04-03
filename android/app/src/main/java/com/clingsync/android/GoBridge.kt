package com.clingsync.android

import android.util.Log
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
        Log.d("GoBridge", "Executing command: $command")
        synchronized(executeLock) {
            try {
                val result = Execute(command, params.toString())
                val response = JSONObject(result)

                if (response.has("error")) {
                    val error = response.getJSONObject("error")
                    val errorMessage = error.getString("message")
                    Log.e("GoBridge", "Command $command failed with error: $errorMessage")
                    throw Exception(errorMessage)
                }

                Log.d("GoBridge", "Command $command completed successfully")
                return response
            } catch (e: Exception) {
                Log.e("GoBridge", "Exception in command $command: ${e.message}", e)
                throw e
            }
        }
    }

    override fun checkRepositoryOpen(hostUrl: String): Boolean {
        val params =
            JSONObject().apply {
                put("hostUrl", hostUrl)
            }

        val response = executeInternal("checkRepositoryOpen", params)
        return response.optBoolean("open", false)
    }

    override fun openRepository(
        hostUrl: String,
        password: String,
    ) {
        val params =
            JSONObject().apply {
                put("hostUrl", hostUrl)
                put("password", password)
            }

        executeInternal("openRepository", params)
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
        localFilePath: String,
        repoFilePath: String,
    ): String? {
        val params =
            JSONObject().apply {
                put("localFilePath", localFilePath)
                put("repoFilePath", repoFilePath)
            }

        val response = executeInternal("uploadFile", params)

        // Check if file was skipped
        if (response.optBoolean("skipped", false)) {
            return null
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

        val response = executeInternal("commit", params)
        return response.getString("revisionId")
    }
}
