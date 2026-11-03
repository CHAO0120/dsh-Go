package io.github.ccch1mneyyy.dsh_app.runtime

import java.io.File
import java.io.IOException
import java.nio.file.Files
import org.junit.After
import org.junit.Assert.*
import org.junit.Assume.assumeFalse
import org.junit.Test

/** 「重置运行环境」 keeping chosen parts of /root: [retireRuntime], [settleReset], [restoreKept]. */
class RuntimeResetKeepTest {
    private val files: File = Files.createTempDirectory("reset-keep").toFile()
    private val base = File(files, "runtime")
    private val retired = File(files, "runtime.reset")
    private val keep = File(files, "runtime-keep")
    private val locked = mutableListOf<File>()

    @After fun cleanUp() {
        locked.forEach { it.setWritable(true) }
        files.deleteRecursively()
    }

    private val ui = ResetKeep.UI_AND_SKILLS.paths
    private val plugins = ResetKeep.PLUGINS_AND_SETTINGS.paths

    private fun write(root: File, vararg paths: String) {
        for (path in paths) File(root, path).apply { parentFile!!.mkdirs() }.writeText(path.substringAfterLast('/'))
    }

    private fun text(path: String): String? = File(base, "rootfs/$path").takeIf { it.isFile }?.readText()

    /** A used runtime: the user's /root with something in each kind of place. */
    private fun installed() {
        write(
            base,
            "rootfs/bin/sh",
            "rootfs/root/.dsh/dsh-go/ui.json",
            "rootfs/root/.dsh/skills/mine/SKILL.md",
            "rootfs/root/.agents/skills/shared/SKILL.md",
            "rootfs/root/.dsh/profiles/web/package.json",
            "rootfs/root/.dsh/cordis.patch.yml",
            "rootfs/root/.dsh/.env",
            "rootfs/root/.dsh/sessions/s1.jsonl",
            "rootfs/root/.dsh/.credentials.yaml",
            "rootfs/root/workspace/notes",
            "logs/dsh.log",
        )
        File(base, "rootfs.version").writeText("r1")
    }

    /** Real layer preparation and activation with the same kept-data callback as install(). */
    private fun install(
        version: String = "r1",
        dropKept: Boolean = false,
        fresh: (File) -> Unit = {},
        checkpoint: (String) -> Unit = {},
    ) {
        settleReset(retired, keep, dropKept)
        val layers = RuntimeLayers(base)
        val next = RuntimeLayerSet(version, "arm64-v8a", "base-$version", "dsh-$version", "go-$version", "info-$version")
        val preparation = requireNotNull(layers.prepare(next, sync = {}))
        writeRuntimeLayerFixture(layers, next)
        val staged = layers.staged("base")
        write(staged, "bin/sh", "etc/os-release")
        File(staged, "root/.dsh").mkdirs()
        fresh(staged)
        val commit = layers.activate(next, preparation, sync = {}, restoreKept = { root ->
            listOf("root", "root/workspace", "tmp", "dev", "proc", "sys").forEach { File(root, it).mkdirs() }
            restoreKept(keep, root, dropKept)
        }, checkpoint = checkpoint)
    }

    private fun assertKeepFailed(block: () -> Unit) {
        try {
            block()
            fail("expected KeepFailed")
        } catch (e: KeepFailed) {
            assertTrue(e.message, e.message!!.startsWith("keep: "))
        }
    }

    /** Makes [dir] refuse renames into and out of it (skipped where permissions don't bind, as root). */
    private fun lock(dir: File) {
        dir.mkdirs()
        assertTrue(dir.setWritable(false))
        locked += dir
        assumeFalse("permissions are not enforced", dir.canWrite())
    }

    private fun assertSettled() {
        assertFalse("runtime.reset", retired.exists())
        assertFalse("runtime-keep", keep.exists())
        assertFalse("keep.trash", File(base, "keep.trash").exists())
        assertEquals("r1", File(base, "rootfs.version").readText())
    }

    private fun assertUserDataGone() {
        for (gone in listOf("root/.dsh/sessions/s1.jsonl", "root/.dsh/.credentials.yaml", "root/workspace/notes")) {
            assertNull(gone, text(gone))
        }
        assertTrue(File(base, "rootfs/root/workspace").isDirectory)
    }

