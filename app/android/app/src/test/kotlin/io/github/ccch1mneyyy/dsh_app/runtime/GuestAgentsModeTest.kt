package io.github.ccch1mneyyy.dsh_app.runtime

import java.io.File
import java.nio.file.Files
import java.nio.file.StandardOpenOption
import java.nio.file.attribute.PosixFilePermissions
import org.junit.Assume.assumeTrue
import org.junit.Assert.*
import org.junit.Test

class GuestAgentsModeTest {
    @Test fun compatibleLaunchRestoresTheExactOriginalDefaultInstructionsAfterDirect() {
        val root = kotlin.io.path.createTempDirectory("agents-mode").toFile()
        try {
            val file = File(root, "root/.dsh/AGENTS.md")
            GuestSetup.writeAgentsMd(root, phoneStorage = false)
            val original = file.readBytes()
            assertTrue(file.readText().contains("`/root/workspace`"))
            GuestSetup.writeAgentsMd(root, phoneStorage = false, directEngine = true)
            assertTrue(file.readText().contains("`${root.canonicalPath}/root/workspace`"))
            assertFalse(original.contentEquals(file.readBytes()))
            GuestSetup.writeAgentsMd(root, phoneStorage = false, directEngine = false)
            assertArrayEquals(original, file.readBytes())
        } finally { root.deleteRecursively() }
    }

    @Test fun aUserOwnedFileIsUnchangedAcrossBothLaunchModes() {
        val root = kotlin.io.path.createTempDirectory("agents-user").toFile()
        try {
            val file = File(root, "root/.dsh/AGENTS.md")
            file.parentFile.mkdirs()
            val original = "# My own workspace instructions\nKeep my paths and examples.\n".toByteArray()
            file.writeBytes(original)
            for (direct in listOf(true, false)) {
                GuestSetup.writeAgentsMd(root, phoneStorage = true, phoneControl = true, directEngine = direct)
                assertArrayEquals(original, file.readBytes())
            }
        } finally { root.deleteRecursively() }
    }

    @Test fun phoneStorageSendsOutputsToTheDshGoFolder() {
        val root = kotlin.io.path.createTempDirectory("agents-storage").toFile()
        try {
            GuestSetup.writeAgentsMd(root, phoneStorage = true)
            val text = File(root, "root/.dsh/AGENTS.md").readText()
            // The folder FilesPlugin saves into and lists, with no space to quote in shell commands.
            assertTrue(text.contains("给用户的产出文件放到 `/sdcard/Download/DSH-Go/`。"))
            assertFalse(text.contains("/sdcard/Download/DSH/"))
        } finally { root.deleteRecursively() }
    }

    @Test fun diagnosticsSectionNamesThePathForEachLaunchMode() {
        val root = kotlin.io.path.createTempDirectory("agents-diagnostics").toFile()
        try {
            val file = File(root, "root/.dsh/AGENTS.md")
            GuestSetup.writeAgentsMd(root, phoneStorage = false)
            val proot = file.readText()
            assertTrue(proot.contains("## 本机诊断"))
            assertTrue(proot.contains("`\$DSH_HOME/dsh-app/diagnostics.md`"))
            assertTrue(proot.contains("dsh-go-support"))
            GuestSetup.writeAgentsMd(root, phoneStorage = false, directEngine = true)
            val direct = file.readText()
            assertTrue(direct.contains("`${root.canonicalPath}/root/.dsh/dsh-app/diagnostics.md`"))
            assertFalse(direct.contains("\$DSH_HOME/dsh-app/diagnostics.md"))
        } finally { root.deleteRecursively() }
    }

    @Test fun diagnosticsSnapshotIsWrittenWhereTheEngineCanReadIt() {
        val root = kotlin.io.path.createTempDirectory("agents-write").toFile()
        try {
            val file = GuestSetup.writeDiagnostics(root, "# first\n")
            assertEquals(File(root, "root/.dsh/dsh-app/diagnostics.md").absoluteFile, file.absoluteFile)
            assertEquals("# first\n", file.readText())
            GuestSetup.writeDiagnostics(root, "# second\n")
            assertEquals("# second\n", file.readText())
            assertEquals(0, file.parentFile!!.listFiles()!!.count { it.name.startsWith(".diagnostics") })
        } finally { root.deleteRecursively() }
    }

