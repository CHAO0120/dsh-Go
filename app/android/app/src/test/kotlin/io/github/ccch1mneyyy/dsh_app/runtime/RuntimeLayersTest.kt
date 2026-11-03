package io.github.ccch1mneyyy.dsh_app.runtime

import java.io.File
import java.io.IOException
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

/** Real temporary directories and the production transaction; no Android or filesystem doubles. */
class RuntimeLayersTest {
    private val files = Files.createTempDirectory("runtime-layers").toFile()
    private val runtime = File(files, "runtime")
    private val root = File(runtime, "rootfs")
    private val layers = RuntimeLayers(runtime)
    private val first = RuntimeLayerSet("one", "arm64-v8a", "base1", "dsh1", "go1", "info1")

    @After fun cleanup() { files.deleteRecursively() }

    private fun write(file: File, text: String) {
        file.parentFile.mkdirs()
        file.writeText(text)
    }

    private var preparation = ""

    private fun stage(set: RuntimeLayerSet, checkpoint: (String) -> Unit = {}) {
        preparation = requireNotNull(layers.prepare(set, sync = {}, checkpoint = checkpoint))
        for (name in layers.changed(set)) {
            val path = when (name) {
                "base" -> "usr/bin/node"
                "dsh" -> "opt/dsh/package.txt"
                else -> "opt/dsh-go/bridge.txt"
            }
            write(File(layers.staged(name), path), set.layer(name))
            if (name == "base") {
                File(layers.staged(name), "root").mkdirs()
                File(layers.staged(name), "opt").mkdirs()
                File(layers.staged(name), "etc/dsh-app").mkdirs()
            }
        }
        write(layers.stagedIdentity(), set.identity)
    }

    private fun installFirst(): String {
        stage(first)
        val commit = layers.activate(first, preparation, sync = {})
        write(File(root, "root/workspace/notes"), "user notes")
        return commit
    }

    private fun inode(file: File): Any = Files.getAttribute(file.toPath(), "unix:ino", NOFOLLOW_LINKS)

    private fun assertFirst() {
        assertEquals(first, layers.installed())
        assertTrue(layers.isCurrent(first))
        assertEquals("base1", File(root, "usr/bin/node").readText())
        assertEquals("dsh1", File(root, "opt/dsh/package.txt").readText())
        assertEquals("go1", File(root, "opt/dsh-go/bridge.txt").readText())
        assertEquals("user notes", File(root, "root/workspace/notes").readText())
    }

    @Test fun committedInstallReclaimsOldMaterialWithoutWaitingForAnEngineStart() {
        stage(first)
        val commit = layers.activate(first, preparation, sync = {})
        assertTrue(layers.isCurrent(first))
        assertFalse(File(files, "runtime-retired/$commit").exists())
        assertFalse(File(runtime, "layers.transaction.properties").exists())
    }

    @Test fun onlyGoChangesWithoutReplacingBaseDshOrHome() {
        installFirst()
        val rootInode = inode(root)
        val dshInode = inode(File(root, "opt/dsh"))
        val homeInode = inode(File(root, "root"))
        val next = first.copy(version = "two", go = "go2", identity = "info2")
        assertEquals(setOf("go"), layers.changed(next))
        stage(next)
        val commit = layers.activate(next, preparation, sync = {})
        assertEquals(rootInode, inode(root))
        assertEquals(dshInode, inode(File(root, "opt/dsh")))
        assertEquals(homeInode, inode(File(root, "root")))
        assertEquals("go2", File(root, "opt/dsh-go/bridge.txt").readText())
        assertFalse(File(files, "runtime-retired/$commit").exists())
        assertEquals("user notes", File(root, "root/workspace/notes").readText())
    }

    @Test fun sameVersionIdentityUpdateDoesNotOpenOrReplaceAnyLayer() {
        installFirst()
        val rootInode = inode(root)
        val goInode = inode(File(root, "opt/dsh-go"))
        val next = first.copy(identity = "corrected-info")
        assertTrue(layers.changed(next).isEmpty())
        assertFalse(layers.isCurrent(next))
        stage(next)
        assertFalse(layers.staged("base").exists())
        val commit = layers.activate(next, preparation, sync = {})
        assertEquals(rootInode, inode(root))
        assertEquals(goInode, inode(File(root, "opt/dsh-go")))
        assertEquals("corrected-info", File(root, "etc/dsh-app/runtime.json").readText())
        assertTrue(layers.isCurrent(next))
        assertEquals(commit, layers.installedCommit())
    }

