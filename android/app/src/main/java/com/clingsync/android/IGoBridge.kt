package com.clingsync.android

interface IGoBridge {
    fun ensureOpen(
        hostUrl: String,
        password: String,
    )

    fun checkFiles(sha256s: List<String>): List<String>

    fun uploadFile(
        filePath: String,
        repoPathPrefix: String,
    ): String

    fun commit(
        revisionEntries: List<String>,
        author: String,
        message: String,
    ): String
}
