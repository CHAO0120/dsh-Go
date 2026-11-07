package io.github.ccch1mneyyy.dsh_app.runtime

import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import org.json.JSONArray
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest

/** Enabled bundles, installed packages and settings layer of the main profile at one moment. */
data class ProfileSnapshot(
    /** `dsh.profile.bundles`, in order. */
    val bundles: List<String>,
    /** `dependencies` (installed third-party packages). */
    val deps: Set<String>,
    /** Installed versions of [deps] that could be read from node_modules. */
    val versions: Map<String, String>,
    /** `cordis.patch.yml` text, or null when the file is absent. */
    val patch: String?,
)

/**
 * What restoring the last good snapshot changes in the current profile: the bundle list
 * goes back to the snapshot's, minus packages uninstalled or upgraded since (an upgraded package
 * can only be turned off, not downgraded); the settings layer goes back when it differs.
 * Nothing is installed or removed.
 */
data class LkgPlan(
    val target: List<String>,
    val disable: List<String>,
    val enable: List<String>,
    /** Enabled packages whose installed version differs from the snapshot's (part of [disable]). */
    val changed: List<String>,
    val patchChanged: Boolean,
    val bundlesChanged: Boolean,
) {
    val isEmpty: Boolean get() = !bundlesChanged && !patchChanged

    fun toMap(): Map<String, Any?> = mapOf(
        "disable" to disable,
        "enable" to enable,
        "changed" to changed,
        "patchChanged" to patchChanged,
        "empty" to isEmpty,
    )

    companion object {
        fun of(lkg: ProfileSnapshot, current: ProfileSnapshot): LkgPlan {
            fun sameVersion(name: String): Boolean {
                val then = lkg.versions[name]
                val now = current.versions[name]
                return then == null || now == null || then == now
            }
            val target = lkg.bundles.filter { name ->
                when {
                    name !in lkg.deps -> true // ships with DSH
                    name !in current.deps -> false // uninstalled since
                    else -> sameVersion(name)
                }
            }.distinct()
            return LkgPlan(
                target = target,
                disable = current.bundles.filter { it !in target }.distinct(),
                enable = target.filter { it !in current.bundles },
                changed = lkg.bundles.filter { it in lkg.deps && it in current.deps && it in current.bundles && !sameVersion(it) }.distinct(),
                patchChanged = !samePatch(lkg.patch, current.patch),
                bundlesChanged = target != current.bundles,
            )
        }

        fun samePatch(a: String?, b: String?): Boolean {
            val trivialA = a == null || SafeMode.isTrivialPatch(a)
            val trivialB = b == null || SafeMode.isTrivialPatch(b)
            if (trivialA && trivialB) return true
            return a?.trimEnd() == b?.trimEnd()
        }
    }
}

/**
 * The last good plugin set of profile `web`, kept outside the rootfs in
 * `filesDir/runtime/lkg/lkg.json` and recorded after each healthy two-minute normal run.
 */
object LastKnownGood {
    class Record(val at: Long, val snapshot: ProfileSnapshot)

    fun webDir(rootfs: File): File = File(rootfs, "root/.dsh/profiles/web")

    /** The main profile as it is now; null before DSH has created it. */
    fun read(rootfs: File): ProfileSnapshot? {
        val dir = webDir(rootfs)
        val pkg = File(dir, "package.json")
        if (!pkg.isFile) return null
        return parse(JSONObject(pkg.readText()), dir)
    }

    /**
     * What a normal run booted with, fixed when it reports ready: [atLaunch], or on a first boot
     * (DSH creates the profile after the launch read found none) the profile [readNow] returns.
     * Null when it is still missing or can't be read.
     */
    fun bootedAtReady(atLaunch: ProfileSnapshot?, readNow: () -> ProfileSnapshot?): ProfileSnapshot? =
        atLaunch ?: try {
            readNow()
        } catch (_: Exception) {
            null
        }

    /**
     * A healthy run pins exactly what it booted with, never a later read of the disk: the app may
     * have imported a profile since that nobody has seen run. False, keeping the old pin, without one.
     */
    fun pinBooted(booted: ProfileSnapshot?, save: (ProfileSnapshot) -> Unit): Boolean {
        save(booted ?: return false)
        return true
    }

    private fun parse(json: JSONObject, dir: File): ProfileSnapshot {
        val bundles = json.optJSONObject("dsh")?.optJSONObject("profile")?.optJSONArray("bundles").strings()
        val depsJson = json.optJSONObject("dependencies")
        val deps = LinkedHashSet<String>()
        depsJson?.keys()?.forEach { deps += it }
        val versions = LinkedHashMap<String, String>()
        for (name in deps) {
            val version = try {
                JSONObject(File(dir, "node_modules/$name/package.json").readText()).optString("version")
            } catch (_: Exception) {
                null
            }
            if (!version.isNullOrEmpty()) versions[name] = version
        }
        val patchFile = File(dir, "cordis.patch.yml")
        val patch = if (patchFile.isFile) patchFile.readText() else null
        return ProfileSnapshot(bundles, deps, versions, patch)
    }

    fun load(file: File): Record? {
        if (!file.isFile) return null
        return try {
            val json = JSONObject(file.readText())
            val versionsJson = json.optJSONObject("versions")
            val versions = LinkedHashMap<String, String>()
            versionsJson?.keys()?.forEach { versions[it] = versionsJson.optString(it) }
            Record(
                at = json.optLong("at"),
                snapshot = ProfileSnapshot(
                    bundles = json.optJSONArray("bundles").strings(),
                    deps = json.optJSONArray("deps").strings().toCollection(LinkedHashSet()),
                    versions = versions,
                    patch = if (json.isNull("patch")) null else json.optString("patch"),
                ),
            )
        } catch (_: Exception) {
            null
        }
    }

