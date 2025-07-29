package com.clingsync.android

import android.content.Context
import android.content.SharedPreferences

data class AppSettings(
    val hostUrl: String = "",
    // TODO: Don't store the password as plain text.
    val password: String = "",
    val repoPathPrefix: String = "",
    val author: String = "Android User",
) {
    fun isValid(): Boolean = hostUrl.isNotBlank() && password.isNotBlank() && author.isNotBlank()
}

class SettingsManager(private val context: Context) {
    private val prefs: SharedPreferences = context.getSharedPreferences("cling_sync_prefs", Context.MODE_PRIVATE)

    fun getSettings(): AppSettings {
        return AppSettings(
            hostUrl = prefs.getString("host_url", "") ?: "",
            password = prefs.getString("password", "") ?: "",
            repoPathPrefix = prefs.getString("repo_path_prefix", "") ?: "",
            author = prefs.getString("author", "Android User") ?: "Android User",
        )
    }

    fun saveSettings(settings: AppSettings) {
        prefs.edit().apply {
            putString("host_url", settings.hostUrl)
            putString("password", settings.password)
            putString("repo_path_prefix", settings.repoPathPrefix)
            putString("author", settings.author)
            apply()
        }
    }
}