    @Test fun baseReplacementMovesUnchangedTreesAndTheOnlyUserHome() {
        installFirst()
        val dshInode = inode(File(root, "opt/dsh"))
        val goInode = inode(File(root, "opt/dsh-go"))
        val homeInode = inode(File(root, "root"))
        val next = first.copy(version = "two", base = "base2", identity = "info2")
        stage(next)
        val commit = layers.activate(next, preparation, sync = {})
        assertEquals(dshInode, inode(File(root, "opt/dsh")))
        assertEquals(goInode, inode(File(root, "opt/dsh-go")))
        assertEquals(homeInode, inode(File(root, "root")))
        assertEquals("user notes", File(root, "root/workspace/notes").readText())
        assertFalse(File(files, "runtime-retired/$commit/rootfs/root").exists())
        assertEquals("base2", File(root, "usr/bin/node").readText())
    }

    @Test fun everyRecordedBaseMoveBoundaryCanRecoverTheOriginalGroupAndHome() {
        val next = first.copy(version = "two", base = "base2", identity = "info2")
        // Eight moves: home, two retained layers, fresh home, old/new root, home, identity.
        val points = listOf("prepared", "marker-retired") +
            (0..7).flatMap { listOf("intent:$it", "moved:$it", "done:$it") } +
            listOf("home-restored", "data-synced", "record-written")
        for (point in points) {
            files.deleteRecursively()
            files.mkdirs()
            installFirst()
            val homeInode = inode(File(root, "root"))
            stage(next)
            var reached = false
            assertThrows("$point was not reached", IOException::class.java) {
                layers.activate(next, preparation, sync = {}, checkpoint = {
                    if (it == point) { reached = true; throw IOException("interrupted at $point") }
                })
            }
            assertTrue(point, reached)
            assertFalse(point, layers.isCurrent(next))
            layers.recover(sync = {})
            assertFirst()
            assertEquals(point, homeInode, inode(File(root, "root")))
        }
    }

    @Test fun aSecondInterruptionAfterAReverseRootRenameResumesTheSameRollback() {
        installFirst()
        val homeInode = inode(File(root, "root"))
        val next = first.copy(version = "two", base = "base2", identity = "info2")
        stage(next)
        assertThrows(IOException::class.java) {
            layers.activate(next, preparation, sync = {}, checkpoint = { if (it == "home-restored") throw IOException("first cut") })
        }
        var reversed = false
        assertThrows(IOException::class.java) {
            layers.recover(sync = {}, checkpoint = {
                if (it == "reversed:5") { reversed = true; throw IOException("second cut") }
            })
        }
        assertTrue(reversed)
        assertFalse(root.exists())
        assertEquals(homeInode, inode(File(runtime, "home.carry")))
        layers.recover(sync = {})
        assertFirst()
        assertEquals(homeInode, inode(File(root, "root")))
    }

    @Test fun committedBeforeMarkerRecoversNewVersionWithoutRollingBack() {
        installFirst()
        val next = first.copy(version = "two", go = "go2", identity = "info2")
        stage(next)
        assertThrows(IOException::class.java) {
            layers.activate(next, preparation, sync = {}, checkpoint = { if (it == "committed") throw IOException("cut") })
        }
        assertFalse(File(runtime, "rootfs.version").exists())
        layers.recover(sync = {})
        assertTrue(layers.isCurrent(next))
        assertEquals("go2", File(root, "opt/dsh-go/bridge.txt").readText())
        assertFalse(File(files, "runtime-retired/${layers.installedCommit()}").exists())
    }