    @Test fun keepsUiAndSkillsThroughResetAndInstall() {
        installed()
        retireRuntime(base, retired, keep, ui)
        assertFalse(base.exists())
        assertFalse(retired.exists())
        assertEquals("ui.json", File(keep, "root/.dsh/dsh-go/ui.json").readText())
        assertFalse(File(keep, "root/.dsh/profiles").exists())

        install()
        assertSettled()
        assertEquals("ui.json", text("root/.dsh/dsh-go/ui.json"))
        assertEquals("SKILL.md", text("root/.dsh/skills/mine/SKILL.md"))
        assertEquals("SKILL.md", text("root/.agents/skills/shared/SKILL.md"))
        for (gone in listOf("root/.dsh/profiles/web/package.json", "root/.dsh/cordis.patch.yml", "root/.dsh/.env")) {
            assertNull(gone, text(gone))
        }
        assertUserDataGone()
        assertEquals("os-release", text("etc/os-release"))
    }

    @Test fun keepsPluginsAndSettingsToo() {
        installed()
        retireRuntime(base, retired, keep, ui + plugins)
        install()
        assertSettled()
        for (path in listOf("root/.dsh/dsh-go/ui.json", "root/.dsh/profiles/web/package.json", "root/.dsh/cordis.patch.yml", "root/.dsh/.env")) {
            assertNotNull(path, text(path))
        }
        assertUserDataGone()
    }

    @Test fun keepingNothingDeletesEverything() {
        installed()
        retireRuntime(base, retired, keep, emptyList())
        assertFalse(base.exists())
        assertFalse(retired.exists())
        assertFalse(keep.exists())
        install()
        assertSettled()
        for (gone in ResetKeep.ALL) assertFalse(gone, File(base, "rootfs/$gone").exists())
    }

    @Test fun keptCopiesReplaceFreshOnes() {
        installed()
        retireRuntime(base, retired, keep, ui)
        install(fresh = { staged ->
            File(staged, "root/.dsh/skills/shipped").mkdirs()
            File(staged, "root/.dsh/skills/shipped/SKILL.md").writeText("fresh")
        })
        assertSettled()
        assertEquals("SKILL.md", text("root/.dsh/skills/mine/SKILL.md"))
        assertNull(text("root/.dsh/skills/shipped/SKILL.md"))
    }

    @Test fun symlinksMoveAsLinksAndAreNotFollowedWhenDeleting() {
        installed()
        val outside = File(files, "outside").apply { mkdirs() }
        File(outside, "precious").writeText("precious")
        Files.createSymbolicLink(File(base, "rootfs/root/workspace/link").toPath(), outside.toPath())
        Files.createSymbolicLink(File(base, "rootfs/root/.dsh/skills/linked").toPath(), outside.toPath())
        retireRuntime(base, retired, keep, ui)
        assertEquals("precious", File(outside, "precious").readText())
        install()
        val linked = File(base, "rootfs/root/.dsh/skills/linked")
        assertTrue(Files.isSymbolicLink(linked.toPath()))
        assertEquals("precious", File(linked, "precious").readText())
    }

    @Test fun aResetKilledAfterRetiringIsFinishedByTheNextInstall() {
        installed()
        File(base, "reset.keep").writeText(ui.joinToString("\n"))
        assertTrue(base.renameTo(retired)) // killed right here
        install()
        assertSettled()
        assertEquals("ui.json", text("root/.dsh/dsh-go/ui.json"))
        assertNull(text("root/.dsh/profiles/web/package.json"))
    }

    @Test fun aResetKilledWhileMovingResumesWhereItStopped() {
        installed()
        File(base, "reset.keep").writeText(ui.joinToString("\n"))
        assertTrue(base.renameTo(retired))
        File(keep, "root/.dsh").mkdirs()
        assertTrue(File(retired, "rootfs/root/.dsh/dsh-go").renameTo(File(keep, "root/.dsh/dsh-go"))) // killed here
        retireRuntime(base, retired, keep, ui) // the next reset (no runtime left) finishes it
        assertFalse(retired.exists())
        install()
        assertSettled()
        assertEquals("ui.json", text("root/.dsh/dsh-go/ui.json"))
        assertEquals("SKILL.md", text("root/.dsh/skills/mine/SKILL.md"))
    }

