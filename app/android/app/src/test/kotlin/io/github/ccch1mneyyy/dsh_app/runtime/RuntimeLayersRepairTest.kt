package io.github.ccch1mneyyy.dsh_app.runtime

import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.attribute.PosixFilePermissions
import java.util.Properties
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

/** Real file replacements and permissions: stable edits are repaired, not an ownership lock. */
class RuntimeLayersRepairTest {
    private val files = Files.createTempDirectory("runtime-layer-repair").toFile()
    private val runtime = File(files, "runtime")
    private val root = File(runtime, "rootfs")
    private val layers = RuntimeLayers(runtime)
    private val first = RuntimeLayerSet("one", "arm64-v8a", "base1", "dsh1", "go1", "info1")

    @After fun cleanup() { files.deleteRecursivelySafely() }

    private fun write(file: File, value: String) { file.parentFile.mkdirs(); file.writeText(value) }
    private fun inode(file: File) = Files.getAttribute(file.toPath(), "unix:ino", NOFOLLOW_LINKS)
    private fun install(set: RuntimeLayerSet = first, checkpoint: (String) -> Unit = {}) {
        val id = requireNotNull(layers.prepare(set, sync = {}))
        writeRuntimeLayerFixture(layers, set)
        layers.activate(set, id, sync = {}, checkpoint = checkpoint)
    }
    private fun installedHome(): Any {
        install()
        write(File(root, "root/workspace/notes"), "user notes")
        return inode(File(root, "root"))
    }
    private fun assertHome(id: Any) {
        assertEquals(id, inode(File(root, "root")))
        assertEquals("user notes", File(root, "root/workspace/notes").readText())
        assertTrue(layers.isCurrent(first))
    }
    private fun editProperties(file: File, edit: (Properties) -> Unit) {
        val p = Properties().apply { file.inputStream().use { load(it) } }
        edit(p)
        file.outputStream().use { p.store(it, null) }
    }

    @Test fun editorReplacementOfRuntimeJsonIsRepairedWithoutReplacingPayloadOrHome() {
        val home = installedHome()
        val base = inode(root)
        val info = File(root, "etc/dsh-app/runtime.json")
        val original = inode(info)
        Files.move(info.toPath(), File(files, "saved-info").toPath())
        write(info, "user edit")
        assertNotEquals(original, inode(info))
        assertFalse(layers.isCurrent(first))
        assertTrue(layers.changed(first).isEmpty())
        install()
        assertEquals("info1", info.readText())
        assertEquals(base, inode(root))
        assertHome(home)
    }

    @Test fun missingGoLayerIsReinstalledWithoutReplacingDshBaseOrHome() {
        val home = installedHome()
        val base = inode(root)
        val dsh = inode(File(root, "opt/dsh"))
        File(root, "opt/dsh-go").deleteRecursively()
        assertFalse(layers.isCurrent(first))
        assertEquals(setOf("go"), layers.changed(first))
        install()
        assertEquals("go1", File(root, "opt/dsh-go/bridge.txt").readText())
        assertEquals(base, inode(root))
        assertEquals(dsh, inode(File(root, "opt/dsh")))
        assertHome(home)
    }

    @Test fun aRecreatedHomeIsPreservedInsteadOfRejectedByItsOldInode() {
        val old = installedHome()
        val home = File(root, "root")
        val saved = File(files, "saved-home")
        Files.move(home.toPath(), saved.toPath())
        saved.copyRecursively(home)
        val recreated = inode(home)
        assertNotEquals(old, recreated)
        assertFalse(layers.isCurrent(first))
        install()
        assertHome(recreated)
    }

    @Test fun restoredRootTreeWithNewInodesCanRepairWhileKeepingItsRestoredHome() {
        installedHome()
        val saved = File(files, "backup-rootfs")
        Files.move(root.toPath(), saved.toPath())
        saved.copyRecursively(root)
        val home = inode(File(root, "root"))
        assertFalse(layers.isCurrent(first))
        assertEquals(RuntimeLayers.NAMES.toSet(), layers.changed(first))
        install()
        assertHome(home)
    }

    @Test fun aDeletedHomeIsRecreatedWithoutLockingInstallation() {
        installedHome()
        File(root, "root").deleteRecursively()
        assertFalse(layers.isCurrent(first))
        install()
        assertTrue(File(root, "root").isDirectory)
        assertTrue(layers.isCurrent(first))
    }