    @Test fun safeDiagnosticsLeaveOriginalHomeUntouchedAndNormalDiagnosticsReturnToIt() {
        val root = kotlin.io.path.createTempDirectory("diagnostics-safe").toFile()
        try {
            val original = GuestSetup.writeDiagnostics(root, "# original\n")
            val originalBytes = original.readBytes()
            val safeFile = GuestSetup.writeDiagnostics(root, "# rescue\n", safe = true)
            assertEquals(
                File(root, "var/lib/dsh-app/safe-mode/home/dsh-app/diagnostics.md").absoluteFile,
                safeFile.absoluteFile,
            )
            assertEquals("# rescue\n", safeFile.readText())
            assertArrayEquals(originalBytes, original.readBytes())
            val normalFile = GuestSetup.writeDiagnostics(root, "# normal again\n")
            assertEquals(original.absoluteFile, normalFile.absoluteFile)
            assertEquals("# normal again\n", original.readText())
            assertEquals("# rescue\n", safeFile.readText())
        } finally { root.deleteRecursively() }
    }

    @Test fun safeDiagnosticsDoNotNeedTheOriginalHomeToBeADirectory() {
        val root = kotlin.io.path.createTempDirectory("diagnostics-broken-home").toFile()
        try {
            val originalHome = File(root, "root/.dsh")
            originalHome.parentFile.mkdirs()
            val originalBytes = "original path is not a directory\n".toByteArray()
            originalHome.writeBytes(originalBytes)
            val safeFile = GuestSetup.writeDiagnostics(root, "# rescue\n", safe = true)
            assertEquals("# rescue\n", safeFile.readText())
            assertArrayEquals(originalBytes, originalHome.readBytes())
            assertEquals(0, safeFile.parentFile!!.listFiles()!!.count { it.name.startsWith(".diagnostics") })
        } finally { root.deleteRecursively() }
    }

    @Test fun unchangedDefaultStartupDoesNotRewriteAnExistingManagedFile() {
        val root = kotlin.io.path.createTempDirectory("agents-unchanged").toFile()
        try {
            val file = File(root, "root/.dsh/AGENTS.md")
            GuestSetup.writeAgentsMd(root, phoneStorage = true, visualReplies = false)
            val original = file.readBytes()
            assertTrue(file.setLastModified(1_234_567_000L))
            val modified = file.lastModified()
            GuestSetup.writeAgentsMd(root, phoneStorage = true, visualReplies = false, directEngine = false)
            assertArrayEquals(original, file.readBytes())
            assertEquals(modified, file.lastModified())
        } finally { root.deleteRecursively() }
    }
    @Test fun aManagedUpdateLeavesAnAlreadyOpenFileComplete() {
        val root = kotlin.io.path.createTempDirectory("agents-publication").toFile()
        try {
            assumeTrue(root.toPath().fileSystem.supportedFileAttributeViews().contains("posix"))
            val file = File(root, "root/.dsh/AGENTS.md")
            GuestSetup.writeAgentsMd(root, phoneStorage = false, directEngine = true)
            val expectedUpdated = file.readBytes()
            GuestSetup.writeAgentsMd(root, phoneStorage = false)
            val original = file.readBytes()
            assertFalse(original.contentEquals(expectedUpdated))
            file.inputStream().use { opened ->
                GuestSetup.writeAgentsMd(root, phoneStorage = false, directEngine = true)
                assertArrayEquals(expectedUpdated, file.readBytes())
                assertArrayEquals(original, opened.readBytes())
            }
        } finally { root.deleteRecursively() }
    }

