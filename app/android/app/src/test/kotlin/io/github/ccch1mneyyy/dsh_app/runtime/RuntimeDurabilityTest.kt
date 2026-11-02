package io.github.ccch1mneyyy.dsh_app.runtime

import java.io.File
import java.io.IOException
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

class RuntimeDurabilityTest {
    private val files = Files.createTempDirectory("rootfs-durable").toFile()
    private val base = File(files, "runtime")
    private val version = File(base, "rootfs.version")
    private val keep = File(files, "runtime-keep")
    private val layers = RuntimeLayers(base)
    private val next = RuntimeLayerSet("same-version", "arm64-v8a", "new-base", "new-dsh", "new-go", "new-info")

    @After fun cleanup() { files.deleteRecursively() }

    private fun write(path: String, value: String) {
        File(base, path).apply { parentFile!!.mkdirs(); writeText(value) }
    }

    private fun stage(): String {
        val preparation = requireNotNull(layers.prepare(next, sync = {}))
        writeRuntimeLayerFixture(layers, next)
        File(layers.staged("base"), "bin/new").writeText("new runtime")
        File(layers.staged("base"), "root/skeleton").writeText("fresh home")
        return preparation
    }

    private fun installed() {
        write("rootfs/bin/old", "old runtime")
        write("rootfs/root/workspace/notes", "user notes")
        version.writeText("same-version")
    }

    @Test fun theReadyMarkerFollowsRestoredDataAndTheDataBarrierEvenForTheSameVersion() {
        installed()
        File(keep, "root/.dsh/dsh-go/ui.json").apply {
            parentFile!!.mkdirs()
            writeText("kept settings")
        }
        val preparation = stage()
        val retired = File(files, "runtime-retired/$preparation/rootfs")
        val order = mutableListOf<String>()
        var syncCalls = 0
        val commit = layers.activate(next, preparation, sync = {
            if (++syncCalls == 1) {
                assertEquals("same-version", version.readText())
                assertEquals("old runtime", File(base, "rootfs/bin/old").readText())
                order.add("before-moves")
            } else {
                assertEquals(2, syncCalls)
                assertFalse(version.exists())
                assertEquals("new runtime", File(base, "rootfs/bin/new").readText())
                assertEquals("user notes", File(base, "rootfs/root/workspace/notes").readText())
                assertEquals("kept settings", File(base, "rootfs/root/.dsh/dsh-go/ui.json").readText())
                assertTrue(File(retired, "bin/old").isFile)
                order.add("data")
            }
        }, restoreKept = { root -> restoreKept(keep, root) }, checkpoint = {
            if (it == "marker-retired") {
                assertFalse(version.exists())
                assertTrue(File(base, "rootfs/bin/old").isFile)
                order.add("marker-retired")
            }
        })
        assertEquals(listOf("before-moves", "marker-retired", "data"), order)
        assertEquals("same-version", version.readText())
        assertTrue(retired.exists())
        assertFalse(layers.cleanup(commit))
        assertTrue(layers.markReady(commit))
        assertTrue(layers.cleanup(commit))
        assertFalse(retired.exists())
    }

    @Test fun aFailedPreMoveSyncLeavesTheActiveTreeHomeAndOldMarkerUntouched() {
        installed()
        val preparation = stage()
        val failure = IOException("sync before moves failed")
        val actual = assertThrows(IOException::class.java) {
            layers.activate(next, preparation, sync = { throw failure })
        }
        assertSame(failure, actual)
        assertEquals("old runtime", File(base, "rootfs/bin/old").readText())
        assertEquals("user notes", File(base, "rootfs/root/workspace/notes").readText())
        assertTrue(File(layers.staged("base"), "bin/new").isFile)
        assertFalse(File(base, "home.carry").exists())
        assertEquals("same-version", version.readText())
    }

    @Test fun aFailedDataBarrierLeavesNoReadyMarkerAndARealRetryKeepsTheHome() {
        installed()
        val preparation = stage()
        val failure = IOException("sync process failed")
        var syncCalls = 0
        val actual = assertThrows(IOException::class.java) {
            layers.activate(next, preparation, sync = { if (++syncCalls == 2) throw failure })
        }
        assertSame(failure, actual)
        assertEquals(2, syncCalls)
        assertFalse(version.exists())
        assertTrue(File(files, "runtime-retired/$preparation/rootfs/bin/old").isFile)
        assertEquals("user notes", File(base, "rootfs/root/workspace/notes").readText())
        val retry = stage() // prepare performs the production journal recovery before re-extraction.
        val commit = layers.activate(next, retry, sync = {})
        assertEquals("same-version", version.readText())
        assertEquals("user notes", File(base, "rootfs/root/workspace/notes").readText())
        assertTrue(layers.markReady(commit))
        assertTrue(layers.cleanup(commit))
    }
}
