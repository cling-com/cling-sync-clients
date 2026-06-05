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

    // The raw string transport. Production calls the JNI [Execute]; tests can
    // override this to route the exact same command/JSON to a host-side execute
    // server while reusing all the translation below (no fake bridge).
    protected open fun rawExecute(
        command: String,
        params: String,
    ): String = Execute(command, params)

    private fun executeInternal(
        command: String,
        params: JSONObject,
    ): JSONObject {
        Log.d("GoBridge", "Executing command: $command")
        synchronized(executeLock) {
            try {
                val result = rawExecute(command, params.toString())
                val response = JSONObject(result)

                if (response.has("error")) {
                    val error = response.getJSONObject("error")
                    val errorMessage = error.getString("message")
                    Log.e("GoBridge", "Command $command failed: $errorMessage")
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

    override fun initialize(cacheDir: String) {
        val params = JSONObject().apply { put("cacheDir", cacheDir) }
        executeInternal("init", params)
    }

    override fun checkRepositoryOpen(repositoryUri: String): Boolean {
        val params = JSONObject().apply { put("hostUrl", repositoryUri) }
        val response = executeInternal("checkRepositoryOpen", params)
        return response.optBoolean("open", false)
    }

    override fun openRepository(
        repositoryUri: String,
        password: String,
    ) {
        val params =
            JSONObject().apply {
                put("hostUrl", repositoryUri)
                put("password", password)
            }
        executeInternal("openRepository", params)
    }

    override fun encodeS3URI(
        hostUrl: String,
        passphrase: String,
        accessKeyId: String,
        accessKey: String,
    ): String {
        val params =
            JSONObject().apply {
                put("hostUrl", hostUrl)
                put("passphrase", passphrase)
                put("accessKeyId", accessKeyId)
                put("accessKey", accessKey)
            }
        return executeInternal("encodeS3URI", params).getString("uri")
    }

    override fun checkFiles(sha256s: List<String>): List<Boolean> {
        val params =
            JSONObject().apply {
                put("sha256s", org.json.JSONArray(sha256s))
            }

        val response = executeInternal("checkFiles", params)
        val resultsArray = response.getJSONArray("results")
        return List(resultsArray.length()) { i -> resultsArray.getBoolean(i) }
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
