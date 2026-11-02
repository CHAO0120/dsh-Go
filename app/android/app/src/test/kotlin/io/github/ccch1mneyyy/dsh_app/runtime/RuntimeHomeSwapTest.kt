package io.github.ccch1mneyyy.dsh_app.runtime

import java.io.File
import java.io.IOException
import java.nio.file.Files
import org.junit.Assert.*
import org.junit.Test

class RuntimeHomeSwapTest {
    private val next = RuntimeLayerSet("r2", "arm64-v8a", "base2", "dsh2", "go2", "info2")

    private fun layout(): File {
        val files = Files.createTempDirectory("rootfs-swap").toFile()
        val base = File(files, "runtime")
        for (path in listOf("rootfs/bin/old", "rootfs/root/workspace/notes"))
            File(base, path).apply { parentFile.mkdirs(); writeText(path.substringAfterLast('/')) }
        return base
    }

    private fun extract(layers: RuntimeLayers) {
        writeRuntimeLayerFixture(layers, next)
        File(layers.staged("base"), "root/skeleton").writeText("shipped")
    }

    private fun assertActivated(base: File, layers: RuntimeLayers, commit: String) {
        assertEquals("notes", File(base, "rootfs/root/workspace/notes").readText())
        assertTrue(File(base, "rootfs/bin/new").isFile)
        assertFalse(File(base, "rootfs/bin/old").exists())
        assertFalse(File(base, "rootfs/root/skeleton").exists())
        assertEquals("r2", File(base, "rootfs.version").readText())
        assertFalse(File(base, "home.carry").exists())
        val retired = File(base.parentFile, "runtime-retired/$commit/rootfs")
        assertTrue("old runtime waits for normal ready", File(retired, "bin/old").isFile)
        assertFalse(layers.cleanup(commit))
        assertTrue(layers.markReady(commit))
        assertTrue(layers.cleanup(commit))
        assertFalse(retired.exists())
        assertFalse(File(base, "layer-staging").exists())
    }

    @Test fun upgradeCarriesTheUserHomeOver() {
        val base = layout()
        try {
            val layers = RuntimeLayers(base)
            val preparation = requireNotNull(layers.prepare(next, sync = {}))
            extract(layers)
            val commit = layers.activate(next, preparation, sync = {})
            assertActivated(base, layers, commit)
        } finally {
            base.parentFile.deleteRecursively()
        }
    }

    @Test fun interruptedHomeMovesRecoverThroughTheActualLayerJournal() {
        // Completed real moves: carry home, retire old root, publish new root, restore home.
        for (stop in listOf("moved:0", "moved:2", "moved:3", "moved:4")) {
            val base = layout()
            try {
                val first = RuntimeLayers(base)
                val preparation = requireNotNull(first.prepare(next, sync = {}))
                extract(first)
                var reached = false
                try {
                    first.activate(next, preparation, sync = {}, checkpoint = {
                        if (it == stop) { reached = true; throw IOException("test interruption") }
                    })
                    fail("checkpoint did not interrupt: $stop")
                } catch (e: IOException) {
                    assertTrue("unexpected failure before $stop: $e", reached)
                }
                val resumed = RuntimeLayers(base)
                val retry = requireNotNull(resumed.prepare(next, sync = {}))
                extract(resumed)
                val commit = resumed.activate(next, retry, sync = {})
                assertActivated(base, resumed, commit)
            } finally {
                base.parentFile.deleteRecursively()
            }
        }
    }
}
