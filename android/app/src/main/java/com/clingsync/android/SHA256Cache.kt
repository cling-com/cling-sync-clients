package com.clingsync.android

import android.content.Context
import android.system.Os
import android.util.Log
import org.json.JSONObject
import java.io.File

class SHA256Cache private constructor(context: Context) {
    companion object {
        @Volatile
        private var instance: SHA256Cache? = null

        fun getInstance(context: Context): SHA256Cache =
            instance ?: synchronized(this) {
                instance ?: SHA256Cache(context.applicationContext).also { instance = it }
            }

        fun resetForTesting() {
            instance = null
        }
    }

    private data class Entry(
        val size: Long,
        val lastModified: Long,
        val ctime: Long,
        val sha256: String,
    )

    private val cacheFile = File(context.filesDir, "sha256cache.json")
    private val entries = mutableMapOf<String, Entry>()

    init {
        load()
    }

    fun lookup(
        name: String,
        size: Long,
        lastModified: Long,
    ): String? {
        val entry = entries[name] ?: return null
        val ctime = getCtime(name)
        if (entry.size != size || entry.lastModified != lastModified || entry.ctime != ctime) {
            entries.remove(name)
            return null
        }
        return entry.sha256
    }

    fun store(
        name: String,
        size: Long,
        lastModified: Long,
        sha256: String,
    ) {
        val ctime = getCtime(name)
        entries[name] = Entry(size = size, lastModified = lastModified, ctime = ctime, sha256 = sha256)
    }

    private fun getCtime(path: String): Long =
        try {
            Os.stat(path).st_ctime
        } catch (_: Exception) {
            0L
        }

    fun save() {
        try {
            val json = JSONObject()
            entries.forEach { (name, entry) ->
                json.put(
                    name,
                    JSONObject().apply {
                        put("size", entry.size)
                        put("lastModified", entry.lastModified)
                        put("ctime", entry.ctime)
                        put("sha256", entry.sha256)
                    },
                )
            }
            cacheFile.writeText(json.toString())
            Log.d("SHA256Cache", "Saved ${entries.size} entries to ${cacheFile.absolutePath} (${cacheFile.length()} bytes)")
        } catch (e: Exception) {
            Log.w("SHA256Cache", "Failed to save cache", e)
        }
    }

    private fun load() {
        try {
            if (!cacheFile.exists()) return
            val json = JSONObject(cacheFile.readText())
            json.keys().forEach { name ->
                val obj = json.getJSONObject(name)
                entries[name] =
                    Entry(
                        size = obj.getLong("size"),
                        lastModified = obj.getLong("lastModified"),
                        ctime = obj.optLong("ctime", 0L),
                        sha256 = obj.getString("sha256"),
                    )
            }
            Log.d("SHA256Cache", "Loaded ${entries.size} cached entries")
        } catch (e: Exception) {
            Log.w("SHA256Cache", "Failed to load cache", e)
            entries.clear()
        }
    }
}
