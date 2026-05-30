package com.clingsync.android

class S3CredentialsRequiredException(message: String) : Exception(message)

interface IGoBridge {
    // Initializes the bridge's writable directory (used for the S3 credentials map).
    fun initBridge(dataDir: String)

    fun checkRepositoryOpen(hostUrl: String): Boolean

    // Opens the repository for `hostUrl`. For S3 URLs the bridge looks up the
    // encrypted credentials internally. Throws [S3CredentialsRequiredException]
    // if none are stored.
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

    // Encrypts the S3 credentials with the passphrase and stores them keyed by `hostUrl`.
    fun encryptAndStoreS3Credentials(
        hostUrl: String,
        passphrase: String,
        accessKeyId: String,
        accessKey: String,
    )

    fun clearStoredS3Credentials(hostUrl: String)
}
