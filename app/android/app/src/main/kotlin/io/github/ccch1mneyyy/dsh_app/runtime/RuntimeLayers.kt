package io.github.ccch1mneyyy.dsh_app.runtime

import java.io.File
import java.io.IOException
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.LinkOption.NOFOLLOW_LINKS
import java.nio.file.StandardCopyOption.ATOMIC_MOVE
import java.nio.file.StandardOpenOption.READ
import java.util.Base64
import java.util.Properties
import java.util.UUID

/** Factory payload identities, not hashes of the user's writable installed files. */
internal data class RuntimeLayerSet(
    val version: String,
    val abi: String,
    val base: String,
    val dsh: String,
    val go: String,
    val identity: String,
) {
    fun layer(name: String): String = when (name) {
        "base" -> base
        "dsh" -> dsh
        "go" -> go
        else -> error("unknown runtime layer")
    }
}

/** Install/recovery runs with the engine stopped; the caller serializes ready cleanup with installs. */
internal class RuntimeLayers(private val runtime: File) {
    private val files = runtime.parentFile
    private val root = File(runtime, "rootfs")
    private val marker = File(runtime, "rootfs.version")
    private val record = File(runtime, "layers.installed.properties")
    private val journal = File(runtime, "layers.transaction.properties")
    private val staging = File(runtime, "layer-staging")
    private val carry = File(runtime, "home.carry")

    private data class Identity(val dev: Long, val ino: Long) {
        override fun toString() = "$dev:$ino"
    }

    private data class Move(val from: File, val to: File, val identity: String)

    fun staged(name: String): File {
        require(name in NAMES)
        return File(staging, name)
    }

    fun stagedIdentity(): File = File(staging, "runtime-info.json")

    fun installed(): RuntimeLayerSet? {
        if (!record.isFile) return null
        val p = read(record)
        if (identity(root)?.toString() != p.getProperty("root")) return null
        return getSet(p, "current")
    }

    fun installedCommit(): String? = if (installed() == null) null else read(record).getProperty("commit")

    fun changed(next: RuntimeLayerSet): Set<String> {
        val old = installed()
        return NAMES.filterTo(linkedSetOf()) { old == null || old.abi != next.abi || old.layer(it) != next.layer(it) }
    }

    /** A stable installed A is checked independently from the requested target B. */
    fun isCurrent(next: RuntimeLayerSet): Boolean {
        val p = transaction()
        if (p == null) checkStable()
        else when (p.getProperty("phase")) {
            "extracting" -> { checkPreparation(p, allowRemovedStage = true); return false }
            "applying", "resetting" -> { checkRoot(p); return false }
            "committed", "ready" -> checkCommit(p)
        }
        return installed() == next && marker.isFile && marker.readText() == next.version
    }

    /** Claim a pure-asset candidate before extraction. Never discard an unexplained tree. */
    fun prepare(next: RuntimeLayerSet, sync: () -> Unit, checkpoint: (String) -> Unit = {}): String? {
        recover(sync)
        checkpoint("preparation-recovered")
        if (isCurrent(next)) return null
        transaction()?.let { p ->
            if (p.getProperty("phase") !in setOf("committed", "ready"))
                throw IOException("previous runtime has an unfinished transaction")
            // A new installation also authorizes retiring the prior rollback material. It must
            // be able to repair a version that never started, while keeping its active home.
            if (p.getProperty("phase") == "committed") {
                checkCommit(p)
                p.setProperty("phase", "ready")
                write(journal, p)
                checkpoint("previous-retirable")
            }
            cleanup(p.getProperty("id"), checkpoint)
        }
        checkStable()
        runtime.mkdirs()
        val id = UUID.randomUUID().toString()
        val p = Properties().apply {
            setProperty("schema", "1")
            setProperty("id", id)
            setProperty("phase", "extracting")
            setProperty("oldRoot", identity(root)?.toString() ?: "absent")
            setProperty("oldCarry", identity(carry)?.toString() ?: "absent")
            setProperty("oldRecord", snapshot(record))
            setProperty("oldMarker", snapshot(marker))
            setProperty("staging", identity(staging)?.toString() ?: "absent")
            putSet(this, "next", next)
        }
        write(journal, p)
        checkpoint("extraction-recorded")
        staging.mkdirs()
        checkpoint("extraction-created")
        p.setProperty("staging", identity(staging).toString())
        write(journal, p)
        checkpoint("extraction-prepared")
        return id
    }

