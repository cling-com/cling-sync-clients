package com.clingsync.android

object GoBridgeProvider {
    private var instance: IGoBridge? = null

    fun getInstance(): IGoBridge {
        return instance ?: GoBridge().also { instance = it }
    }

    fun setInstance(bridge: IGoBridge) {
        instance = bridge
    }

    fun reset() {
        instance = null
    }

    fun setInstanceForTesting(bridge: IGoBridge) {
        instance = bridge
    }
}