    @Test fun oldDeviceNumbersAreIgnoredInStableAndInterruptedTransactionIdentities() {
        val home = installedHome()
        editProperties(File(runtime, "layers.installed.properties")) { p ->
            for (key in p.stringPropertyNames()) if (key == "root" || key.startsWith("object."))
                p.setProperty(key, "999999:${p.getProperty(key)}")
        }
        assertTrue(layers.isCurrent(first))
        val next = first.copy(go = "go2", identity = "info2")
        val id = requireNotNull(layers.prepare(next, sync = {}))
        writeRuntimeLayerFixture(layers, next)
        assertThrows(IOException::class.java) {
            layers.activate(next, id, sync = {}, checkpoint = { if (it == "moved:0") throw IOException("cut") })
        }
        editProperties(File(runtime, "layers.transaction.properties")) { p ->
            for (key in p.stringPropertyNames()) {
                if (key in setOf("oldRoot", "newRoot", "staging", "retired") || key.endsWith(".identity")) {
                    val value = p.getProperty(key)
                    if (value.matches(Regex("[0-9]+"))) p.setProperty(key, "777777:$value")
                }
            }
        }
        layers.recover(sync = {})
        assertHome(home)
    }

    @Test fun malformedOrDirectoryInstallationRecordsReturnFalseAndCanBeRepaired() {
        for (state in listOf("absent", "invalid", "directory")) {
            files.deleteRecursivelySafely(); files.mkdirs()
            val home = installedHome()
            val record = File(runtime, "layers.installed.properties")
            record.delete()
            if (state == "directory") record.mkdir()
            if (state == "invalid") record.writeText("schema=broken\n")
            assertFalse(layers.isCurrent(first))
            install()
            assertHome(home)
        }
    }

    @Test fun oldArchiveGarbageAndModeZeroDirectoriesAreReclaimedBeforeExtraction() {
        val home = installedHome()
        for (name in listOf("staging", "rootfs.old")) {
            val dir = File(runtime, "$name/locked")
            write(File(dir, "payload"), "obsolete")
            Files.setPosixFilePermissions(dir.toPath(), PosixFilePermissions.fromString("---------"))
        }
        val retired = File(files, "runtime-retired/orphan/locked")
        write(File(retired, "payload"), "obsolete")
        Files.setPosixFilePermissions(retired.toPath(), PosixFilePermissions.fromString("---------"))
        assertNull(layers.prepare(first, sync = {}))
        assertFalse(File(runtime, "staging").exists())
        assertFalse(File(runtime, "rootfs.old").exists())
        assertFalse(File(files, "runtime-retired").exists())
        assertHome(home)
    }

    @Test fun interruptedCommittedCleanupIsNotANewStableIdentityGate() {
        val home = installedHome()
        val next = first.copy(go = "go2", identity = "info2")
        assertThrows(IOException::class.java) {
            install(next) { if (it.startsWith("cleanup-deleted:")) throw IOException("cut cleanup") }
        }
        val info = File(root, "etc/dsh-app/runtime.json")
        Files.move(info.toPath(), File(files, "old-info").toPath())
        write(info, "changed after commit")
        assertFalse(layers.isCurrent(next))
        install(next)
        assertTrue(layers.isCurrent(next))
        assertEquals(home, inode(File(root, "root")))
        assertEquals("user notes", File(root, "root/workspace/notes").readText())
    }

    @Test fun interruptionAfterRecreatingAMissingHomeCanRecoverAndRepairAgain() {
        installedHome()
        File(root, "root").deleteRecursively()
        assertThrows(IOException::class.java) {
            install { if (it == "home-created") throw IOException("cut") }
        }
        layers.recover(sync = {})
        assertFalse(layers.isCurrent(first))
        install()
        assertTrue(layers.isCurrent(first))
        assertTrue(File(root, "root").isDirectory)
    }


    @Test fun lostJournalAfterFirstHomeMoveCanReinstallTheSameBaseAndRestoreCarry() {
        val home = installedHome()
        val next = first.copy(base = "base2", identity = "info2")
        assertThrows(IOException::class.java) {
            install(next) { if (it == "moved:0") throw IOException("cut after home to carry") }
        }
        File(runtime, "layers.transaction.properties").delete()
        assertFalse(File(root, "root").exists())
        assertEquals(home, inode(File(runtime, "home.carry")))
        assertEquals(setOf("base"), layers.changed(first))
        install(first)
        assertFalse(File(runtime, "home.carry").exists())
        assertHome(home)
    }

}
