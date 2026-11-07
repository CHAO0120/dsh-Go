package io.github.ccch1mneyyy.dsh_app.phone.background

import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.NoSuchFileException
import java.nio.file.Path
import java.nio.file.StandardCopyOption.ATOMIC_MOVE
import java.nio.file.StandardCopyOption.REPLACE_EXISTING
import java.nio.file.attribute.BasicFileAttributes
import java.nio.file.attribute.PosixFilePermissions

/** File publication for the sole production AdbKeyStore, under its existing instance lock.
 * Protects process interruption, not power-loss durability or external concurrent writers. */
internal object AdbIdentityFiles {
    fun complete(key: File, certificate: File): Boolean {
        val hasKey = present(key.toPath())
        val hasCertificate = present(certificate.toPath())
        return hasKey && hasCertificate
    }

    private fun present(path: Path): Boolean {
        val attributes = try {
            Files.readAttributes(path, BasicFileAttributes::class.java, NOFOLLOW_LINKS)
        } catch (_: NoSuchFileException) {
            return false
        }
        if (!attributes.isRegularFile) throw IOException("ADB identity path is not a regular file")
        return true
    }

    fun publish(key: File, certificate: File, keyBytes: ByteArray, certificateBytes: ByteArray) {
        val hasKey = present(key.toPath())
        val hasCertificate = present(certificate.toPath())
        if (hasKey && hasCertificate) throw IOException("ADB identity already exists")
        // Replace the existing half first. Until the missing half is published last,
        // a new load still sees an incomplete identity and follows the original generation policy.
        val order = if (hasCertificate) listOf(certificate to certificateBytes, key to keyBytes)
            else listOf(key to keyBytes, certificate to certificateBytes)
        val temporary = ArrayList<Path>(2)
        var failure: Throwable? = null
        try {
            for ((target, bytes) in order) {
                val path = Files.createTempFile(target.toPath().parent, ".adb-identity-", ".tmp",
                    PosixFilePermissions.asFileAttribute(PosixFilePermissions.fromString("rw-------")))
                temporary.add(path)
                Files.newOutputStream(path).use { it.write(bytes) }
            }
            for (index in order.indices) {
                Files.move(temporary[index], order[index].first.toPath(), ATOMIC_MOVE, REPLACE_EXISTING)
            }
        } catch (e: Throwable) {
            failure = e
            throw e
        } finally {
            // Renamed paths are absent; never roll back the final identity names.
            var cleanupFailure: Throwable? = null
            for (path in temporary) {
                try { Files.deleteIfExists(path) }
                catch (e: Throwable) {
                    val prior = failure ?: cleanupFailure
                    if (prior != null) prior.addSuppressed(e) else cleanupFailure = e
                }
            }
            cleanupFailure?.let { throw it }
        }
    }
}
