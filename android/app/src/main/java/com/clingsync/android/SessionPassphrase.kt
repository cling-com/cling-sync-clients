package com.clingsync.android

// In-memory passphrase of the currently open repository, mirroring iOS's
// "session" storage mode. It lets the browse screen open its own repository
// session right after connecting, even when the user declined (or the device
// cannot support) storing the passphrase securely. It lives exactly as long
// as the open repository: every successful connect sets it, every close
// clears it.
object SessionPassphrase {
    @Volatile
    private var entry: Pair<String, String>? = null

    fun set(
        repositoryID: String,
        passphrase: String,
    ) {
        entry = repositoryID to passphrase
    }

    fun clear() {
        entry = null
    }

    fun get(repositoryID: String): String? {
        val current = entry ?: return null
        return if (current.first == repositoryID) current.second else null
    }
}
