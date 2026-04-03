package com.clingsync.android

import java.util.concurrent.atomic.AtomicInteger

class MockGoBridge : IGoBridge {
    var shouldFailOpenRepository = false
    var shouldFailUploadFile = false
    var shouldFailCommit = false
    var uploadDelay = 100L // Milliseconds per file.
    var failAtFileIndex = -1 // -1 means don't fail.

    private val uploadedFiles = mutableListOf<String>()
    private val uploadCounter = AtomicInteger(0)
    private val openRepositoryCounter = AtomicInteger(0)
    private val commitCounter = AtomicInteger(0)

    private val uploadCalls = mutableListOf<String>()
    private val commitCalls = mutableListOf<Triple<List<String>, String, String>>()
    private val errors = mutableListOf<String>()

    var isOpen = false
    var lastCommitMessage: String? = null
    var lastCommitAuthor: String? = null

    override fun checkRepositoryOpen(hostUrl: String): Boolean {
        return isOpen
    }

    override fun openRepository(
        hostUrl: String,
        password: String,
    ) {
        if (shouldFailOpenRepository) {
            val error = "Failed to connect to repository: Connection refused"
            errors.add(error)
            throw Exception(error)
        }
        openRepositoryCounter.incrementAndGet()
        isOpen = true
    }

    var checkFilesResults: List<String>? = null

    override fun checkFiles(sha256s: List<String>): List<String> {
        if (!isOpen) {
            val error = "Repository not open"
            errors.add(error)
            throw Exception(error)
        }

        if (checkFilesResults != null) {
            return checkFilesResults!!
        }

        // Default: return empty strings (files not found in repo).
        return List(sha256s.size) { "" }
    }

    override fun uploadFile(
        localFilePath: String,
        repoFilePath: String,
    ): String? {
        if (!isOpen) {
            val error = "Repository not open"
            errors.add(error)
            throw Exception(error)
        }

        val currentIndex = uploadCounter.getAndIncrement()

        if (failAtFileIndex == currentIndex) {
            val error = "Failed to upload file: Permission denied"
            errors.add(error)
            throw Exception(error)
        }

        if (shouldFailUploadFile) {
            val error = "Upload failed: Network error"
            errors.add(error)
            throw Exception(error)
        }

        uploadedFiles.add(localFilePath)
        uploadCalls.add(localFilePath)
        return "revision-entry-$currentIndex"
    }

    override fun commit(
        revisionEntries: List<String>,
        author: String,
        message: String,
    ): String {
        if (!isOpen) {
            val error = "Repository not open"
            errors.add(error)
            throw Exception(error)
        }

        if (shouldFailCommit) {
            val error = "Commit failed: Invalid revision entries"
            errors.add(error)
            throw Exception(error)
        }

        commitCounter.incrementAndGet()
        lastCommitAuthor = author
        lastCommitMessage = message
        commitCalls.add(Triple(revisionEntries, author, message))

        return "revision-${System.currentTimeMillis()}"
    }

    fun reset() {
        shouldFailOpenRepository = false
        shouldFailUploadFile = false
        shouldFailCommit = false
        uploadDelay = 100L
        failAtFileIndex = -1
        uploadedFiles.clear()
        uploadCounter.set(0)
        openRepositoryCounter.set(0)
        commitCounter.set(0)
        uploadCalls.clear()
        commitCalls.clear()
        errors.clear()
        checkFilesResults = null
        isOpen = false
        lastCommitMessage = null
        lastCommitAuthor = null
    }

    fun getUploadedFiles(): List<String> = uploadedFiles.toList()

    fun getUploadCount(): Int = uploadCounter.get()

    fun getOpenRepositoryCount(): Int = openRepositoryCounter.get()

    fun getCommitCount(): Int = commitCounter.get()

    fun getUploadCalls(): List<String> = uploadCalls.toList()

    fun getCommitCalls(): List<Triple<List<String>, String, String>> = commitCalls.toList()

    fun getErrors(): List<String> = errors.toList()
}