    /**
     * Staged trees were already verified by the installer. A failed IO leaves the journal for
     * recover(), never a successful marker. checkpoint reports completed real disk boundaries.
     */
    fun activate(
        next: RuntimeLayerSet,
        preparation: String,
        sync: () -> Unit,
        restoreKept: (File) -> Unit = {},
        checkpoint: (String) -> Unit = {},
    ): String {
        val prepared = transaction() ?: throw IOException("runtime extraction was not prepared")
        if (prepared.getProperty("phase") != "extracting" || prepared.getProperty("id") != preparation ||
            getSet(prepared, "next") != next) throw IOException("runtime preparation changed")
        checkPreparation(prepared)
        val changes = changed(next)
        val id = preparation
        val retired = File(files, "runtime-retired/$id")
        val moves = mutableListOf<Move>()
        val oldRoot = identity(root)?.toString()
        var newRoot = oldRoot
        var factoryHome: String? = null
        fun add(from: File, to: File, known: String? = null) {
            val obj = known ?: identity(from)?.toString() ?: throw IOException("missing runtime object: $from")
            moves.add(Move(from, to, obj))
        }
        if ("base" in changes) {
            val base = staged("base")
            newRoot = identity(base)?.toString() ?: throw IOException("missing staged base")
            // Only new factory objects move here; no live/user tree has moved yet.
            for (name in listOf("dsh", "go")) {
                val target = File(base, layerPath(name))
                if (name in changes) rename(File(staged(name), layerPath(name)), target)
                else add(File(root, layerPath(name)), target)
            }
            val home = File(root, "root")
            val freshHome = File(base, "root")
            val homeId = identity(carry)?.toString() ?: identity(home)?.toString() ?: run {
                if (!present(freshHome)) freshHome.mkdirs()
                identity(freshHome)?.toString() ?: throw IOException("missing factory home")
            }
            if (!present(carry)) {
                if (present(home)) moves.add(0, Move(home, carry, homeId))
                else {
                    factoryHome = homeId
                    moves.add(0, Move(freshHome, carry, homeId))
                }
            }
            if (present(freshHome) && factoryHome == null) add(freshHome, File(retired, "fresh-home"))
            if (oldRoot != null) add(root, File(retired, "rootfs"), oldRoot)
            add(base, root, newRoot)
            add(carry, File(root, "root"), homeId)
        } else {
            for (name in listOf("dsh", "go")) if (name in changes) {
                val live = File(root, layerPath(name))
                add(live, File(retired, name))
                add(File(staged(name), layerPath(name)), live)
            }
        }
        val info = File(root, "etc/dsh-app/runtime.json")
        // With a new base this path is deliberately absent from its payload.
        if ("base" !in changes && present(info)) add(info, File(retired, "runtime-info.json"))
        add(stagedIdentity(), info)
        val p = Properties().apply {
            setProperty("schema", "1")
            setProperty("id", id)
            setProperty("retired", "absent")
            setProperty("staging", prepared.getProperty("staging"))
            factoryHome?.let { setProperty("factoryHome", it) }
            setProperty("phase", "applying")
            setProperty("applied", "0")
            setProperty("oldRoot", oldRoot ?: "absent")
            setProperty("newRoot", newRoot ?: throw IOException("missing runtime root"))
            setProperty("oldRecord", snapshot(record))
            setProperty("oldMarker", snapshot(marker))
            putSet(this, "next", next)
            setProperty("moves", moves.size.toString())
            moves.forEachIndexed { i, move ->
                setProperty("move.$i.from", relative(move.from))
                setProperty("move.$i.to", relative(move.to))
                setProperty("move.$i.identity", move.identity)
            }
        }
        sync()
        write(journal, p)
        checkpoint("prepared")
        retired.mkdirs()
        p.setProperty("retired", identity(retired).toString())
        write(journal, p)
        if (Files.deleteIfExists(marker.toPath())) force(runtime)
        checkpoint("marker-retired")
        for ((index, move) in moves.withIndex()) {
            p.setProperty("intent", "forward:$index")
            write(journal, p)
            checkpoint("intent:$index")
            move(move)
            checkpoint("moved:$index")
            p.setProperty("applied", (index + 1).toString())
            p.remove("intent")
            write(journal, p)
            checkpoint("done:$index")
        }
        restoreKept(root)
        checkpoint("home-restored")
        sync()
        checkpoint("data-synced")
        val installed = Properties().apply {
            setProperty("schema", "1")
            setProperty("root", newRoot)
            setProperty("commit", id)
            putSet(this, "current", next)
            for ((name, path) in liveObjects()) setProperty("object.$name", identity(path)?.toString()
                ?: throw IOException("missing committed runtime object: $name"))
        }
        write(record, installed)
        checkpoint("record-written")
        p.setProperty("phase", "committed")
        write(journal, p)
        checkpoint("committed")
        writeBytes(marker, next.version.toByteArray(Charsets.UTF_8))
        checkpoint("marker-written")
        return id
    }

