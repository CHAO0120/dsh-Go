package io.github.ccch1mneyyy.dsh_app.phone.background

import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermissions
import org.junit.Assert.*
import org.junit.Assume.assumeTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

class AdbIdentityFilesTest {
    @get:Rule val temporary = TemporaryFolder()
    private val keyBytes = byteArrayOf(1, 2, 3)
    private val certificateBytes = byteArrayOf(4, 5, 6)

    private fun directory(): File = temporary.newFolder().also {
        assumeTrue("Private temporary files require POSIX creation attributes",
            Files.getFileStore(it.toPath()).supportsFileAttributeView("posix"))
    }

    private fun publishesFrom(keyPresent: Boolean, certificatePresent: Boolean) {
        val directory = directory()
        val key = File(directory, "adbkey.pk8")
        val certificate = File(directory, "adbkey.crt")
        if (keyPresent) key.writeText("old key half")
        if (certificatePresent) certificate.writeText("old certificate half")
        assertFalse(AdbIdentityFiles.complete(key, certificate))
        AdbIdentityFiles.publish(key, certificate, keyBytes, certificateBytes)
        assertTrue(AdbIdentityFiles.complete(key, certificate))
        assertArrayEquals(keyBytes, key.readBytes())
        assertArrayEquals(certificateBytes, certificate.readBytes())
        assertEquals(setOf("adbkey.pk8", "adbkey.crt"), directory.list()!!.toSet())
        val permissions = PosixFilePermissions.fromString("rw-------")
        assertEquals(permissions, Files.getPosixFilePermissions(key.toPath()))
        assertEquals(permissions, Files.getPosixFilePermissions(certificate.toPath()))
    }

    @Test fun publishesAnInitiallyMissingPair() = publishesFrom(false, false)
    @Test fun replacesTheExistingKeyBeforePublishingTheMissingCertificate() = publishesFrom(true, false)
    @Test fun replacesTheExistingCertificateBeforePublishingTheMissingKey() = publishesFrom(false, true)

    @Test fun existingPairIsNotRegeneratedEvenWhenItsBytesAreNotParseable() {
        val directory = directory()
        val key = File(directory, "adbkey.pk8").apply { writeText("existing key") }
        val certificate = File(directory, "adbkey.crt").apply { writeText("existing certificate") }
        assertTrue(AdbIdentityFiles.complete(key, certificate))
        try {
            AdbIdentityFiles.publish(key, certificate, keyBytes, certificateBytes)
            fail("An existing pair must not be replaced")
        } catch (_: IOException) { }
        assertEquals("existing key", key.readText())
        assertEquals("existing certificate", certificate.readText())
        assertEquals(2, directory.list()!!.size)
    }

    @Test fun aDirectoryIsNotAMissingHalf() {
        val directory = directory()
        val key = File(directory, "adbkey.pk8").apply { mkdir() }
        val certificate = File(directory, "adbkey.crt")
        try {
            AdbIdentityFiles.publish(key, certificate, keyBytes, certificateBytes)
            fail("A directory must be rejected")
        } catch (_: IOException) { }
        assertTrue(key.isDirectory)
        assertFalse(certificate.exists())
        assertEquals(1, directory.list()!!.size)
    }

    @Test fun aDanglingLinkIsNotAMissingHalf() {
        val directory = directory()
        val key = File(directory, "adbkey.pk8")
        val absent = File(directory, "absent")
        Files.createSymbolicLink(key.toPath(), absent.toPath())
        val certificate = File(directory, "adbkey.crt")
        try {
            AdbIdentityFiles.publish(key, certificate, keyBytes, certificateBytes)
            fail("A link must be rejected without following it")
        } catch (_: IOException) { }
        assertTrue(Files.isSymbolicLink(key.toPath()))
        assertFalse(absent.exists())
        assertFalse(certificate.exists())
    }
}
