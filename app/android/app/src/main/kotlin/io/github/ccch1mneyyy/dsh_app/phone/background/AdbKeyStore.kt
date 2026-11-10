package io.github.ccch1mneyyy.dsh_app.phone.background

import android.content.Context
import android.security.keystore.KeyGenParameterSpec
import android.security.keystore.KeyProperties
import java.io.File
import java.io.FileOutputStream
import java.math.BigInteger
import java.nio.file.Files
import java.nio.file.StandardCopyOption.ATOMIC_MOVE
import java.nio.file.StandardCopyOption.REPLACE_EXISTING
import java.security.KeyFactory
import java.security.KeyPairGenerator
import java.security.KeyStore
import java.security.PrivateKey
import java.security.cert.Certificate
import java.security.cert.CertificateFactory
import java.security.spec.PKCS8EncodedKeySpec
import java.util.Date
import javax.crypto.Cipher
import javax.crypto.KeyGenerator
import javax.crypto.SecretKey
import javax.crypto.spec.GCMParameterSpec
import javax.security.auth.x500.X500Principal
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder

/**
 * The adb RSA identity for self-ADB, persisted in the app's private files (0600). libadb-android
 * needs a real [PrivateKey] + self-signed [Certificate]; BouncyCastle builds the certificate.
 * Generated once, then reused so a paired device stays paired. Optional Android Keystore
 * wrapping changes only the key file's encoding, not the RSA identity or certificate.
 */