    @Test fun failedFirstInstallKeepsRestoredUserFilesInCarryForTheRetry() {
        stage(first)
        assertThrows(IOException::class.java) {
            layers.activate(first, preparation, sync = {}, restoreKept = { write(File(it, "root/.dsh/kept"), "only copy") },
                checkpoint = { if (it == "home-restored") throw IOException("cut") })
        }
        layers.recover(sync = {})
        assertEquals("only copy", File(runtime, "home.carry/.dsh/kept").readText())
        assertFalse(root.exists())
        // A new extraction may discard all staged payloads, but not home.carry.
        File(runtime, "layer-staging").deleteRecursively()
        stage(first)
        layers.activate(first, preparation, sync = {})
        assertEquals("only copy", File(root, "root/.dsh/kept").readText())
    }

    @Test fun anExternalRootWithTheOldVersionDoesNotAuthorizeTheOldJournal() {
        installFirst()
        val next = first.copy(version = "two", go = "go2", identity = "info2")
        stage(next)
        assertThrows(IOException::class.java) {
            layers.activate(next, preparation, sync = {}, checkpoint = { if (it == "home-restored") throw IOException("cut") })
        }
        Files.move(root.toPath(), File(files, "displaced-root").toPath())
        write(File(root, "root/workspace/notes"), "external owner")
        File(runtime, "rootfs.version").writeText(first.version)
        assertThrows(IOException::class.java) { layers.recover(sync = {}) }
        assertEquals("external owner", File(root, "root/workspace/notes").readText())
        assertEquals(first.version, File(runtime, "rootfs.version").readText())
        assertNull(layers.installed())
        File(runtime, "rootfs.version").delete()
        assertThrows(IOException::class.java) { layers.recover(sync = {}) }
        assertEquals("external owner", File(root, "root/workspace/notes").readText())
    }

    @Test fun recoveryChecksTheWholeObjectGroupBeforeUndoingAnyLiveMove() {
        installFirst()
        val next = first.copy(version = "two", go = "go2", identity = "info2")
        stage(next)
        assertThrows(IOException::class.java) {
            layers.activate(next, preparation, sync = {}, checkpoint = { if (it == "home-restored") throw IOException("cut") })
        }
        val go = File(root, "opt/dsh-go")
        Files.move(go.toPath(), File(files, "displaced-go").toPath())
        write(File(go, "bridge.txt"), "other object")
        assertThrows(IOException::class.java) { layers.recover(sync = {}) }
        // Even the later identity move must stay untouched when an earlier object is unknown.
        assertEquals("info2", File(root, "etc/dsh-app/runtime.json").readText())
        assertEquals("other object", File(go, "bridge.txt").readText())
        assertEquals("user notes", File(root, "root/workspace/notes").readText())
    }

    @Test fun currentQueryDoesNotMutateUnclaimedStagingMaterial() {
        installFirst()
        write(File(layers.staged("go"), "opt/dsh-go/next.txt"), "next candidate")
        assertTrue(layers.isCurrent(first))
        layers.recover(sync = {})
        assertEquals("next candidate", File(layers.staged("go"), "opt/dsh-go/next.txt").readText())
    }

    @Test fun aSecondUpdateCanReplaceACommittedVersionThatNeverBecameReady() {
        installFirst()
        val home = inode(File(root, "root"))
        val next = first.copy(version = "two", go = "go2", identity = "info2")
        stage(next)
        val commit = layers.activate(next, preparation, sync = {})
        write(File(root, "root/workspace/after-b"), "written by B")
        val third = next.copy(version = "three", go = "go3", identity = "info3")
        stage(third)
        assertFalse(File(files, "runtime-retired/$commit").exists())
        val latest = layers.activate(third, preparation, sync = {})
        assertTrue(layers.isCurrent(third))
        assertEquals(home, inode(File(root, "root")))
        assertEquals("user notes", File(root, "root/workspace/notes").readText())
        assertEquals("written by B", File(root, "root/workspace/after-b").readText())
        assertEquals("go3", File(root, "opt/dsh-go/bridge.txt").readText())
        assertFalse(File(files, "runtime-retired/$latest").exists())
    }