    @Test fun aFailedMoveKeepsTheRetiredRuntimeUntilItCanFinish() {
        installed()
        lock(File(keep, "root/.agents")) // the shared skills cannot move in
        assertKeepFailed { retireRuntime(base, retired, keep, ui) }
        assertFalse(base.exists()) // runtime reads as not installed
        assertEquals("SKILL.md", File(retired, "rootfs/root/.agents/skills/shared/SKILL.md").readText())
        assertEquals("ui.json", File(keep, "root/.dsh/dsh-go/ui.json").readText())

        // Still failing: the install stops before touching anything.
        assertKeepFailed { install() }
        assertFalse(File(base, "rootfs.version").exists())
        assertTrue(retired.exists())

        File(keep, "root/.agents").setWritable(true)
        install()
        assertSettled()
        assertEquals("SKILL.md", text("root/.agents/skills/shared/SKILL.md"))
        assertEquals("ui.json", text("root/.dsh/dsh-go/ui.json"))
    }

    @Test fun aFailedRestorePutsTheFreshCopyBackAndKeepsTheRest() {
        installed()
        retireRuntime(base, retired, keep, ui)
        lock(File(keep, "root/.agents")) // the shared skills cannot move out
        assertKeepFailed {
            install(fresh = { write(it, "root/.agents/skills/shipped/SKILL.md") })
        }
        // Not installed, nothing lost: what moved is in place, the rest still kept, the fresh copy back.
        assertFalse(File(base, "rootfs.version").exists())
        assertEquals("ui.json", text("root/.dsh/dsh-go/ui.json"))
        assertEquals("SKILL.md", File(keep, "root/.agents/skills/shared/SKILL.md").readText())
        assertEquals("SKILL.md", text("root/.agents/skills/shipped/SKILL.md"))

        // The retry extracts again; the user's home (with what was restored) carries over.
        File(keep, "root/.agents").setWritable(true)
        install()
        assertSettled()
        assertEquals("ui.json", text("root/.dsh/dsh-go/ui.json"))
        assertEquals("SKILL.md", text("root/.agents/skills/shared/SKILL.md"))
        assertNull(text("root/.agents/skills/shipped/SKILL.md"))
    }

    @Test fun aRestoreThatCannotFinishIsDroppedOnRequest() {
        installed()
        retireRuntime(base, retired, keep, ui)
        lock(File(keep, "root/.agents")) // the shared skills cannot move out
        assertKeepFailed {
            install(fresh = { write(it, "root/.agents/skills/shipped/SKILL.md") })
        }
        write(files, "runtime-keep.dropped/root/old") // left by an earlier drop cut short

        // 「不保留，继续安装」: what can move goes back, the rest is given up, the install finishes.
        install(dropKept = true)
        assertSettled()
        assertFalse(File(files, "runtime-keep.dropped").exists())
        assertEquals("ui.json", text("root/.dsh/dsh-go/ui.json"))
        assertEquals("SKILL.md", text("root/.dsh/skills/mine/SKILL.md"))
        assertNull(text("root/.agents/skills/shared/SKILL.md"))
        assertEquals("SKILL.md", text("root/.agents/skills/shipped/SKILL.md"))
    }

    @Test fun aKeepThatCannotMoveOutIsDroppedOnRequest() {
        installed()
        lock(File(keep, "root/.agents"))
        assertKeepFailed { retireRuntime(base, retired, keep, ui) }
        assertTrue(retired.exists())

        install(dropKept = true)
        assertSettled()
        assertEquals("ui.json", text("root/.dsh/dsh-go/ui.json"))
        assertEquals("SKILL.md", text("root/.dsh/skills/mine/SKILL.md"))
        assertNull(text("root/.agents/skills/shared/SKILL.md"))
    }

    @Test fun droppingWithNothingStuckRestoresEverything() {
        installed()
        retireRuntime(base, retired, keep, ui + plugins)
        install(dropKept = true)
        assertSettled()
        for (path in listOf("root/.dsh/dsh-go/ui.json", "root/.agents/skills/shared/SKILL.md", "root/.dsh/.env")) {
            assertNotNull(path, text(path))
        }
    }

