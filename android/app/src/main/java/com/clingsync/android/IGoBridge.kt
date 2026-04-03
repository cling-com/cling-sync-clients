package com.clingsync.android

interface IGoBridge {
    fun checkRepositoryOpen(hostUrl: String): Boolean

    fun openRepository(
        hostUrl: String,
        password: String,
    )

    fun checkFiles(sha256s: List<String>): List<String>

    fun uploadFile(
        localFilePath: String,
        repoFilePath: String,
    ): String?

    fun commit(
        revisionEntries: List<String>,
        author: String,
        message: String,
    ): String
}
