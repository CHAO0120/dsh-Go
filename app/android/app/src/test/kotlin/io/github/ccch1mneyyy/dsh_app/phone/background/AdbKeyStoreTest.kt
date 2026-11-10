package io.github.ccch1mneyyy.dsh_app.phone.background

import java.io.File
import java.io.IOException
import java.security.GeneralSecurityException
import javax.crypto.SecretKey
import javax.crypto.spec.SecretKeySpec
import org.junit.Assert.*
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder

/** Real identity generation, GCM, files and migration; only Android key lookup/chmod are injected. */
class AdbKeyStoreTest {
    @get:Rule val temp = TemporaryFolder()
    private val dir by lazy { temp.newFolder("adb") }
    private val keyFile get() = File(dir, "adbkey.pk8")
    private val certFile get() = File(dir, "adbkey.crt")
    private val pending get() = File(dir, "adbkey.pk8.next")
    private val aes = SecretKeySpec(ByteArray(32) { (it + 1).toByte() }, "AES")
    private val lookups = mutableListOf<Boolean>()
    private var lookup: (Boolean) -> SecretKey = { aes }

    private fun store(makePrivate: (File) -> Unit = {}): AdbKeyStore =
        AdbKeyStore(dir, { create -> lookups += create; lookup(create) }, makePrivate)

    @Test fun defaultsOffWithoutCreatingKeysOrConsultingKeystore() {
        val keys = store()
        assertFalse(keys.protectionEnabled())
        assertFalse(keys.setProtection(false))
        assertFalse(keyFile.exists())
        assertFalse(certFile.exists())
        assertTrue(lookups.isEmpty())
        val original = keys.privateKey().encoded
        assertArrayEquals(original, keyFile.readBytes())
        assertFalse(keys.protectionEnabled())
        assertTrue(lookups.isEmpty())
    }

    @Test fun bothDirectionsKeepTheRsaIdentityAndCertificateAcrossColdLoads() {
        val original = store()
        val key = original.privateKey().encoded
        val certificate = original.certificate().encoded
        val certificateFile = certFile.readBytes()
        repeat(2) {
            assertTrue(store().setProtection(true))
            assertFalse(key.contentEquals(keyFile.readBytes()))
            val wrapped = store()
            assertTrue(wrapped.protectionEnabled())
            assertArrayEquals(key, wrapped.privateKey().encoded)
            assertArrayEquals(certificate, wrapped.certificate().encoded)
            assertArrayEquals(certificateFile, certFile.readBytes())
            assertFalse(store().setProtection(false))
            assertArrayEquals(key, keyFile.readBytes())
            val plain = store()
            assertFalse(plain.protectionEnabled())
            assertArrayEquals(key, plain.privateKey().encoded)
            assertArrayEquals(certificate, plain.certificate().encoded)
            assertArrayEquals(certificateFile, certFile.readBytes())
        }
    }

    @Test fun optInBeforeFirstPairingAndRepeatedSelectionsKeepOneIdentity() {
        val keys = store()
        assertTrue(keys.setProtection(true))
        val key = keys.privateKey().encoded
        val certificate = keys.certificate().encoded
        val first = keyFile.readBytes()
        assertTrue(keys.setProtection(true))
        assertArrayEquals(first, keyFile.readBytes())
        assertTrue(store().protectionEnabled())
        assertFalse(keys.setProtection(false))
        assertFalse(keys.setProtection(false))
        assertArrayEquals(key, store().privateKey().encoded)
        assertArrayEquals(certificate, store().certificate().encoded)
    }

    @Test fun failedEncryptionLeavesThePlainIdentityAndModeUntouched() {
        val keys = store()
        val key = keys.privateKey().encoded
        val certificate = certFile.readBytes()
        lookup = { throw GeneralSecurityException("synthetic unavailable provider") }
        assertThrows(GeneralSecurityException::class.java) { keys.setProtection(true) }
        assertArrayEquals(key, keyFile.readBytes())
        assertArrayEquals(certificate, certFile.readBytes())
        assertFalse(keys.protectionEnabled())
        assertFalse(pending.exists())
    }