    /** Restores an incomplete group, or repairs a committed group's final compatibility marker. */
    fun recover(sync: () -> Unit, checkpoint: (String) -> Unit = {}) {
        val p = transaction() ?: run { checkStable(); return }
        if (p.getProperty("phase") == "extracting") {
            checkPreparation(p, allowRemovedStage = true)
            removePreparedStage(p)
            checkpoint("extraction-stage-removed")
            Files.delete(journal.toPath())
            force(runtime)
            return
        }
        if (p.getProperty("phase") == "resetting") {
            checkCommit(p)
            return // Only the explicit reset caller may continue this saved reset.
        }
        if (p.getProperty("rollbackComplete") == "true") {
            finishRollback(p, sync, checkpoint)
            return
        }
        checkRoot(p)
        if (p.getProperty("phase") in setOf("committed", "ready")) {
            checkCommit(p)
            writeBytes(marker, getSet(p, "next").version.toByteArray(Charsets.UTF_8))
            return
        }
        var applied = p.getProperty("applied").toInt()
        val pending = p.getProperty("intent")
        if (pending != null) {
            val (direction, number) = pending.split(':')
            val index = number.toInt()
            val action = getMove(p, index)
            val from = identity(action.from)?.toString()
            val to = identity(action.to)?.toString()
            applied = when {
                from == action.identity && to == null -> index
                from == null && to == action.identity -> index + 1
                else -> throw IOException("runtime rename ownership changed ($direction:$index)")
            }
            p.remove("intent")
            p.setProperty("applied", applied.toString())
            write(journal, p)
        }
        verifyPositions(p, applied)
        for (index in applied - 1 downTo 0) {
            val action = getMove(p, index)
            // restoreKept may have put the only user copy into this factory home.
            // Keep it in carry rather than return it to disposable extraction assets.
            if (index == 0 && action.identity == p.getProperty("factoryHome")) break
            p.setProperty("intent", "reverse:$index")
            write(journal, p)
            checkpoint("reverse-intent:$index")
            move(Move(action.to, action.from, action.identity))
            checkpoint("reversed:$index")
            p.setProperty("applied", index.toString())
            p.remove("intent")
            write(journal, p)
        }
        for ((name, path) in liveObjects() + ("carry" to carry))
            p.setProperty("rollback.$name", identity(path)?.toString() ?: "absent")
        p.setProperty("rollbackRecord", snapshot(record))
        p.setProperty("rollbackMarker", snapshot(marker))
        p.setProperty("rollbackComplete", "true")
        write(journal, p)
        checkpoint("rollback-complete")
        finishRollback(p, sync, checkpoint)
    }