    @Test fun aManagedUpdatePreservesExistingPosixPermissions() {
        val root = kotlin.io.path.createTempDirectory("agents-mode-bits").toFile()
        try {
            assumeTrue(root.toPath().fileSystem.supportedFileAttributeViews().contains("posix"))
            val file = File(root, "root/.dsh/AGENTS.md")
            GuestSetup.writeAgentsMd(root, phoneStorage = false)
            val permissions = PosixFilePermissions.fromString("rw-r-----")
            Files.setPosixFilePermissions(file.toPath(), permissions)
            GuestSetup.writeAgentsMd(root, phoneStorage = false, directEngine = true)
            assertTrue(file.readText().contains("`${root.canonicalPath}/root/workspace`"))
            assertEquals(permissions, Files.getPosixFilePermissions(file.toPath()))
            assertEquals(listOf("AGENTS.md"), file.parentFile!!.list()!!.toList())
        } finally { root.deleteRecursively() }
    }

    @Test fun aNewManagedFileUsesOrdinaryFileCreationPermissions() {
        val root = kotlin.io.path.createTempDirectory("agents-default-mode").toFile()
        try {
            assumeTrue(root.toPath().fileSystem.supportedFileAttributeViews().contains("posix"))
            val control = File(root, "ordinary").also { it.writeText("control") }
            GuestSetup.writeAgentsMd(root, phoneStorage = false)
            val file = File(root, "root/.dsh/AGENTS.md")
            assertEquals(Files.getPosixFilePermissions(control.toPath()), Files.getPosixFilePermissions(file.toPath()))
        } finally { root.deleteRecursively() }
    }

    @Test fun managedSymlinksStillFollowTheirTargetsIncludingMissingTargets() {
        val root = kotlin.io.path.createTempDirectory("agents-link").toFile()
        try {
            assumeTrue(root.toPath().fileSystem.supportedFileAttributeViews().contains("posix"))
            val file = File(root, "root/.dsh/AGENTS.md")
            GuestSetup.writeAgentsMd(root, phoneStorage = false)
            val target = File(file.parentFile, "linked")
            Files.move(file.toPath(), target.toPath())
            Files.createSymbolicLink(file.toPath(), target.toPath().fileName)
            GuestSetup.writeAgentsMd(root, phoneStorage = false, directEngine = true)
            assertTrue(Files.isSymbolicLink(file.toPath()))
            assertTrue(target.readText().contains("`${root.canonicalPath}/root/workspace`"))
            Files.delete(target.toPath())
            GuestSetup.writeAgentsMd(root, phoneStorage = false)
            assertTrue(Files.isSymbolicLink(file.toPath()))
            assertTrue(target.readText().startsWith("<!-- dsh-app:managed"))
        } finally { root.deleteRecursively() }
    }

    @Test fun aReadOnlyManagedFileIsNotReplacedThroughItsWritableParent() {
        val root = kotlin.io.path.createTempDirectory("agents-read-only").toFile()
        try {
            assumeTrue(root.toPath().fileSystem.supportedFileAttributeViews().contains("posix"))
            val file = File(root, "root/.dsh/AGENTS.md")
            GuestSetup.writeAgentsMd(root, phoneStorage = false)
            val original = file.readBytes()
            val permissions = PosixFilePermissions.fromString("r--------")
            val probe = File(file.parentFile, "write-admission-probe").also { it.writeText("probe") }
            Files.setPosixFilePermissions(probe.toPath(), permissions)
            val denied = try {
                Files.newByteChannel(probe.toPath(), StandardOpenOption.WRITE).use { }
                false
            } catch (_: java.nio.file.AccessDeniedException) {
                true
            }
            assumeTrue("The real filesystem must deny WRITE for the read-only probe", denied)
            Files.setPosixFilePermissions(file.toPath(), permissions)
            GuestSetup.writeAgentsMd(root, phoneStorage = false, directEngine = true)
            assertArrayEquals(original, file.readBytes())
            assertEquals(permissions, Files.getPosixFilePermissions(file.toPath()))
        } finally { root.deleteRecursively() }
    }

}