    @Test fun everyBoundaryOfReplacingAnUnreadyCommitCanRecoverAndRetryWithoutLosingHome() {
        for (baseB in listOf(false, true)) for (baseC in listOf(false, true)) {
            val second = first.copy(version = "two", base = if (baseB) "base2" else first.base,
                go = "go2", identity = "info2")
            val third = second.copy(version = "three", base = if (baseC) "base3" else second.base,
                go = "go3", identity = "info3")
            fun installB(): Pair<String, Any> {
                files.deleteRecursively(); files.mkdirs()
                installFirst()
                stage(second)
                val commit = layers.activate(second, preparation, sync = {})
                write(File(root, "root/workspace/after-b"), "written by B")
                return commit to inode(File(root, "root"))
            }
            fun installC(checkpoint: (String) -> Unit) {
                stage(third, checkpoint)
                layers.activate(third, preparation, sync = {}, checkpoint = checkpoint)
            }
            installB()
            val points = mutableListOf<String>()
            installC { points.add(it) }
            for (cut in points.indices) {
                val (oldCommit, home) = installB()
                var visited = 0
                assertThrows("baseB=$baseB baseC=$baseC ${points[cut]}", IOException::class.java) {
                    installC { if (visited++ == cut) throw IOException("cut") }
                }
                assertEquals(cut + 1, visited)
                layers.recover(sync = {})
                assertTrue(layers.isCurrent(second) || layers.isCurrent(third))
                assertEquals(home, inode(File(root, "root")))
                assertEquals("user notes", File(root, "root/workspace/notes").readText())
                assertEquals("written by B", File(root, "root/workspace/after-b").readText())
                if (!layers.isCurrent(third)) installC {}
                assertTrue(layers.isCurrent(third))
                assertEquals(home, inode(File(root, "root")))
                assertEquals("written by B", File(root, "root/workspace/after-b").readText())
                assertEquals("dsh1", File(root, "opt/dsh/package.txt").readText())
                assertEquals("go3", File(root, "opt/dsh-go/bridge.txt").readText())
                val latest = requireNotNull(layers.installedCommit())
                assertFalse(File(files, "runtime-retired/$latest").exists())
                assertEquals("written by B", File(root, "root/workspace/after-b").readText())
            }
        }
    }
    @Test fun missingJournalCanRepairPayloadsWithoutLosingTheCarriedHome() {
        installFirst()
        val next = first.copy(version = "two", base = "base2", identity = "info2")
        stage(next)
        assertThrows(IOException::class.java) {
            layers.activate(next, preparation, sync = {}, checkpoint = { if (it == "moved:1") throw IOException("cut") })
        }
        Files.delete(File(runtime, "layers.transaction.properties").toPath())
        assertFalse(layers.isCurrent(next))
        assertEquals("user notes", File(runtime, "home.carry/workspace/notes").readText())
        stage(next)
        layers.activate(next, preparation, sync = {})
        assertTrue(layers.isCurrent(next))
        assertEquals("user notes", File(root, "root/workspace/notes").readText())
    }

    @Test fun journalDirectoryIsNotTheAbsenceOfATransaction() {
        installFirst()
        File(runtime, "layers.transaction.properties").mkdir()
        assertThrows(IOException::class.java) { layers.recover(sync = {}) }
        assertFalse(layers.isCurrent(first))
        assertEquals("user notes", File(root, "root/workspace/notes").readText())
    }

    @Test fun obsoleteStagingDoesNotLockAStableInstallAndIsReclaimedOnPrepare() {
        installFirst()
        write(File(layers.staged("go"), "old.txt"), "old candidate")
        assertTrue(layers.isCurrent(first))
        assertNull(layers.prepare(first, sync = {}))
        assertFalse(File(runtime, "layer-staging").exists())
        assertFirst()
    }

    @Test fun extractionRetryDeletesOnlyItsPreparedAssetsAndKeepsStableA() {
        installFirst()
        val next = first.copy(version = "two", go = "go2", identity = "info2")
        stage(next)
        assertFalse(layers.isCurrent(first))
        val oldTicket = preparation
        stage(next)
        assertNotEquals(oldTicket, preparation)
        assertThrows(IOException::class.java) { layers.activate(next, oldTicket, sync = {}) }
        layers.activate(next, preparation, sync = {})
        assertTrue(layers.isCurrent(next))
        assertEquals("user notes", File(root, "root/workspace/notes").readText())
    }