    private fun finishRollback(p: Properties, sync: () -> Unit, checkpoint: (String) -> Unit) {
        for ((name, path) in liveObjects() + ("carry" to carry)) {
            if ((identity(path)?.toString() ?: "absent") != p.getProperty("rollback.$name"))
                throw IOException("rolled back runtime object changed: $name")
        }
        if (snapshot(record) !in setOf(p.getProperty("rollbackRecord"), p.getProperty("oldRecord")) ||
            snapshot(marker) !in setOf(p.getProperty("rollbackMarker"), p.getProperty("oldMarker")))
            throw IOException("rolled back runtime record changed")
        removePreparedStage(p)
        checkpoint("rollback-stage-removed")
        removeRetired(p)
        checkpoint("rollback-retired-removed")
        sync()
        restore(record, p.getProperty("oldRecord"))
        restore(marker, p.getProperty("oldMarker"))
        Files.delete(journal.toPath())
        force(runtime)
    }

    /** Saved reset choices survive until the existing reset retirement moves this journal. */
    fun pendingReset(): List<String>? {
        val p = transaction() ?: return null
        if (p.getProperty("phase") != "resetting") return null
        return (0 until p.getProperty("reset.count").toInt()).map { p.getProperty("reset.$it") }
    }

    /** Explicit reset authority, not evidence that an engine reached normal ready. */
    fun prepareReset(keep: List<String>, sync: () -> Unit, checkpoint: (String) -> Unit = {}) {
        recover(sync)
        if (present(carry)) {
            identity(carry)
            if (!Files.isDirectory(carry.toPath(), NOFOLLOW_LINKS)) throw IOException("invalid runtime carry")
            val home = File(root, "root")
            if (present(home)) throw IOException("runtime has two user homes")
            if (present(root)) identity(root) else root.mkdirs()
            if (!Files.isDirectory(root.toPath(), NOFOLLOW_LINKS)) throw IOException("invalid runtime root")
            rename(carry, home)
            checkpoint("reset-home-restored")
        }
        val p = transaction() ?: return
        if (p.getProperty("phase") == "resetting") {
            if (pendingReset() != keep) throw IOException("runtime reset selection changed")
            checkCommit(p)
        } else {
            if (p.getProperty("phase") !in setOf("committed", "ready"))
                throw IOException("runtime reset has an unfinished transaction")
            checkCommit(p)
            p.setProperty("phase", "resetting")
            p.setProperty("reset.count", keep.size.toString())
            keep.forEachIndexed { i, value -> p.setProperty("reset.$i", value) }
            write(journal, p)
            checkpoint("reset-recorded")
        }
        removeRetired(p) { checkpoint("reset-deleted:$it") }
        sync()
        force(File(files, "runtime-retired"))
        checkpoint("reset-old-removed")
        // Keep the journal: the caller still has to retire runtime to runtime.reset.
    }

    /** The controller supplies the commit captured by this normal engine start, not global state. */
    fun markReady(commit: String): Boolean {
        if (!journal.isFile) return false
        val p = read(journal)
        if (p.getProperty("id") != commit || p.getProperty("phase") !in setOf("committed", "ready")) return false
        if (installedCommit() != commit) return false
        checkCommit(p)
        p.setProperty("phase", "ready")
        write(journal, p)
        return true
    }

