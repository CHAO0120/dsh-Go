package io.github.ccch1mneyyy.dsh_app.runtime

import java.io.File
import java.io.IOException
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.StandardOpenOption
import org.junit.Assert.*
import org.junit.Assume.assumeNoException
import org.junit.Test

class RuntimeResetWitnessTest {
    @Test fun missingAndStrictlyInvalidRecordsNeverProveAReboot() = withFile { file ->
        val witness = RuntimeResetWitness(file) { 100 }
        assertFalse(witness.allowsIncompleteReset(false))
        witness.admitLaunch()
        assertFalse(file.exists())
        for (text in listOf("", "1000", "v1\n0\n", "v1\n-1\n", "v1\n01000\n",
            "v1\n9223372036854775808\n", "v2\n1000\n", "v1\n1000\nextra")) {
            file.writeText(text)
            assertFalse(text, witness.allowsIncompleteReset(false))
            witness.admitLaunch()
            assertEquals(text, file.readText())
        }
    }

    @Test fun aLowerPositiveTimeIsOnlyASufficientWitnessAndKnownOwnersVetoIt() = withFile { file ->
        durableDirectory(file.parentFile!!)
        var now = 1000L
        val witness = RuntimeResetWitness(file) { now }
        witness.recordFailedReset()
        assertFalse(witness.allowsIncompleteReset(false))
        now = 1200
        assertFalse(witness.allowsIncompleteReset(false))
        now = 100
        assertTrue(witness.allowsIncompleteReset(false))
        assertFalse(witness.allowsIncompleteReset(true))
        assertTrue(RuntimeResetWitness(file) { now }.allowsIncompleteReset(false))
    }

    @Test fun admittingANewBootLaunchPersistsRetirementAcrossReopening() = withFile { file ->
        durableDirectory(file.parentFile!!)
        var now = 1000L
        RuntimeResetWitness(file) { now }.recordFailedReset()
        now = 100
        val witness = RuntimeResetWitness(file) { now }
        assertTrue(witness.allowsIncompleteReset(false))
        witness.admitLaunch()
        assertEquals("v1\n100\n", file.readText())
        assertFalse(RuntimeResetWitness(file) { 101 }.allowsIncompleteReset(false))
        // A future lower time may provide a new witness; no delayed reset is scheduled.
        assertTrue(RuntimeResetWitness(file) { 50 }.allowsIncompleteReset(false))
    }

    @Test fun anAlreadyRetiredWitnessDoesNotNeedAnotherWrite() = withFile { file ->
        durableDirectory(file.parentFile!!)
        RuntimeResetWitness(file) { 100 }.recordFailedReset()
        val original = file.readBytes()
        RuntimeResetWitness(file) { 100 }.admitLaunch()
        RuntimeResetWitness(file) { 200 }.admitLaunch()
        assertArrayEquals(original, file.readBytes())
        assertFalse(RuntimeResetWitness(file) { 200 }.allowsIncompleteReset(false))
    }

    @Test fun clockFailureCannotAuthorizeResetOrAdmitPastAValidWitness() = withFile { file ->
        file.writeText("v1\n1000\n")
        for (now in listOf(0L, -1L)) {
            val witness = RuntimeResetWitness(file) { now }
            assertFalse(witness.allowsIncompleteReset(false))
            assertThrows(IOException::class.java) { witness.admitLaunch() }
            assertThrows(IOException::class.java) { witness.recordFailedReset() }
            assertEquals("v1\n1000\n", file.readText())
        }
    }

    @Test fun anUnknownReadFailureIsNotTreatedAsMissingOrInvalid() = withFile { file ->
        assertTrue(file.mkdir())
        val witness = RuntimeResetWitness(file) { 100 }
        assertThrows(IOException::class.java) { witness.admitLaunch() }
        assertThrows(IOException::class.java) { witness.allowsIncompleteReset(false) }
        assertFalse(witness.allowsIncompleteReset(true))
    }

    @Test fun failedAtomicPublicationPropagatesAndCleansOnlyItsTemporaryFile() = withFile { file ->
        file.writeText("v1\n1000\n")
        // The clock callback is a scheduling gate after the real read. Make rename fail
        // against a real nonempty directory; do not replace the writer with a throwing fake.
        val witness = RuntimeResetWitness(file) {
            check(file.delete())
            check(file.mkdir())
            File(file, "occupied").writeText("keep")
            100
        }
        assertThrows(IOException::class.java) { witness.admitLaunch() }
        assertEquals("keep", File(file, "occupied").readText())
        assertEquals(listOf(file.name), file.parentFile!!.list()!!.toList())
    }

    @Test fun symlinksAreNotAcceptedAsAnAuthorityThatMayReappearLater() = withFile { file ->
        val actual = File(file.parentFile, "elsewhere").apply { writeText("v1\n1000\n") }
        try { Files.createSymbolicLink(file.toPath(), actual.toPath()) }
        catch (unsupported: Exception) { assumeNoException(unsupported) }
        val witness = RuntimeResetWitness(file) { 100 }
        assertThrows(IOException::class.java) { witness.admitLaunch() }
        assertThrows(IOException::class.java) { witness.allowsIncompleteReset(false) }
        assertEquals("v1\n1000\n", actual.readText())
    }

    private fun withFile(test: (File) -> Unit) {
        val root = Files.createTempDirectory("reset-witness-").toFile()
        try { test(File(root, "witness")) } finally { root.deleteRecursively() }
    }

    private fun durableDirectory(directory: File) {
        // Independent platform capability probe, before calling the product writer.
        // Some host filesystems cannot force a directory; Android/Linux is the product target.
        try { FileChannel.open(directory.toPath(), StandardOpenOption.READ).use { it.force(true) } }
        catch (unsupported: IOException) { assumeNoException(unsupported) }
    }
}