class AdbKeyStore internal constructor(
    private val dir: File,
    private val wrappingKey: (create: Boolean) -> SecretKey,
    private val makePrivate: (File) -> Unit,
) {
    constructor(context: Context) : this(File(context.filesDir, "phone-adb"), ::androidWrappingKey,
        { android.system.Os.chmod(it.path, "600".toInt(8)) })

    private val keyFile = File(dir, "adbkey.pk8")
    private val certFile = File(dir, "adbkey.crt")
    private val pendingKeyFile = File(dir, "adbkey.pk8.next")

    init { dir.mkdirs() }

    private data class Identity(val key: PrivateKey, val certificate: Certificate, val wrapped: Boolean = false)
    @Volatile private var cached: Identity? = null

    @Synchronized
    fun privateKey(): PrivateKey = load().key

    @Synchronized
    fun certificate(): Certificate = load().certificate

    /** A fresh installation is off; merely opening settings does not generate an identity. */
    @Synchronized
    fun protectionEnabled(): Boolean {
        if (keyFile.exists() || certFile.exists()) return load().wrapped
        discardPending()
        return false
    }

    /** One file is the commit point for both bytes and mode. Failure keeps the old identity. */
    @Synchronized
    fun setProtection(enabled: Boolean): Boolean {
        if (!enabled && !keyFile.exists() && !certFile.exists()) {
            discardPending()
            return false
        }
        val identity = load()
        if (identity.wrapped != enabled) {
            val bytes = identity.key.encoded
            replaceKey(if (enabled) encrypt(bytes, identity.certificate.encoded) else bytes)
            cached = identity.copy(wrapped = enabled)
        }
        return enabled
    }

    private fun load(): Identity {
        discardPending()
        cached?.let { return it }
        // An incomplete or unreadable existing identity must never be silently replaced.
        val pair = if (keyFile.exists() || certFile.exists()) read() else generate()
        cached = pair
        return pair
    }

    private fun read(): Identity {
        val cert = certFile.inputStream().use { CertificateFactory.getInstance("X.509").generateCertificate(it) }
        val stored = keyFile.readBytes()
        val wrapped = hasHeader(stored)
        val bytes = if (wrapped) decrypt(stored, cert.encoded) else stored
        val key = KeyFactory.getInstance("RSA").generatePrivate(PKCS8EncodedKeySpec(bytes))
        return Identity(key, cert, wrapped)
    }

    private fun generate(): Identity {
        val generator = KeyPairGenerator.getInstance("RSA").apply { initialize(2048) }
        val keyPair = generator.generateKeyPair()
        val now = System.currentTimeMillis()
        val subject = X500Principal("CN=dsh-app")
        val builder = JcaX509v3CertificateBuilder(
            subject,
            BigInteger.valueOf(now),
            Date(now - 60_000L),
            Date(now + 30L * 365 * 24 * 3600 * 1000),
            subject,
            keyPair.public,
        )
        val signer = JcaContentSignerBuilder("SHA256withRSA").build(keyPair.private)
        val cert = JcaX509CertificateConverter().getCertificate(builder.build(signer))
        val keyBytes = PKCS8EncodedKeySpec(keyPair.private.encoded).encoded
        val certBytes = cert.encoded
        var createdKey = false
        var createdCert = false
        try {
            // A failed write can leave two regular files, which load() would
            // thereafter treat as a complete identity. Roll back only names
            // created by this attempt; existing files retain the old policy.
            createdKey = keyFile.createNewFile()
            keyFile.writeBytes(keyBytes)
            createdCert = certFile.createNewFile()
            certFile.writeBytes(certBytes)
        } catch (e: Exception) {
            if (createdKey) runCatching { keyFile.delete() }
            if (createdCert) runCatching { certFile.delete() }
            throw e
        }
        runCatching {
            makePrivate(keyFile)
            makePrivate(certFile)
        }
        return Identity(keyPair.private, cert)
    }

    /** A killed migration leaves the committed key intact; discard only our uncommitted sibling. */
    private fun discardPending() { Files.deleteIfExists(pendingKeyFile.toPath()) }

    private fun replaceKey(bytes: ByteArray) {
        try {
            FileOutputStream(pendingKeyFile).use { output ->
                makePrivate(pendingKeyFile)
                output.write(bytes)
                output.fd.sync()
            }
            Files.move(pendingKeyFile.toPath(), keyFile.toPath(), ATOMIC_MOVE, REPLACE_EXISTING)
        } catch (error: Exception) {
            try { discardPending() } catch (cleanup: Exception) { error.addSuppressed(cleanup) }
            throw error
        }
    }

    private fun encrypt(bytes: ByteArray, certificate: ByteArray): ByteArray {
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.ENCRYPT_MODE, wrappingKey(true))
        check(cipher.iv.size == IV_BYTES) { "Unsupported ADB wrapping IV" }
        cipher.updateAAD(HEADER)
        cipher.updateAAD(certificate)
        return HEADER + cipher.iv + cipher.doFinal(bytes)
    }

    private fun decrypt(bytes: ByteArray, certificate: ByteArray): ByteArray {
        require(bytes.size >= HEADER.size + IV_BYTES + 16) { "Incomplete wrapped ADB key" }
        val cipher = Cipher.getInstance("AES/GCM/NoPadding")
        cipher.init(Cipher.DECRYPT_MODE, wrappingKey(false),
            GCMParameterSpec(128, bytes.copyOfRange(HEADER.size, HEADER.size + IV_BYTES)))
        cipher.updateAAD(HEADER)
        cipher.updateAAD(certificate)
        return cipher.doFinal(bytes, HEADER.size + IV_BYTES, bytes.size - HEADER.size - IV_BYTES)
    }

    companion object {
        private val HEADER = "DSHADB\u0001".toByteArray(Charsets.US_ASCII)
        private const val IV_BYTES = 12
        private const val ALIAS = "dsh.phone.adb.wrap.v1"

        private fun hasHeader(bytes: ByteArray): Boolean =
            bytes.size >= HEADER.size && HEADER.indices.all { bytes[it] == HEADER[it] }

        private fun androidWrappingKey(create: Boolean): SecretKey {
            val store = KeyStore.getInstance("AndroidKeyStore").apply { load(null) }
            store.getKey(ALIAS, null)?.let { return it as SecretKey }
            check(create) { "ADB wrapping key is unavailable" }
            return KeyGenerator.getInstance(KeyProperties.KEY_ALGORITHM_AES, "AndroidKeyStore").apply {
                init(KeyGenParameterSpec.Builder(ALIAS, KeyProperties.PURPOSE_ENCRYPT or KeyProperties.PURPOSE_DECRYPT)
                    .setKeySize(256)
                    .setBlockModes(KeyProperties.BLOCK_MODE_GCM)
                    .setEncryptionPaddings(KeyProperties.ENCRYPTION_PADDING_NONE)
                    .build())
            }.generateKey()
        }
    }
}