    @Test fun preparationCannotAcceptAnExternalChangedHomeOrMarker() {
        installFirst()
        val next = first.copy(identity = "info2")
        stage(next)
        File(runtime, "rootfs.version").writeText("external")
        assertThrows(IOException::class.java) { layers.activate(next, preparation, sync = {}) }
        assertThrows(IOException::class.java) { layers.recover(sync = {}) }
        assertEquals("external", File(runtime, "rootfs.version").readText())
        assertEquals("info2", layers.stagedIdentity().readText())
    }

    @Test fun invalidJournalPreservesCurrentAndPreparedFiles() {
        installFirst()
        stage(first.copy(identity = "info2"))
        File(runtime, "layers.transaction.properties").writeText("schema=unknown\n")
        assertThrows(IOException::class.java) { layers.recover(sync = {}) }
        assertThrows(IOException::class.java) { layers.prepare(first, sync = {}) }
        assertEquals("user notes", File(root, "root/workspace/notes").readText())
        assertEquals("info2", layers.stagedIdentity().readText())
    }

    @Test fun rollbackAfterCandidateDeletionCanResumeWithoutThoseCandidateObjects() {
        installFirst()
        val next = first.copy(version = "two", base = "base2", identity = "info2")
        stage(next)
        assertThrows(IOException::class.java) {
            layers.activate(next, preparation, sync = {}, checkpoint = {
                if (it == "home-restored") throw IOException("cut applying")
            })
        }
        assertThrows(IOException::class.java) {
            layers.recover(sync = {}, checkpoint = {
                if (it == "rollback-stage-removed") throw IOException("cut cleanup")
            })
        }
        assertFalse(File(runtime, "layer-staging").exists())
        layers.recover(sync = {})
        assertFirst()
    }

    @Test fun firstFactoryHomeIsRecordedBeforeItMovesAndSurvivesRollbackCleanup() {
        for (point in listOf("intent:0", "moved:0", "done:0", "home-restored")) {
            files.deleteRecursively(); files.mkdirs()
            stage(first)
            var reached = false
            assertThrows(IOException::class.java) {
                layers.activate(first, preparation, sync = {},
                    restoreKept = { write(File(it, "root/.dsh/kept"), "only copy") },
                    checkpoint = { if (it == point) { reached = true; throw IOException("cut") } })
            }
            assertTrue(point, reached)
            layers.recover(sync = {})
            if (point == "home-restored") assertEquals("only copy", File(runtime, "home.carry/.dsh/kept").readText())
            stage(first)
            layers.activate(first, preparation, sync = {})
            if (point == "home-restored") assertEquals("only copy", File(root, "root/.dsh/kept").readText())
        }
    }

    @Test fun resetAfterPartialGarbageDeletionResumesItsSavedChoice() {
        installFirst()
        write(File(files, "runtime-retired/old/payload"), "garbage")
        val selected = listOf("root/.dsh/skills")
        assertThrows(IOException::class.java) {
            layers.prepareReset(selected, sync = {}, checkpoint = {
                if (it.startsWith("reset-garbage-deleted:")) throw IOException("cut delete")
            })
        }
        assertEquals(selected, layers.pendingReset())
        assertFalse(layers.isCurrent(first))
        layers.prepareReset(selected, sync = {})
        assertFalse(File(files, "runtime-retired").exists())
        assertEquals(selected, layers.pendingReset())
        assertEquals("user notes", File(root, "root/workspace/notes").readText())
    }

    @Test fun resetDoesNotTreatChangedGarbageIdentityAsAnAuthorizationGate() {
        installFirst()
        write(File(files, "runtime-retired/changed/owner"), "obsolete")
        layers.prepareReset(emptyList(), sync = {})
        assertFalse(File(files, "runtime-retired").exists())
        assertEquals("user notes", File(root, "root/workspace/notes").readText())
    }

