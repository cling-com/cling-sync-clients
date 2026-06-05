package com.clingsync.android

interface IGoBridge {
    // Sets the directory the bridge writes its caches to. Called once per process
    // before any other call.
    fun initialize(cacheDir: String)

    fun checkRepositoryOpen(repositoryUri: String): Boolean

    // Opens the repository. `repositoryUri` is a file path or an `s3+...` URI
    // carrying its encrypted credentials.
    fun openRepository(
        repositoryUri: String,
        password: String,
    )

    // Reports, per input hash, whether its content is present in the repository's
    // HEAD. Backed by the persisted hash index, so it works without an open repo.
    fun checkFiles(sha256s: List<String>): List<Boolean>

    fun uploadFile(
        localFilePath: String,
        repoFilePath: String,
    ): String?

    fun commit(
        revisionEntries: List<String>,
        author: String,
        message: String,
    ): String

    // Encrypts the S3 credentials with the passphrase and returns the `s3+...`
    // URI with them embedded. The bridge keeps no credential state of its own.
    fun encodeS3URI(
        hostUrl: String,
        passphrase: String,
        accessKeyId: String,
        accessKey: String,
    ): String
}
