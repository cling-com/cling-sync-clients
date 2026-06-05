package com.clingsync.android

import android.content.Context

object GoBridgeProvider {
    private var instance: IGoBridge? = null
    private var initialized = false

    fun getInstance(): IGoBridge {
        return instance ?: GoBridge().also { instance = it }
    }

    // Points the bridge at an app-writable directory for its caches. Idempotent
    // per process, and called from every entry point (Activity and workers) since
    // a worker can cold-start the process on its own.
    fun initialize(context: Context) {
        if (initialized) return
        getInstance().initialize(context.filesDir.absolutePath)
        initialized = true
    }

    fun setInstance(bridge: IGoBridge) {
        instance = bridge
    }

    fun reset() {
        instance = null
        initialized = false
    }
}
