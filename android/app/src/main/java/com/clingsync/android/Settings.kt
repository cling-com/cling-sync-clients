package com.clingsync.android

import android.content.Context
import android.content.SharedPreferences
import android.os.Environment

data class AppSettings(
    val hostUrl: String = "",
    val repoPathPrefix: String = "",
    val author: String = "Android User",
    val sourceDirectory: String =
        Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DCIM).absolutePath,
    val mediaOnly: Boolean = true,
) {
    fun isValid(): Boolean = hostUrl.isNotBlank() && author.isNotBlank()

    fun repositoryID(): String = hostUrl.trim().trimEnd('/')
}

// Returns null when `url` is a syntactically acceptable host URL, or a
// human-readable error message describing the required format otherwise.
fun validateHostUrl(url: String): String? {
    val trimmed = url.trim()
    if (trimmed.startsWith("s3+http://") || trimmed.startsWith("s3+https://")) {
        return null
    }
    return "The Host URL must start with \"s3+http://\" or \"s3+https://\".\n\n" +
        "Example: s3+https://bucket.s3.region.example.com"
}

class SettingsManager(private val context: Context) {
    private val prefs: SharedPreferences = context.getSharedPreferences("cling_sync_prefs", Context.MODE_PRIVATE)

    fun getSettings(): AppSettings {
        return AppSettings(
            hostUrl = prefs.getString("host_url", "") ?: "",
            repoPathPrefix = prefs.getString("repo_path_prefix", "") ?: "",
            author = prefs.getString("author", "Android User") ?: "Android User",
            sourceDirectory =
                prefs.getString(
                    "source_directory",
                    Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DCIM).absolutePath,
                ) ?: "",
            mediaOnly = prefs.getBoolean("media_only", true),
        )
    }

    fun saveSettings(settings: AppSettings) {
        prefs.edit().apply {
            putString("host_url", settings.hostUrl)
            putString("repo_path_prefix", settings.repoPathPrefix)
            putString("author", settings.author)
            putString("source_directory", settings.sourceDirectory)
            putBoolean("media_only", settings.mediaOnly)
            remove("password")
            apply()
        }
    }
}