    @Test fun aRetiredRuntimeWhoseDeleteWasCutShortKeepsNothingMore() {
        installed()
        retireRuntime(base, retired, keep, ui)
        install()
        // A settle that moved everything and lost its list, then was killed mid-delete.
        write(retired, "rootfs/root/.dsh/dsh-go/ui.json")
        settleReset(retired, keep)
        assertFalse(retired.exists())
        assertFalse(keep.exists())
    }

    @Test fun aRestoreKilledBeforeCommitKeepsRestoredDataOnTheReinstall() {
        installed()
        retireRuntime(base, retired, keep, ui + plugins)
        var reached = false
        try {
            install(checkpoint = {
                if (it == "home-restored") { reached = true; throw IOException("test interruption") }
            })
            fail("restore checkpoint did not interrupt")
        } catch (e: IOException) {
            assertTrue("unexpected failure before restore: $e", reached)
        }
        assertFalse(File(base, "rootfs.version").exists())
        install()
        assertSettled()
        for (path in listOf(
            "root/.dsh/dsh-go/ui.json", "root/.dsh/skills/mine/SKILL.md", "root/.agents/skills/shared/SKILL.md",
            "root/.dsh/profiles/web/package.json", "root/.dsh/cordis.patch.yml", "root/.dsh/.env",
        )) assertNotNull(path, text(path))
    }

    @Test fun theLatestResetDecidesWhatAnUnrestoredKeepHolds() {
        installed()
        retireRuntime(base, retired, keep, ui + plugins)
        // The install never ran; a fresh runtime got there some other way and is reset again.
        write(base, "rootfs/root/.dsh/dsh-go/ui.json")
        File(base, "rootfs/root/.dsh/dsh-go/ui.json").writeText("fresh")
        retireRuntime(base, retired, keep, ui)
        assertEquals("ui.json", File(keep, "root/.dsh/dsh-go/ui.json").readText())
        assertFalse(File(keep, "root/.dsh/profiles").exists())
        assertFalse(File(keep, "root/.dsh/.env").exists())

        retireRuntime(base, retired, keep, emptyList())
        assertFalse(keep.exists())
    }

    @Test fun aKeepListOnlyNamesKnownPaths() {
        installed()
        write(base, "rootfs/etc/passwd")
        File(base, "reset.keep").writeText("../../outside\nroot\netc/passwd\n root/.dsh/dsh-go \n")
        assertTrue(base.renameTo(retired))
        settleReset(retired, keep)
        assertFalse(retired.exists())
        assertEquals(listOf("dsh-go"), File(keep, "root/.dsh").list()!!.toList())
    }

    @Test fun anUnreadableKeepListTakesNothingAndDropsNothing() {
        installed()
        retireRuntime(base, retired, keep, ui)
        installed()
        assertTrue(base.renameTo(retired)) // no list, as from an older build
        settleReset(retired, keep)
        assertFalse(retired.exists())
        assertEquals("ui.json", File(keep, "root/.dsh/dsh-go/ui.json").readText())
        assertFalse(File(keep, "root/.dsh/profiles").exists())
    }

    @Test fun anUpgradeWithoutAKeepLeavesTheHomeAlone() {
        installed()
        install(version = "r2")
        assertEquals("ui.json", text("root/.dsh/dsh-go/ui.json"))
        assertEquals("notes", text("root/workspace/notes"))
        assertEquals("r2", File(base, "rootfs.version").readText())
    }

    @Test fun wireNames() {
        assertEquals(setOf(ResetKeep.UI_AND_SKILLS), ResetKeep.fromWire(listOf("uiAndSkills", "bogus")))
        assertEquals(ResetKeep.entries.toSet(), ResetKeep.fromWire(listOf("pluginsAndSettings", "uiAndSkills")))
        assertTrue(ResetKeep.fromWire(emptyList()).isEmpty())
        // No kept path lies inside another (a restore moves each one on its own).
        for (a in ResetKeep.ALL) for (b in ResetKeep.ALL) if (a != b) assertFalse("$a in $b", a.startsWith("$b/"))
    }
}
