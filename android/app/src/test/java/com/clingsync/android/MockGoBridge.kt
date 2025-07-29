package com.clingsync.android

import kotlinx.coroutines.delay
import kotlinx.coroutines.runBlocking
import java.util.concurrent.atomic.AtomicInteger

class MockGoBridge : IGoBridge {
    var shouldFailEnsureOpen = false
    var shouldFailUploadFile = false
    var shouldFailCommit = false
    var uploadDelay = 100L // Milliseconds per file.
    var failAtFileIndex = -1 // -1 means don't fail.

    private val uploadedFiles = mutableListOf<String>()
    private val uploadCounter = AtomicInteger(0)
    private val ensureOpenCounter = AtomicInteger(0)
    private val commitCounter = AtomicInteger(0)

    private val uploadCalls = mutableListOf<String>()
    private val commitCalls = mutableListOf<Triple<List<String>, String, String>>()
    private val errors = mutableListOf<String>()

    var isOpen = false
    var lastCommitMessage: String? = null
    var lastCommitAuthor: String? = null

    val selectedFiles = mutableListOf<String>()

    override fun ensureOpen(
        hostUrl: String,
        password: String,
        repoPathPrefix: String,
    ) {
        if (shouldFailEnsureOpen) {
            val error = "Failed to connect to repository: Connection refused"
            errors.add(error)
            throw Exception(error)
        }
        ensureOpenCounter.incrementAndGet()
        isOpen = true
    }

    override fun checkFiles(sha256s: List<String>): List<String> {
        if (!isOpen) {
            val error = "Repository not open"
            errors.add(error)
            throw Exception(error)
        }

        val res = mutableListOf<String>()
        for (sha256 in sha256s) {
            res.add("path/to/file/$sha256")
        }
        return res
    }

    override fun uploadFile(filePath: String): String? {
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

        // Simulate upload delay.
        runBlocking {
            delay(uploadDelay)
        }

        uploadedFiles.add(filePath)
        uploadCalls.add(filePath)
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
        shouldFailEnsureOpen = false
        shouldFailUploadFile = false
        shouldFailCommit = false
        uploadDelay = 100L
        failAtFileIndex = -1
        uploadedFiles.clear()
        uploadCounter.set(0)
        ensureOpenCounter.set(0)
        commitCounter.set(0)
        uploadCalls.clear()
        commitCalls.clear()
        errors.clear()
        selectedFiles.clear()
        isOpen = false
        lastCommitMessage = null
        lastCommitAuthor = null
    }

    fun getUploadedFiles(): List<String> = uploadedFiles.toList()

    fun getUploadCount(): Int = uploadCounter.get()

    fun getEnsureOpenCount(): Int = ensureOpenCounter.get()

    fun getCommitCount(): Int = commitCounter.get()

    fun getUploadCalls(): List<String> = uploadCalls.toList()

    fun getCommitCalls(): List<Triple<List<String>, String, String>> = commitCalls.toList()

    fun getErrors(): List<String> = errors.toList()
}
