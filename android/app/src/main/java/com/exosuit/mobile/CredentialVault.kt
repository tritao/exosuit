package com.exosuit.mobile

import android.content.Context
import android.os.Looper
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import android.util.AtomicFile
import java.io.File
import java.security.KeyStore
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec

/**
 * The phone's paired-workspace credentials, encrypted at rest. The AES-GCM key is generated inside the Android Keystore
 * and never leaves it; the file holds only the IV and ciphertext. The Haxe module owns the document (a JSON list of
 * devices); the vault only stores and returns its bytes.
 *
 * Confined to the thread that created it (the UI thread, where the Haxe module runs). Every plaintext copy is a
 * ByteArray the caller wipes with [wipe]; nothing here turns a secret into a String.
 */
class CredentialVault(context: Context) {
    private val owner: Thread = Looper.getMainLooper().thread
    private val directory = context.filesDir
    private val file = AtomicFile(File(directory, "credentials.bin"))

    /**
     * The last [read] found a stored document it could not open (a missing or failing key, a damaged file). It is not the
     * same as no document: the next [write] first moves that file aside, so saving a new pairing never destroys it.
     */
    var unreadable = false
        private set

    private fun check() = check(Thread.currentThread() === owner) { "Credential vault used off the UI thread" }

    private fun key(create: Boolean): SecretKey? {
        val store = KeyStore.getInstance(ANDROID_KEYSTORE).apply { load(null) }
        (store.getKey(ALIAS, null) as? SecretKey)?.let { return it }
        // A key that exists but did not come back is a failure, never a reason to generate one: a new key under the same
        // alias would make the stored document impossible to open.
        if (store.containsAlias(ALIAS)) throw IllegalStateException("The credential key exists but could not be read")
        if (!create) return null
        val spec = KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
            .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
            .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
            .setKeySize(256)
            .build()
        return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, ANDROID_KEYSTORE).apply { init(spec) }.generateKey()
    }

    /**
     * The stored document, or null when none is stored or it cannot be opened (a wiped key, a damaged file); [unreadable]
     * tells those two apart.
     */
    fun read(): ByteArray? {
        check()
        unreadable = false
        if (!file.baseFile.exists()) return null
        val document = try {
            val data = file.readFully()
            val secret = if (data.size <= IV_BYTES + TAG_BYTES) null else key(false)
            if (secret == null) null else {
                val cipher = Cipher.getInstance(TRANSFORM)
                cipher.init(Cipher.DECRYPT_MODE, secret, GCMParameterSpec(TAG_BYTES * 8, data, 0, IV_BYTES))
                cipher.doFinal(data, IV_BYTES, data.size - IV_BYTES)
            }
        } catch (_: Exception) {
            null
        }
        unreadable = document == null
        return document
    }

    /**
     * Replaces the stored document. False when the Keystore or the file refused it. A document the last [read] could not
     * open is first renamed to `credentials.unreadable-<time>.bin`, so it can still be recovered.
     */
    fun write(document: ByteArray): Boolean {
        check()
        return try {
            val cipher = Cipher.getInstance(TRANSFORM)
            cipher.init(Cipher.ENCRYPT_MODE, key(true))
            val sealed = cipher.doFinal(document)
            if (unreadable) {
                val aside = File(directory, "credentials.unreadable-${System.currentTimeMillis()}.bin")
                if (!file.baseFile.renameTo(aside)) return false
                unreadable = false
            }
            val out = file.startWrite()
            try {
                out.write(cipher.iv)
                out.write(sealed)
                file.finishWrite(out)
            } catch (error: Exception) {
                file.failWrite(out)
                throw error
            }
            true
        } catch (_: Exception) {
            false
        }
    }

    companion object {
        private const val ANDROID_KEYSTORE = "AndroidKeyStore"
        private const val ALIAS = "exosuit-credentials-v1"
        private const val TRANSFORM = "AES/GCM/NoPadding"
        private const val IV_BYTES = 12
        private const val TAG_BYTES = 16

        fun wipe(bytes: ByteArray?) = bytes?.fill(0)
    }
}
