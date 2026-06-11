package com.clingsync.android

import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.Log
import java.security.KeyStore
import javax.crypto.KeyGenerator
import javax.crypto.Mac
import javax.crypto.SecretKey

// Derives a stable, per-install 32-byte secret the Go bridge uses to encrypt the
// repository hash index at rest. The secret is HMAC-SHA256 of a fixed label under a
// non-exportable AndroidKeyStore key that requires NO user authentication, so the
// headless merge reminder can read the index without a prompt. A copy of the cache
// file off-device (cloud backup, forensic pull) is useless without the hardware key.
// HMAC is used rather than wrapping a random secret because AndroidKeyStore keys
// cannot be exported, and it avoids adding a second cipher to the app.
object HashIndexKeyStore {
    private const val TAG = "HashIndexKeyStore"
    private const val KEYSTORE_PROVIDER = "AndroidKeyStore"
    private const val KEY_ALIAS = "clingsync_hash_index_key"
    private val label = "cling-sync hash index v1".toByteArray(Charsets.UTF_8)

    // Returns the 32-byte secret, creating the backing key on first use. Returns null
    // when the keystore is unavailable (e.g. under Robolectric, or a broken keystore),
    // in which case the bridge falls back to writing the index in the clear.
    fun getOrCreate(): ByteArray? =
        try {
            Mac.getInstance("HmacSHA256").apply { init(getOrCreateKey()) }.doFinal(label)
        } catch (e: Exception) {
            Log.w(TAG, "Hash index key unavailable; index will not be encrypted", e)
            null
        }

    private fun getOrCreateKey(): SecretKey {
        val keyStore = KeyStore.getInstance(KEYSTORE_PROVIDER)
        keyStore.load(null)
        (keyStore.getKey(KEY_ALIAS, null) as? SecretKey)?.let { return it }

        val generator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_HMAC_SHA256, KEYSTORE_PROVIDER)
        generator.init(KeyGenParameterSpec.Builder(KEY_ALIAS, KeyProperties.PURPOSE_SIGN).build())
        return generator.generateKey()
    }
}
