package com.clingsync.android

import android.content.Context
import android.content.SharedPreferences

object RepositoryUri {
    fun isCleartextS3(url: String): Boolean {
        val lower = url.lowercase()
        val isS3 = lower.startsWith("s3+http://") || lower.startsWith("s3+https://")
        return isS3 && !hasEmbeddedCredentials(url)
    }

    fun hasEmbeddedCredentials(url: String): Boolean {
        val schemeEnd = url.indexOf("://")
        if (schemeEnd < 0) return false
        val authority = url.substring(schemeEnd + 3).substringBefore('/')
        return authority.contains('@')
    }
}

// Persists the encrypted S3 repository URI per repository, so the S3 credentials
// (encrypted with the passphrase) are entered once and re-sent thereafter. The
// bridge keeps no credential state of its own.
class RepositoryUriStore(context: Context) {
    private val prefs: SharedPreferences =
        context.getSharedPreferences("repository_uris", Context.MODE_PRIVATE)

    fun get(repositoryID: String): String? = prefs.getString(repositoryID, null)

    fun set(
        repositoryID: String,
        uri: String,
    ) {
        prefs.edit().putString(repositoryID, uri).apply()
    }

    fun clear(repositoryID: String) {
        prefs.edit().remove(repositoryID).apply()
    }
}
