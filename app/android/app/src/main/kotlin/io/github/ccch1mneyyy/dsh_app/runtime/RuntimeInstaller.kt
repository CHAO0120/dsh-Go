package io.github.ccch1mneyyy.dsh_app.runtime

import io.github.ccch1mneyyy.dsh_app.i18n.AppStrings
import io.github.ccch1mneyyy.dsh_app.R
import android.content.Context
import android.content.res.AssetManager
import java.io.File
import java.nio.channels.FileChannel
import java.nio.file.Files
import java.nio.file.attribute.PosixFilePermissions
import java.nio.file.StandardOpenOption
import java.security.DigestInputStream
import java.security.MessageDigest

/**
 * Installs the changed bundled runtime layers into app-private storage.
 *
 * Layout under filesDir/runtime:
 *   rootfs/            the active Linux root (proot -r)
 *   rootfs.version     runtimeVersion of the active rootfs
 *   layer-staging/     verified new layer payloads, owned by [RuntimeLayers]
 *   home.carry/        the user's /root while a base upgrade swaps rootfs
 *   keep.trash/        fresh copies a restore of kept files replaced (see [restoreKept])
 * and next to it, for a reset (see [retireRuntime]):
 *   runtime.reset/     the runtime being deleted
 *   runtime-keep/      what the reset keeps, mirrored under rootfs paths, until the next install
 *
 * Upgrading keeps the user's /root (DSH_HOME, workspaces) from the previous rootfs.
 */
class RuntimeInstaller(
    private val context: Context,
    private val manifest: RuntimeManifest,
    private val onLog: (String) -> Unit,
    private val sync: () -> Unit = ::syncFilesystems,
) {
    val baseDir = File(context.filesDir, "runtime")
    val rootfs = File(baseDir, "rootfs")
    private val versionFile = File(baseDir, "rootfs.version")
    internal val layers = RuntimeLayers(baseDir)
    private val retiredDir = File(context.filesDir, "runtime.reset")
    private val keepDir = File(context.filesDir, "runtime-keep")

    fun installedVersion(): String? =
        if (rootfs.isDirectory && versionFile.isFile) versionFile.readText().trim().ifEmpty { null } else null

    fun isCurrent(): Boolean = layers.isCurrent(manifest.layerSet)

    /**
     * Extracts the bundled rootfs; [onProgress] gets (compressedBytesRead, totalCompressedBytes).
     * Fails with [KeepFailed] when what a reset kept cannot go back; [dropKept] then gives up
     * whatever cannot and installs anyway.
     */
    fun install(dropKept: Boolean = false, onProgress: (Long, Long) -> Unit) {
        // A reset killed halfway finishes first, so what it keeps is in runtime-keep for the restore.
        settleReset(retiredDir, keepDir, dropKept)
        layers.pendingReset()?.let { reset(it) }
        val carry = File(baseDir, "home.carry")
        DirectLaunch.preservePhysicalAlias(rootfs,
            if (carry.exists()) carry else File(rootfs, "root"), File(baseDir, "rootfs.old"))
        val next = manifest.layerSet
        val preparation = layers.prepare(next, sync) ?: return
        val changed = layers.changed(next)
        checkFreeSpace(changed)
        val total = changed.sumOf { manifest.layers.getValue(it).bytes } + manifest.runtimeIdentity.bytes
        var completed = 0L
        var lastReported = 0L
        val progress: (Long) -> Unit = { read ->
            val done = completed + read
            if (done - lastReported >= 512 * 1024 || done == total) {
                lastReported = done
                onProgress(done, total)
            }
        }
        for (name in changed) {
            val layer = manifest.layers.getValue(name)
            val assetPath = "${RuntimeManifest.ASSET_DIR}/${layer.asset}"
            timed("verify $name") {
                verifyAsset(assetPath, layer.bytes, layer.archiveSha256)
            }
            timed("extract $name") {
                val extractor = TarExtractor(layers.staged(name), progress)
                if (layer.asset.endsWith(".xz") && assetLength(assetPath) > 0) {
                    val decoded = ParallelXZInputStream.open(
                        { AssetSeekableInputStream(context.assets.openFd(assetPath)) }, progress,
                    )
                    extractor.extractDecoded(decoded)
                } else {
                    context.assets.open(assetPath, AssetManager.ACCESS_STREAMING).use { raw ->
                        extractor.extract(raw, layer.asset)
                    }
                }
            }
            completed += layer.bytes
        }
        val identity = manifest.runtimeIdentity
        val identityPath = "${RuntimeManifest.ASSET_DIR}/${identity.asset}"
        timed("verify identity") { verifyAsset(identityPath, identity.bytes, identity.sha256) }
        val stagedIdentity = layers.stagedIdentity()
        context.assets.open(identityPath, AssetManager.ACCESS_STREAMING).use { input ->
            stagedIdentity.outputStream().use { input.copyTo(it) }
        }
        android.system.Os.chmod(stagedIdentity.path, 0x1A4) // 0644, as in the assembled reference.
        onProgress(total, total)

        timed("activate") {
            layers.activate(next, preparation, sync = { timed("sync") { sync() } }, restoreKept = { root ->
                listOf("root", "root/workspace", "tmp", "dev", "proc", "sys").forEach { File(root, it).mkdirs() }
                File(root, "tmp").setWritable(true, false)
                restoreKept(keepDir, root, dropKept)
            })
        }
    }

    private fun verifyAsset(path: String, bytes: Long, expected: String) {
        // Parallel readers revisit compressed bytes; hash each changed asset once, in order.
        val digest = MessageDigest.getInstance("SHA-256")
        var read = 0L
        DigestInputStream(context.assets.open(path, AssetManager.ACCESS_STREAMING), digest).use { input ->
            val buffer = ByteArray(1 shl 16)
            while (true) {
                val count = input.read(buffer)
                if (count < 0) break
                read += count
            }
        }
        val actual = digest.digest().joinToString("") { "%02x".format(it) }
        if (read != bytes || !expected.equals(actual, ignoreCase = true)) {
            throw IllegalStateException(AppStrings.get(context, R.string.service_package_checksum_failed))
        }
    }

    private inline fun <T> timed(phase: String, block: () -> T): T {
        val started = System.nanoTime()
        try {
            return block()
        } finally {
            onLog("[dsh-app] install $phase: ${(System.nanoTime() - started) / 1_000_000} ms")
        }
    }

    private fun checkFreeSpace(changed: Set<String>) {
        val payload = changed.sumOf { manifest.layers.getValue(it).uncompressedBytes } + manifest.runtimeIdentity.bytes
        val need = payload * 115 / 100
        val free = context.filesDir.usableSpace
        if (free < need) {
            val mb = { b: Long -> b / (1024 * 1024) }
            throw IllegalStateException(AppStrings.get(context, R.string.service_storage_insufficient, mb(need), mb(free)))
        }
    }

    /** Deletes the runtime; [keep] (paths under the rootfs) waits in runtime-keep for the next install. */
    fun reset(keep: List<String>) {
        layers.prepareReset(keep, sync)
        retireRuntime(baseDir, retiredDir, keepDir, keep)
    }

    private fun assetLength(path: String): Long = try {
        context.assets.openFd(path).use { it.length }
    } catch (_: Exception) {
        -1L // compressed asset; fall back to the manifest
    }
}

