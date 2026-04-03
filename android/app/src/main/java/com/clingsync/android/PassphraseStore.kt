package com.clingsync.android

import android.content.Context
import android.content.SharedPreferences
import android.os.Build
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyPermanentlyInvalidatedException
import android.security.keystore.KeyProperties
import android.util.Base64
import android.util.Log
import androidx.biometric.BiometricManager
import androidx.biometric.BiometricPrompt
import androidx.core.content.ContextCompat
import androidx.fragment.app.FragmentActivity
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

class PassphraseStore(private val context: Context) {
    companion object {
        private const val TAG = "PassphraseStore"
        private const val KEYSTORE_PROVIDER = "AndroidKeyStore"
        private const val KEY_ALIAS_PREFIX = "clingsync_passphrase_"
        private const val PREFS_NAME = "clingsync_passphrase_store"
        private const val CIPHER_TRANSFORMATION = "AES/GCM/NoPadding"
        private const val GCM_TAG_LENGTH = 128
    }

    private val prefs: SharedPreferences =
        context.getSharedPreferences(PREFS_NAME, Context.MODE_PRIVATE)

    fun hasStoredPassphrase(repositoryID: String): Boolean {
        val has = prefs.contains(ciphertextKey(repositoryID))
        Log.d(TAG, "hasStoredPassphrase($repositoryID) = $has")
        return has
    }

    fun canUseBiometric(): Boolean {
        val biometricManager = BiometricManager.from(context)
        return biometricManager.canAuthenticate(
            BiometricManager.Authenticators.BIOMETRIC_STRONG,
        ) == BiometricManager.BIOMETRIC_SUCCESS
    }

    fun save(
        activity: FragmentActivity,
        passphrase: String,
        repositoryID: String,
        onDone: () -> Unit,
    ) {
        val key = getOrCreateKey(repositoryID)

        try {
            val cipher = Cipher.getInstance(CIPHER_TRANSFORMATION)
            cipher.init(Cipher.ENCRYPT_MODE, key)
            authenticateAndRun(activity, cipher, "Save passphrase securely") {
                val encryptCipher = it ?: cipher
                val ciphertext = encryptCipher.doFinal(passphrase.toByteArray(Charsets.UTF_8))
                val iv = encryptCipher.iv
                prefs.edit()
                    .putString(ciphertextKey(repositoryID), Base64.encodeToString(ciphertext, Base64.NO_WRAP))
                    .putString(ivKey(repositoryID), Base64.encodeToString(iv, Base64.NO_WRAP))
                    .commit()
                Log.d(TAG, "Passphrase saved for $repositoryID")
                onDone()
            }
        } catch (e: Exception) {
            Log.e(TAG, "Failed to save passphrase", e)
            onDone()
        }
    }

    fun load(
        activity: FragmentActivity,
        repositoryID: String,
        onSuccess: (String) -> Unit,
        onError: (String) -> Unit,
    ) {
        val ciphertextStr = prefs.getString(ciphertextKey(repositoryID), null)
        val ivStr = prefs.getString(ivKey(repositoryID), null)
        if (ciphertextStr == null || ivStr == null) {
            Log.d(TAG, "No stored passphrase for $repositoryID")
            onError("No stored passphrase found.")
            return
        }

        val ciphertext = Base64.decode(ciphertextStr, Base64.NO_WRAP)
        val iv = Base64.decode(ivStr, Base64.NO_WRAP)

        val key = getKey(repositoryID)
        if (key == null) {
            delete(repositoryID)
            onError("Keystore key lost. Please re-enter your passphrase.")
            return
        }

        try {
            val cipher = Cipher.getInstance(CIPHER_TRANSFORMATION)
            cipher.init(Cipher.DECRYPT_MODE, key, GCMParameterSpec(GCM_TAG_LENGTH, iv))
            authenticateAndRun(activity, cipher, "Unlock passphrase") {
                val decryptCipher = it ?: cipher
                val plaintext = decryptCipher.doFinal(ciphertext)
                onSuccess(String(plaintext, Charsets.UTF_8))
            }
        } catch (e: KeyPermanentlyInvalidatedException) {
            delete(repositoryID)
            onError("Biometric data changed. Please re-enter your passphrase.")
        } catch (e: Exception) {
            Log.e(TAG, "Failed to init decrypt cipher", e)
            delete(repositoryID)
            onError("Failed to decrypt passphrase. Please re-enter it.")
        }
    }