    /** Run off the main thread. A failed delete retains the ready record for a later retry. */
    fun cleanup(commit: String, checkpoint: (String) -> Unit = {}): Boolean {
        if (!journal.isFile) return false
        val p = read(journal)
        if (p.getProperty("id") != commit || p.getProperty("phase") != "ready") return false
        if (installedCommit() != commit) return false
        checkCommit(p)
        removeRetired(p) { checkpoint("cleanup-deleted:$it") }
        checkpoint("cleanup-retired-removed")
        removeEmpty(staging)
        checkpoint("cleanup-stage-removed")
        Files.delete(journal.toPath())
        force(runtime)
        checkpoint("cleanup-journal-removed")
        return true
    }

    private fun transaction(): Properties? {
        if (!present(journal)) return null
        if (!Files.isRegularFile(journal.toPath(), NOFOLLOW_LINKS)) throw IOException("runtime journal is not a regular file")
        return read(journal).also {
            if (it.getProperty("phase") !in setOf("extracting", "applying", "committed", "ready", "resetting"))
                throw IOException("invalid runtime journal phase")
        }
    }

    private fun liveObjects(): Map<String, File> = linkedMapOf(
        "root" to root, "home" to File(root, "root"), "dsh" to File(root, layerPath("dsh")),
        "go" to File(root, layerPath("go")), "identity" to File(root, "etc/dsh-app/runtime.json"),
    )

    /** No hashes of writable payload contents: only the fixed participating directory objects. */
    private fun checkInstalledGroup() {
        if (!Files.isRegularFile(record.toPath(), NOFOLLOW_LINKS)) throw IOException("invalid runtime installation record")
        val p = read(record)
        for ((name, path) in liveObjects()) {
            val expected = p.getProperty("object.$name") ?: throw IOException("missing runtime object record")
            if (identity(path)?.toString() != expected) throw IOException("installed runtime object changed: $name")
        }
        if (identity(root)?.toString() != p.getProperty("root")) throw IOException("runtime root changed")
    }

    private fun checkStable() {
        val retired = File(files, "runtime-retired")
        if (present(staging) || (present(retired) &&
                (!Files.isDirectory(retired.toPath(), NOFOLLOW_LINKS) ||
                    (retired.listFiles() ?: throw IOException("cannot inspect retired runtime")).isNotEmpty())))
            throw IOException("runtime transaction material has no journal")
        if (!present(record)) return // First installation or the existing single-archive layout.
        checkInstalledGroup()
        if (present(carry) || !marker.isFile || marker.readText() != getSet(read(record), "current").version)
            throw IOException("runtime installation marker or home is inconsistent")
    }

    private fun checkPreparation(p: Properties, allowRemovedStage: Boolean = false) {
        if ((identity(root)?.toString() ?: "absent") != p.getProperty("oldRoot") ||
            (identity(carry)?.toString() ?: "absent") != p.getProperty("oldCarry") ||
            snapshot(record) != p.getProperty("oldRecord") || snapshot(marker) != p.getProperty("oldMarker"))
            throw IOException("runtime changed during extraction")
        if (present(record)) checkInstalledGroup()
        val expected = p.getProperty("staging")
        if (expected == "absent") {
            if (hasMaterial(staging)) throw IOException("unrecorded runtime extraction")
        } else if (!(allowRemovedStage && !present(staging)) && identity(staging)?.toString() != expected)
            throw IOException("runtime extraction object changed")
    }

    private fun checkCommit(p: Properties) {
        checkRoot(p)
        checkInstalledGroup()
        if (identity(root)?.toString() != p.getProperty("newRoot") || installedCommit() != p.getProperty("id"))
            throw IOException("runtime commit ownership changed")
        verifyPositions(p, p.getProperty("moves").toInt(), liveOnly = p.getProperty("phase") in setOf("ready", "resetting"))
    }

    private fun removePreparedStage(p: Properties) {
        if (present(staging)) {
            if (p.getProperty("staging") != "absent" && identity(staging)?.toString() != p.getProperty("staging"))
                throw IOException("runtime extraction object changed")
            if (p.getProperty("staging") == "absent" && hasMaterial(staging)) throw IOException("unrecorded runtime extraction")
            remove(staging)
        }
    }