/** Recursive delete that removes symlinks without following them and copes with read-only dirs. */
internal fun File.deleteRecursivelySafely() {
    if (isSymlink()) {
        delete()
        return
    }
    if (isDirectory) {
        runCatching { Files.setPosixFilePermissions(toPath(), PosixFilePermissions.fromString("rwx------")) }
        listFiles()?.forEach { it.deleteRecursivelySafely() }
    }
    delete()
}

private fun File.isSymlink(): Boolean = try {
    android.system.OsConstants.S_ISLNK(android.system.Os.lstat(path).st_mode)
} catch (_: Exception) {
    // No android.system off the device (JVM tests).
    runCatching { Files.isSymbolicLink(toPath()) }.getOrDefault(false)
}

/** Exists, counting a symlink whose target is gone. */
private fun File.present(): Boolean = exists() || isSymlink()

internal fun syncDirectory(directory: File) {
    FileChannel.open(directory.toPath(), StandardOpenOption.READ).use { it.force(true) }
}

/** What 「重置运行环境」 can keep of the user's /root (paths under the rootfs). */
enum class ResetKeep(val wire: String, val paths: List<String>) {
    /** `$DSH_HOME/dsh-go` (ui.json) and both user skill roots: small, written by the user, harmless. */
    UI_AND_SKILLS("uiAndSkills", listOf("root/.dsh/dsh-go", "root/.dsh/skills", "root/.agents/skills")),

    /** Installed plugins with their settings, the global settings layer and the home `.env`. */
    PLUGINS_AND_SETTINGS("pluginsAndSettings", listOf("root/.dsh/profiles", "root/.dsh/cordis.patch.yml", "root/.dsh/.env"));

    companion object {
        /** Every path a reset can keep; none lies inside another. */
        val ALL: List<String> = entries.flatMap { it.paths }

        fun fromWire(names: Collection<String>): Set<ResetKeep> = entries.filterTo(LinkedHashSet()) { it.wire in names }
    }
}

/** The reset's choice of paths, written into the runtime before it is retired. */
private const val KEEP_LIST = "reset.keep"

/**
 * What a reset kept could not be moved; nothing is lost, and the install can be retried or told
 * to drop what cannot move. The message starts with `keep:` (the app's failure page looks for it).
 */
class KeepFailed(rel: String) : IllegalStateException("keep: could not move $rel")

