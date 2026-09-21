package com.clingsync.android

import org.json.JSONObject

// Second JNI entry point next to GoBridge, for the browse module. Browse
// sessions open their own repository and synchronize in Go, so calls are not
// serialized with GoBridge's executeLock: a browse page load never queues
// behind a running upload and vice versa.
object GoBrowse {
    init {
        System.loadLibrary("clingsync")
    }

    @Suppress("ktlint:standard:function-naming")
    // UTF-8 bytes rather than Strings, see android/go/browse.go.
    private external fun Execute(
        command: String,
        params: ByteArray,
    ): ByteArray

    fun execute(
        command: String,
        params: JSONObject,
    ): JSONObject {
        val result = JSONObject(String(Execute(command, params.toString().toByteArray(Charsets.UTF_8)), Charsets.UTF_8))
        val error = result.optJSONObject("error")
        if (error != null) {
            throw BrowseException(error.optString("message", "Unknown browse error"))
        }
        return result
    }

    fun closeAll() {
        execute("closeAll", JSONObject())
    }
}

class BrowseException(message: String) : Exception(message)