    private fun removeRetired(p: Properties, deleted: (String) -> Unit = {}) {
        val retired = File(files, "runtime-retired/${p.getProperty("id")}")
        if (present(retired)) {
            val expected = p.getProperty("retired")
            if (expected == "absent") {
                if (hasMaterial(retired)) throw IOException("unrecorded retired runtime")
            } else if (identity(retired)?.toString() != expected) throw IOException("retired runtime ownership changed")
            remove(retired) { deleted(relative(it)) }
            force(retired.parentFile)
        }
    }

    /** Empty extraction wrappers are harmless; do not remove somebody else's files. */
    private fun removeEmpty(file: File) {
        if (!Files.isDirectory(file.toPath(), NOFOLLOW_LINKS)) return
        file.listFiles()?.forEach(::removeEmpty) ?: throw IOException("cannot inspect runtime directory")
        if (file.list()?.isEmpty() == true) Files.delete(file.toPath())
    }

    private fun hasMaterial(file: File): Boolean {
        if (!present(file)) return false
        if (!Files.isDirectory(file.toPath(), NOFOLLOW_LINKS)) return true
        val entries = file.listFiles() ?: throw IOException("cannot inspect runtime directory")
        return entries.any { !Files.isDirectory(it.toPath(), NOFOLLOW_LINKS) || hasMaterial(it) }
    }

    private fun checkRoot(p: Properties) {
        val actual = identity(root)?.toString()
        if (actual != null && actual != p.getProperty("oldRoot") && actual != p.getProperty("newRoot")) {
            throw IOException("runtime was replaced outside this transaction; keep current home and recovery files")
        }
    }

    /** Follow nested objects when an enclosing base/root is renamed, before changing live data. */
    private fun verifyPositions(p: Properties, applied: Int, liveOnly: Boolean = false) {
        val actions = (0 until p.getProperty("moves").toInt()).map { getMove(p, it) }
        val positions = linkedMapOf<String, File>()
        for (action in actions) positions.putIfAbsent(action.identity, action.from)
        for (action in actions.take(applied)) {
            for ((id, path) in positions.toMap()) {
                if (path == action.from) positions[id] = action.to
                else if (path.toPath().startsWith(action.from.toPath())) {
                    positions[id] = File(action.to, path.relativeTo(action.from).path)
                }
            }
        }
        for ((expected, path) in positions) {
            if (liveOnly && !path.toPath().startsWith(root.toPath())) continue
            if (identity(path)?.toString() != expected) throw IOException("runtime object continuity changed: $path")
        }
    }

    private fun getMove(p: Properties, index: Int): Move {
        val id = p.getProperty("id")
        if (UUID.fromString(id).toString() != id) throw IOException("invalid runtime transaction id")
        val retired = File(files, "runtime-retired/$id")
        val allowed = listOf(root, File(root, "root"), carry, staged("base"),
            File(staged("base"), "root"), File(retired, "rootfs"), File(retired, "fresh-home"),
            File(root, "etc/dsh-app/runtime.json"), File(retired, "runtime-info.json"), stagedIdentity()) +
            listOf("dsh", "go").flatMap { name -> listOf(File(root, layerPath(name)),
                File(staged(name), layerPath(name)), File(staged("base"), layerPath(name)), File(retired, name)) }
        val from = File(files, p.getProperty("move.$index.from"))
        val to = File(files, p.getProperty("move.$index.to"))
        if (from !in allowed || to !in allowed) throw IOException("invalid runtime transaction path")
        return Move(from, to, p.getProperty("move.$index.identity"))
    }

    private fun move(action: Move) {
        if (identity(action.from)?.toString() != action.identity || present(action.to)) {
            throw IOException("runtime object changed before rename")
        }
        rename(action.from, action.to)
    }