    @Test fun resetRestoresTheOnlyFactoryCarryBeforeTheOriginalKeepPathReader() {
        stage(first)
        assertThrows(IOException::class.java) {
            layers.activate(first, preparation, sync = {},
                restoreKept = { write(File(it, "root/.dsh/skills/kept"), "only copy") },
                checkpoint = { if (it == "home-restored") throw IOException("cut") })
        }
        layers.recover(sync = {})
        val homeId = inode(File(runtime, "home.carry"))
        assertThrows(IOException::class.java) {
            layers.prepareReset(listOf("root/.dsh/skills"), sync = {}, checkpoint = {
                if (it == "reset-home-restored") throw IOException("cut before retiring runtime")
            })
        }
        layers.prepareReset(listOf("root/.dsh/skills"), sync = {})
        assertEquals(homeId, inode(File(root, "root")))
        assertFalse(File(runtime, "home.carry").exists())
        assertEquals("only copy", File(root, "root/.dsh/skills/kept").readText())
    }

    @Test fun resetChoosesTheCarriedUserHomeOverTheFactoryHome() {
        write(File(root, "root/notes"), "factory")
        write(File(runtime, "home.carry/notes"), "user")
        layers.prepareReset(emptyList(), sync = {})
        assertEquals("user", File(root, "root/notes").readText())
        assertFalse(File(runtime, "home.carry").exists())
    }

    @Test fun missingJournalAfterFirstGroupMovedStillPreservesRestoredHomeOnRepair() {
        stage(first)
        assertThrows(IOException::class.java) {
            layers.activate(first, preparation, sync = {},
                restoreKept = { write(File(it, "root/.dsh/kept"), "only copy") },
                checkpoint = { if (it == "home-restored") throw IOException("cut") })
        }
        File(runtime, "layers.transaction.properties").delete()
        stage(first)
        layers.activate(first, preparation, sync = {})
        assertTrue(layers.isCurrent(first))
        assertEquals("only copy", File(root, "root/.dsh/kept").readText())
    }

    @Test fun aRecordedEmptyExtractionCanRetryAndCommitLeavesAStableInstall() {
        val empty = layers.prepare(first, sync = {})
        assertTrue(File(runtime, "layer-staging").isDirectory)
        assertTrue(File(runtime, "layer-staging").list()!!.isEmpty())
        stage(first)
        assertNotEquals(empty, preparation)
        val commit = layers.activate(first, preparation, sync = {})
        assertTrue(layers.isCurrent(first))
        assertFalse(File(runtime, "layer-staging").exists())
        assertFalse(File(files, "runtime-retired").exists())
    }

    @Test fun sameTargetPrepareIsIdempotentAfterImmediateCommitCleanup() {
        installFirst()
        val next = first.copy(version = "two", go = "go2", identity = "info2")
        stage(next)
        val commit = layers.activate(next, preparation, sync = {})
        assertNull(layers.prepare(next, sync = {}))
        assertEquals(commit, layers.installedCommit())
        assertFalse(File(files, "runtime-retired/$commit").exists())
        assertEquals("user notes", File(root, "root/workspace/notes").readText())
    }

    @Test fun currentQueryDoesNotBlockRecoveryAfterExtractedStageWasAlreadyRemoved() {
        installFirst()
        val next = first.copy(version = "two", go = "go2", identity = "info2")
        stage(next)
        val abandoned = preparation
        var cut = false
        assertThrows(IOException::class.java) {
            layers.recover(sync = {}, checkpoint = {
                if (it == "extraction-stage-removed") { cut = true; throw IOException("cut after deleting stage") }
            })
        }
        assertTrue(cut)
        assertFalse(File(runtime, "layer-staging").exists())
        assertTrue(File(runtime, "layers.transaction.properties").isFile)
        // The old candidate is still unusable, before a different preparation ID even exists.
        assertThrows(IOException::class.java) { layers.activate(next, abandoned, sync = {}) }
        // RuntimeController.install makes this query before it can reach prepare/recover.
        assertFalse(layers.isCurrent(next))
        val retry = layers.prepare(next, sync = {})
        assertNotNull(retry)
        assertNotEquals(abandoned, retry)
        layers.recover(sync = {})
        assertFirst()
    }

}
