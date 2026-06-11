package com.clingsync.android

import android.content.Context
import androidx.test.core.app.ApplicationProvider
import androidx.test.ext.junit.runners.AndroidJUnit4
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.annotation.Config

@RunWith(AndroidJUnit4::class)
@Config(sdk = [30])
class RepositoryUriTest {
    private lateinit var context: Context

    @Before
    fun setup() {
        context = ApplicationProvider.getApplicationContext()
        context.getSharedPreferences("repository_uris", Context.MODE_PRIVATE).edit().clear().commit()
    }

    @Test
    fun cleartextS3IsDetected() {
        assertTrue(RepositoryUri.isCleartextS3("s3+http://10.0.2.2:9124"))
        assertTrue(RepositoryUri.isCleartextS3("s3+https://bucket.s3.example.com"))
        // Scheme casing does not matter.
        assertTrue(RepositoryUri.isCleartextS3("S3+HTTP://10.0.2.2:9124"))
    }

    @Test
    fun nonS3OrCredentialedUrlsAreNotCleartextS3() {
        assertFalse(RepositoryUri.isCleartextS3("https://bucket.example.com"))
        assertFalse(RepositoryUri.isCleartextS3("s3+http://key:secret@10.0.2.2:9124"))
    }

    @Test
    fun embeddedCredentialsLookAtAuthorityOnly() {
        assertTrue(RepositoryUri.hasEmbeddedCredentials("s3+http://key:secret@10.0.2.2:9124"))
        assertFalse(RepositoryUri.hasEmbeddedCredentials("s3+http://10.0.2.2:9124"))
        // An '@' in the path must not be mistaken for credentials.
        assertFalse(RepositoryUri.hasEmbeddedCredentials("s3+http://host/folder@2x/file"))
        // No scheme at all.
        assertFalse(RepositoryUri.hasEmbeddedCredentials("not-a-url"))
    }

    @Test
    fun storeRoundTripsAndClears() {
        val store = RepositoryUriStore(context)
        val id = "s3+http://10.0.2.2:9124"

        assertNull(store.get(id))

        store.set(id, "s3+http://key:enc@10.0.2.2:9124")
        assertEquals("s3+http://key:enc@10.0.2.2:9124", store.get(id))

        store.clear(id)
        assertNull(store.get(id))
    }

    @Test
    fun storeKeepsRepositoriesIndependent() {
        val store = RepositoryUriStore(context)
        store.set("repo-a", "uri-a")
        store.set("repo-b", "uri-b")

        store.clear("repo-a")

        assertNull(store.get("repo-a"))
        assertEquals("uri-b", store.get("repo-b"))
    }
}