    fun delete(repositoryID: String) {
        prefs.edit().remove(ciphertextKey(repositoryID)).remove(ivKey(repositoryID)).apply()
        try {
            val keyStore = KeyStore.getInstance(KEYSTORE_PROVIDER)
            keyStore.load(null)
            keyStore.deleteEntry(keyAlias(repositoryID))
        } catch (e: Exception) {
            Log.w(TAG, "Failed to delete key", e)
        }
    }

    fun deleteAll() {
        prefs.edit().clear().apply()
        try {
            val keyStore = KeyStore.getInstance(KEYSTORE_PROVIDER)
            keyStore.load(null)
            keyStore.aliases().toList().filter { it.startsWith(KEY_ALIAS_PREFIX) }.forEach {
                keyStore.deleteEntry(it)
            }
        } catch (e: Exception) {
            Log.w(TAG, "Failed to delete all keys", e)
        }
    }

    private fun authenticateAndRun(
        activity: FragmentActivity,
        cipher: Cipher,
        subtitle: String,
        onAuthenticated: (Cipher?) -> Unit,
    ) {
        if (!canUseBiometric()) {
            // No biometric available — use cipher directly (key has no auth requirement).
            onAuthenticated(null)
            return
        }

        val promptInfo =
            BiometricPrompt.PromptInfo.Builder()
                .setTitle("Cling Sync")
                .setSubtitle(subtitle)
                .setNegativeButtonText("Cancel")
                .build()

        val biometricPrompt =
            BiometricPrompt(
                activity,
                ContextCompat.getMainExecutor(activity),
                object : BiometricPrompt.AuthenticationCallback() {
                    override fun onAuthenticationSucceeded(result: BiometricPrompt.AuthenticationResult) {
                        try {
                            onAuthenticated(result.cryptoObject?.cipher)
                        } catch (e: Exception) {
                            Log.e(TAG, "Operation failed after auth", e)
                        }
                    }

                    override fun onAuthenticationError(
                        errorCode: Int,
                        errString: CharSequence,
                    ) {
                        Log.w(TAG, "Auth error $errorCode: $errString")
                        // Proceed without crypto binding on cancel.
                    }

                    override fun onAuthenticationFailed() {
                        // Prompt stays open for retry.
                    }
                },
            )

        try {
            biometricPrompt.authenticate(promptInfo, BiometricPrompt.CryptoObject(cipher))
        } catch (e: Exception) {
            Log.w(TAG, "CryptoObject auth failed, running without", e)
            onAuthenticated(null)
        }
    }

    private fun getOrCreateKey(repositoryID: String): SecretKey {
        getKey(repositoryID)?.let { return it }

        val keyGenerator = KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, KEYSTORE_PROVIDER)
        val specBuilder =
            KeyGenParameterSpec.Builder(
                keyAlias(repositoryID),
                KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT,
            )
                .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                .setKeySize(256)

        // Bind key to biometric auth when available.
        if (canUseBiometric()) {
            specBuilder.setUserAuthenticationRequired(true)
            specBuilder.setInvalidatedByBiometricEnrollment(true)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                specBuilder.setUserAuthenticationParameters(
                    0,
                    KeyProperties.AUTH_BIOMETRIC_STRONG,
                )
            }
        }

        keyGenerator.init(specBuilder.build())
        return keyGenerator.generateKey()
    }

    private fun getKey(repositoryID: String): SecretKey? {
        val keyStore = KeyStore.getInstance(KEYSTORE_PROVIDER)
        keyStore.load(null)
        return keyStore.getKey(keyAlias(repositoryID), null) as? SecretKey
    }

    private fun keyAlias(repositoryID: String) = "$KEY_ALIAS_PREFIX$repositoryID"

    private fun ciphertextKey(repositoryID: String) = "ct_$repositoryID"

    private fun ivKey(repositoryID: String) = "iv_$repositoryID"
}
