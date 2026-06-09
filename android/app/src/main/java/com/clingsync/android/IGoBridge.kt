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
    // HEAD. Backed by the persisted hash index, so it works without an open repo, but
    // does NOT verify the index is current (the merge reminder relies on this).
    fun checkFiles(sha256s: List<String>): List<Boolean>

    // Rebuilds the persisted hash index if it was built for a different revision than
    // the open repository's current HEAD. Interactive callers (scan/share) run this
    // before checkFiles; requires the repository open.
    fun ensureFileHashesAtHead()

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