    @Test fun aMissingWrappingKeyOnColdLoadNeverRequestsReplacementOrResetsAdb() {
        store().setProtection(true)
        val wrapped = keyFile.readBytes()
        val certificate = certFile.readBytes()
        lookups.clear()
        lookup = { throw GeneralSecurityException("synthetic missing alias") }
        assertThrows(GeneralSecurityException::class.java) { store().setProtection(false) }
        assertEquals(listOf(false), lookups)
        assertArrayEquals(wrapped, keyFile.readBytes())
        assertArrayEquals(certificate, certFile.readBytes())
        lookup = { aes }
        assertTrue(store().protectionEnabled())
    }

    @Test fun malformedOrUnauthenticatedWrappedBytesAreNeverReplaced() {
        store().setProtection(true)
        val wrapped = keyFile.readBytes()
        val certificate = certFile.readBytes()
        val changedTag = wrapped.copyOf().apply { this[lastIndex] = (this[lastIndex].toInt() xor 1).toByte() }
        val changedHeader = wrapped.copyOf().apply { this[0] = 0 }
        for (bad in listOf(wrapped.copyOf(10), changedTag, changedHeader)) {
            keyFile.writeBytes(bad)
            assertThrows(Exception::class.java) { store().privateKey() }
            assertArrayEquals(bad, keyFile.readBytes())
            assertArrayEquals(certificate, certFile.readBytes())
        }
        keyFile.writeBytes(wrapped)
        assertTrue(store().protectionEnabled())
    }

    @Test fun failedPrivateStagingInEitherDirectionKeepsTheCommittedFile() {
        val identity = store()
        val key = identity.privateKey().encoded
        val certificate = certFile.readBytes()
        for (before in listOf(false, true)) {
            store().setProtection(before)
            val committed = keyFile.readBytes()
            val failing = store { file ->
                if (file.name.endsWith(".next")) throw IOException("synthetic chmod failure")
            }
            assertThrows(IOException::class.java) { failing.setProtection(!before) }
            assertArrayEquals(committed, keyFile.readBytes())
            assertArrayEquals(certificate, certFile.readBytes())
            assertFalse(pending.exists())
            val cold = store()
            assertEquals(before, cold.protectionEnabled())
            assertArrayEquals(key, cold.privateKey().encoded)
        }
    }

    @Test fun wrappedIdentityAuthenticatesItsExistingCertificate() {
        store().setProtection(true)
        val committed = keyFile.readBytes()
        val certificate = certFile.readBytes()
        val other = AdbKeyStore(temp.newFolder("other"), { aes }, {})
        certFile.writeBytes(other.certificate().encoded)
        assertThrows(GeneralSecurityException::class.java) { store().privateKey() }
        assertArrayEquals(committed, keyFile.readBytes())
        certFile.writeBytes(certificate)
        assertTrue(store().protectionEnabled())
    }

    @Test fun uncommittedSiblingIsRemovedBeforeReportingTheCommittedMode() {
        val keys = store()
        val key = keys.privateKey().encoded
        for (before in listOf(false, true)) {
            keys.setProtection(before)
            val committed = keyFile.readBytes()
            // Models a killed enable/disable before its atomic rename, including a plaintext sibling.
            pending.writeBytes(key)
            val cold = store()
            assertEquals(before, cold.protectionEnabled())
            assertFalse(pending.exists())
            assertArrayEquals(committed, keyFile.readBytes())
            assertArrayEquals(key, cold.privateKey().encoded)
        }
    }

    @Test fun aPartialExistingIdentityDoesNotGenerateAnotherKey() {
        val keys = store()
        val key = keys.privateKey().encoded
        val certificate = certFile.readBytes()
        assertTrue(certFile.delete())
        assertThrows(Exception::class.java) { store().privateKey() }
        assertArrayEquals(key, keyFile.readBytes())
        assertFalse(certFile.exists())
        certFile.writeBytes(certificate)
        assertTrue(keyFile.delete())
        assertThrows(Exception::class.java) { store().privateKey() }
        assertFalse(keyFile.exists())
        assertArrayEquals(certificate, certFile.readBytes())
        assertTrue(lookups.isEmpty())
    }
}
