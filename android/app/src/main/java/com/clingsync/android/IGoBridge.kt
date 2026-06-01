package com.clingsync.android

interface IGoBridge {
    fun checkRepositoryOpen(repositoryUri: String): Boolean

    // Opens the repository. `repositoryUri` is a file path or an `s3+...` URI
    // carrying its encrypted credentials.
    fun openRepository(
        repositoryUri: String,
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

    // Encrypts the S3 credentials with the passphrase and returns the `s3+...`
    // URI with them embedded. The bridge keeps no credential state of its own.
    fun encodeS3URI(
        hostUrl: String,
        passphrase: String,
        accessKeyId: String,
        accessKey: String,
    ): String
}
