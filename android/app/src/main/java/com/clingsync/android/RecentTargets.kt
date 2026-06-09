package com.clingsync.android

import android.content.Context
import org.json.JSONArray

// Persists the destination paths most recently used for a share upload (most
// recent first, de-duplicated, capped), offered by the share screen alongside the
// configured settings prefix.
object RecentTargets {
    const val MAX = 10
    private const val PREFS = "recent_share_targets"
    private const val KEY = "targets"

    fun load(context: Context): List<String> {
        val raw = prefs(context).getString(KEY, null) ?: return emptyList()
        val array = JSONArray(raw)
        return List(array.length()) { array.getString(it) }
    }

    fun record(
        context: Context,
        target: String,
    ) {
        val normalized = normalizeTarget(target)
        val updated = (listOf(normalized) + load(context).filter { it != normalized }).take(MAX)
        val array = JSONArray()
        updated.forEach { array.put(it) }
        prefs(context).edit().putString(KEY, array.toString()).apply()
    }

    private fun prefs(context: Context) = context.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
}

// The repo path the upload actually uses trims surrounding slashes, so normalize
// targets the same way before storing or comparing them, or equivalent paths
// ("photos", "/photos/") would show up as separate recent entries.
fun normalizeTarget(target: String): String = target.trim().trim('/')

// The target-dir choices the share screen offers: the recent targets (most recent
// first) plus the settings prefix when not already present, with the default being
// the most recently used or the settings prefix when there are none. Pure so the
// option logic is assertable on its own.
data class ShareTargetOptions(
    val options: List<String>,
    val default: String,
) {
    companion object {
        fun from(
            settingsPrefix: String,
            recent: List<String>,
        ): ShareTargetOptions {
            val prefix = normalizeTarget(settingsPrefix)
            val options = if (recent.contains(prefix)) recent else recent + prefix
            return ShareTargetOptions(options, recent.firstOrNull() ?: prefix)
        }
    }
}