    private fun relative(file: File): String = file.relativeTo(files).invariantSeparatorsPath

    private fun rename(from: File, to: File) {
        if (present(to)) throw IOException("runtime rename target exists: $to")
        val parent = to.parentFile
        parent.mkdirs()
        if (!Files.isDirectory(parent.toPath(), NOFOLLOW_LINKS)) throw IOException("runtime parent is not a directory")
        Files.move(from.toPath(), to.toPath(), ATOMIC_MOVE)
        force(from.parentFile)
        if (from.parentFile != parent) force(parent)
    }

    private fun identity(file: File): Identity? {
        if (!present(file)) return null
        val attrs = Files.readAttributes(file.toPath(), "unix:dev,ino,mode", NOFOLLOW_LINKS)
        val mode = (attrs.getValue("mode") as Number).toInt()
        if (mode and 0xF000 == 0xA000) throw IOException("runtime object is a symlink")
        return Identity((attrs.getValue("dev") as Number).toLong(), (attrs.getValue("ino") as Number).toLong())
    }

    private fun present(file: File) = Files.exists(file.toPath(), NOFOLLOW_LINKS)

    private fun read(file: File): Properties = Properties().apply {
        try { file.inputStream().use { load(it) } }
        catch (e: IllegalArgumentException) { throw IOException("invalid runtime record", e) }
        if (getProperty("schema") != "1") throw IOException("unsupported runtime installation record")
    }

    private fun write(file: File, properties: Properties) {
        val bytes = java.io.ByteArrayOutputStream().use { out -> properties.store(out, null); out.toByteArray() }
        writeBytes(file, bytes)
    }

    private fun writeBytes(file: File, bytes: ByteArray) {
        file.parentFile.mkdirs()
        val temp = File(file.parentFile, "${file.name}.tmp")
        temp.outputStream().use { stream -> stream.write(bytes); stream.fd.sync() }
        Files.move(temp.toPath(), file.toPath(), ATOMIC_MOVE)
        force(file.parentFile)
    }

    private fun snapshot(file: File): String = if (present(file))
        Base64.getEncoder().encodeToString(file.readBytes()) else "absent"

    private fun restore(file: File, snapshot: String) {
        if (snapshot == "absent") {
            if (Files.deleteIfExists(file.toPath())) force(file.parentFile)
        } else writeBytes(file, Base64.getDecoder().decode(snapshot))
    }

    private fun force(directory: File) {
        FileChannel.open(directory.toPath(), READ).use { it.force(true) }
    }

    private fun remove(file: File, deleted: (File) -> Unit = {}) {
        if (!present(file)) return
        if (Files.isDirectory(file.toPath(), NOFOLLOW_LINKS)) {
            if (!file.canWrite() && !file.setWritable(true)) throw IOException("cannot remove retired directory")
            file.listFiles()?.forEach { remove(it, deleted) } ?: throw IOException("cannot list retired directory")
        }
        Files.delete(file.toPath())
        deleted(file)
    }

    private fun putSet(p: Properties, prefix: String, set: RuntimeLayerSet) {
        for ((key, value) in mapOf("version" to set.version, "abi" to set.abi, "base" to set.base,
            "dsh" to set.dsh, "go" to set.go, "identity" to set.identity)) p.setProperty("$prefix.$key", value)
    }

    private fun getSet(p: Properties, prefix: String) = RuntimeLayerSet(
        p.getProperty("$prefix.version"), p.getProperty("$prefix.abi"), p.getProperty("$prefix.base"),
        p.getProperty("$prefix.dsh"), p.getProperty("$prefix.go"), p.getProperty("$prefix.identity"),
    )

    private fun layerPath(name: String) = if (name == "dsh") "opt/dsh" else "opt/dsh-go"

    companion object {
        val NAMES = listOf("base", "dsh", "go")
    }
}