/**
 * Deletes [base] but keeps [paths] of its rootfs in [keep]. The runtime is first renamed to [retired]
 * in one step, so from then on it reads as not installed, and the list of paths goes with it: a reset
 * killed at any point is finished by the next one or by the next install ([settleReset]). Nothing is
 * deleted before what is kept has moved.
 */
internal fun retireRuntime(base: File, retired: File, keep: File, paths: List<String>) {
    settleReset(retired, keep)
    // Reclamation can fail after all selected data was moved. Do not reuse its occupied name.
    if (retired.present()) {
        val discarded = File(retired.parentFile, "runtime-reset-discard-${java.util.UUID.randomUUID()}")
        if (!retired.renameTo(discarded)) throw IllegalStateException("could not retire old reset garbage")
    }
    retired.parentFile.listFiles()?.filter { it.name.startsWith("runtime-reset-discard-") }
        ?.forEach { it.deleteRecursivelySafely() }
    if (!base.exists()) {
        // Nothing to take from; the choice still applies to what an earlier reset kept.
        pruneKept(keep, paths)
        return
    }
    val list = File(base, KEEP_LIST)
    list.writeText(paths.joinToString("\n"))
    if (!base.renameTo(retired)) {
        list.delete()
        throw IllegalStateException("could not retire the runtime")
    }
    settleReset(retired, keep)
}

/**
 * Finishes a retired runtime: moves its listed paths into [keep], then deletes it. A path that
 * [keep] already holds is an earlier reset's, not restored yet (the runtime never got installed),
 * so that copy is the user's and the retired one is a fresh one. If a move fails, the retired
 * runtime stays as it is and the next attempt picks up from there; with [dropFailed] it is deleted
 * with whatever could not move.
 */
internal fun settleReset(retired: File, keep: File, dropFailed: Boolean = false) {
    if (!retired.present()) return
    val list = File(retired, KEEP_LIST)
    val listed = readKeepList(list)
    val rootfs = File(retired, "rootfs")
    for (rel in listed.orEmpty()) {
        val from = File(rootfs, rel)
        val to = File(keep, rel)
        if (!from.present() || to.present()) continue
        to.parentFile?.mkdirs()
        if (!from.renameTo(to) && !dropFailed) throw KeepFailed(rel)
    }
    // An unreadable list keeps whatever is already kept.
    if (listed != null) pruneKept(keep, listed)
    // The list goes first: a delete cut short leaves nothing that a later settle would keep.
    list.delete()
    retired.deleteRecursivelySafely()
}

/** The kept paths, or null when the list is missing; anything that could leave the rootfs is dropped. */
private fun readKeepList(file: File): List<String>? {
    if (!file.isFile) return null
    return file.readLines().map { it.trim() }.filter { it in ResetKeep.ALL }
}

/** Drops what [keep] holds outside [paths]: the latest reset's choice wins. */
private fun pruneKept(keep: File, paths: List<String>) {
    if (!keep.present()) return
    for (rel in ResetKeep.ALL) if (rel !in paths) File(keep, rel).deleteRecursivelySafely()
    keep.deleteEmptyDirs()
}

/**
 * Moves what a reset kept back into the new [rootfs], over the fresh copies (which wait in
 * `keep.trash` until all is back). A failed move puts that path's fresh copy back and throws
 * [KeepFailed]; what is not back yet stays in [keep] for the next install. With [dropFailed] the
 * paths that cannot move are given up instead and [keep] is cleared.
 */
internal fun restoreKept(keep: File, rootfs: File, dropFailed: Boolean = false) {
    val dropped = File(keep.parentFile, "${keep.name}.dropped")
    dropped.deleteRecursivelySafely()
    if (!keep.present()) return
    val trash = File(rootfs.parentFile, "keep.trash")
    trash.deleteRecursivelySafely()
    for (rel in ResetKeep.ALL) {
        val kept = File(keep, rel)
        if (!kept.present()) continue
        val target = File(rootfs, rel)
        val aside = File(trash, rel)
        if (target.present()) {
            aside.parentFile?.mkdirs()
            if (!target.renameTo(aside)) {
                if (dropFailed) continue
                throw KeepFailed(rel)
            }
        }
        target.parentFile?.mkdirs()
        if (!kept.renameTo(target)) {
            if (aside.present()) aside.renameTo(target)
            if (dropFailed) continue
            throw KeepFailed(rel)
        }
    }
    trash.deleteRecursivelySafely()
    if (!dropFailed) {
        keep.deleteEmptyDirs()
        return
    }
    // Out of the restore's way in one step, then deleted; a delete cut short is retried next time.
    if (keep.renameTo(dropped)) dropped.deleteRecursivelySafely() else keep.deleteRecursivelySafely()
}

/** Removes the empty directories of this tree, itself included; files (and symlinks) stay. */
private fun File.deleteEmptyDirs() {
    if (isSymlink() || !isDirectory) return
    listFiles()?.forEach { it.deleteEmptyDirs() }
    if (list()?.isEmpty() == true) delete()
}