    fun save(file: File, snapshot: ProfileSnapshot, at: Long) {
        val versions = JSONObject()
        snapshot.versions.forEach { (k, v) -> versions.put(k, v) }
        val json = JSONObject()
            .put("at", at)
            .put("bundles", JSONArray(snapshot.bundles))
            .put("deps", JSONArray(snapshot.deps.toList()))
            .put("versions", versions)
            .put("patch", snapshot.patch ?: JSONObject.NULL)
        file.parentFile?.mkdirs()
        SafeMode.writeAtomic(file, json.toString(2) + "\n")
    }

    /**
     * Applies [LkgPlan.of] to the main profile under DSH's `package.json.lock`. The settings
     * layer being replaced is kept as `cordis.patch.yml.bak-<stamp>`.
     */
    fun restore(
        rootfs: File, lkg: ProfileSnapshot, stamp: String,
        missingConfig: String = "找不到主配置 profiles/web/package.json", // l10n:keep test default
        busyConfig: String = "插件配置正被别的程序修改，稍后再试", // l10n:keep test default
    ): LkgPlan {
        val dir = webDir(rootfs)
        val pkg = File(dir, "package.json")
        if (!pkg.isFile) throw IllegalStateException(missingConfig)
        return withLock(pkg, busyConfig) {
            val json = JSONObject(pkg.readText())
            val plan = LkgPlan.of(lkg, parse(json, dir))
            if (plan.bundlesChanged) {
                val dsh = json.optJSONObject("dsh") ?: JSONObject().also { json.put("dsh", it) }
                val profile = dsh.optJSONObject("profile") ?: JSONObject().also { dsh.put("profile", it) }
                profile.put("bundles", JSONArray(plan.target))
                // Android's org.json escapes every '/' as "\/"; undo that so the file stays as DSH writes it.
                SafeMode.writeAtomic(pkg, json.toString(2).replace("\\/", "/") + "\n")
            }
            if (plan.patchChanged) {
                val patchFile = File(dir, "cordis.patch.yml")
                if (patchFile.isFile) patchFile.copyTo(File(dir, "cordis.patch.yml.bak-$stamp"), overwrite = true)
                val text = lkg.patch
                if (text != null) SafeMode.writeAtomic(patchFile, text) else patchFile.delete()
            }
            plan
        }
    }

    /**
     * DSH's writer lock (`dsh-atomic-write`): a sibling `<file>.lock` created exclusively,
     * holding the writer's pid; a lock whose pid no longer exists is taken over.
     */
    private fun <T> withLock(file: File, busyConfig: String, block: () -> T): T {
        val lock = File(file.path + ".lock")
        val deadline = System.currentTimeMillis() + 3000
        while (true) {
            if (lock.createNewFile()) {
                break
            }
            if (takeOverExitedLock(lock)) continue
            if (System.currentTimeMillis() > deadline) throw IllegalStateException(busyConfig)
            Thread.sleep(50)
        }
        try {
            lock.writeText("${android.os.Process.myPid()}\n")
            return block()
        } finally {
            lock.delete()
        }
    }

    private fun readLockRecord(lock: File): String? = try {
        lock.readText(Charsets.UTF_8)
    } catch (_: Exception) {
        null
    }

    private fun holderExited(record: String): Boolean {
        if (!Regex("[0-9]+\\n").matches(record)) return false
        val pid = record.dropLast(1).toIntOrNull() ?: return false
        if (pid <= 0 || pid == android.os.Process.myPid()) return false
        return try {
            Os.kill(pid, 0)
            false
        } catch (error: ErrnoException) {
            error.errno == OsConstants.ESRCH
        }
    }

    // Match dsh-atomic-write: contenders for one dead record share a claim.
    // An existing claim, even from a dead claimant, is never reclaimed here.
    private fun takeOverExitedLock(lock: File): Boolean {
        val record = readLockRecord(lock) ?: return false
        if (!holderExited(record)) return false
        val hash = MessageDigest.getInstance("SHA-256")
            .digest(record.toByteArray(Charsets.UTF_8))
            .take(8).joinToString("") { "%02x".format(it.toInt() and 0xff) }
        val claim = File(lock.path + ".takeover-" + hash)
        val fd = try {
            Os.open(claim.path, OsConstants.O_CREAT or OsConstants.O_EXCL or OsConstants.O_WRONLY, 384)
        } catch (error: ErrnoException) {
            if (error.errno == OsConstants.EEXIST || error.errno == OsConstants.EPERM) return false
            throw error
        }
        try {
            // Android's FileOutputStream(fd) borrows fd; closing the stream does not own this close.
            var writeFailure: Throwable? = null
            try {
                FileOutputStream(fd).use { it.write("${android.os.Process.myPid()}\n".toByteArray(Charsets.UTF_8)) }
            } catch (error: Throwable) {
                writeFailure = error
                throw error
            } finally {
                try {
                    Os.close(fd)
                } catch (closeError: Throwable) {
                    if (writeFailure == null) throw closeError
                    writeFailure.addSuppressed(closeError)
                }
            }
            if (readLockRecord(lock) != record || !holderExited(record)) return false
            return lock.delete()
        } finally {
            claim.delete()
        }
    }

    private fun JSONArray?.strings(): List<String> {
        if (this == null) return emptyList()
        val out = ArrayList<String>(length())
        for (i in 0 until length()) optString(i).takeIf { it.isNotEmpty() }?.let { out += it }
        return out
    }
}
