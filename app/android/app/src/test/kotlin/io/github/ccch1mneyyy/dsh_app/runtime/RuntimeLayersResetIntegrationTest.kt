package io.github.ccch1mneyyy.dsh_app.runtime

import java.io.File
import java.io.IOException
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

/** Calls the production reset/keep functions, rather than a copy of the reset algorithm. */
class RuntimeLayersResetIntegrationTest {
    private val files = Files.createTempDirectory("runtime-layers-reset").toFile()
    private val runtime = File(files, "runtime")
    private val reset = File(files, "runtime.reset")
    private val kept = File(files, "runtime.keep")
    private val layers = RuntimeLayers(runtime)
    private val set = RuntimeLayerSet("one", "arm64-v8a", "base1", "dsh1", "go1", "info1")

    @After fun cleanup() { files.deleteRecursively() }

    private fun write(file: File, value: String) {
        file.parentFile.mkdirs()
        file.writeText(value)
    }

    private fun prepare(): String {
        val id = requireNotNull(layers.prepare(set, sync = {}))
        write(File(layers.staged("base"), "usr/bin/node"), "base1")
        File(layers.staged("base"), "root").mkdirs()
        File(layers.staged("base"), "opt").mkdirs()
        File(layers.staged("base"), "etc/dsh-app").mkdirs()
        write(File(layers.staged("dsh"), "opt/dsh/package.txt"), "dsh1")
        write(File(layers.staged("go"), "opt/dsh-go/bridge.txt"), "go1")
        write(layers.stagedIdentity(), "info1")
        return id
    }

    @Test fun failedFirstInstallCarryReachesTheActualResetKeepAndNextRestore() {
        val id = prepare()
        assertThrows(IOException::class.java) {
            layers.activate(set, id, sync = {}, restoreKept = {
                write(File(it, "root/.dsh/skills/demo/SKILL.md"), "only user copy")
            }, checkpoint = { if (it == "home-restored") throw IOException("cut") })
        }
        layers.recover(sync = {})
        assertFalse(File(runtime, "rootfs").exists())
        layers.prepareReset(ResetKeep.UI_AND_SKILLS.paths, sync = {})
        retireRuntime(runtime, reset, kept, ResetKeep.UI_AND_SKILLS.paths)
        settleReset(reset, kept)
        assertEquals("only user copy", File(kept, "root/.dsh/skills/demo/SKILL.md").readText())
        assertFalse(reset.exists())
        assertFalse(runtime.exists())

        val retry = prepare()
        layers.activate(set, retry, sync = {}, restoreKept = { restoreKept(kept, it) })
        assertEquals("only user copy", File(runtime, "rootfs/root/.dsh/skills/demo/SKILL.md").readText())
    }

    @Test fun committedResetKeepsItsChoiceUntilTheActualRuntimeRetirement() {
        val id = prepare()
        val commit = layers.activate(set, id, sync = {})
        write(File(runtime, "rootfs/root/.dsh/skills/demo/SKILL.md"), "user skill")
        assertThrows(IOException::class.java) {
            layers.prepareReset(ResetKeep.UI_AND_SKILLS.paths, sync = {}, checkpoint = {
                if (it == "reset-old-removed") throw IOException("cut before runtime retirement")
            })
        }
        assertFalse(layers.markReady(commit))
        val choice = layers.pendingReset()!!
        layers.prepareReset(choice, sync = {})
        retireRuntime(runtime, reset, kept, choice)
        settleReset(reset, kept)
        assertEquals("user skill", File(kept, "root/.dsh/skills/demo/SKILL.md").readText())
        assertFalse(File(files, "runtime-retired/$commit").exists())
        assertFalse(runtime.exists())
        assertFalse(reset.exists())
        assertNotNull(layers.prepare(set, sync = {}))
    }
}
