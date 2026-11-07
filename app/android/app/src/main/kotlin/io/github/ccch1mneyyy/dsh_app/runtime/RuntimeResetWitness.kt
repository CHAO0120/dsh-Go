package io.github.ccch1mneyyy.dsh_app.runtime

import java.io.File
import java.io.FileOutputStream
import java.io.IOException
import java.nio.channels.Channels
import java.nio.file.Files
import java.nio.file.LinkOption
import java.nio.file.StandardOpenOption
import java.nio.file.NoSuchFileException
import java.nio.file.StandardCopyOption

/** A sufficient reboot witness, never a boot id. Call only on the runtime worker. */
internal class RuntimeResetWitness(private val file: File, private val elapsed: () -> Long) {
    /** A launch must first retire any witness that could authorize deleting its rootfs. */
    fun admitLaunch() {
        val previous = read() ?: return
        val now = positiveTime()
        if (now < previous) write(now)
    }

    /** Captured/observed owners remain a veto even when some /proc reads fail. */
    fun allowsIncompleteReset(ownedRemaining: Boolean): Boolean {
        if (ownedRemaining) return false
        val previous = read() ?: return false
        val now = elapsed()
        return now > 0 && now < previous
    }

    fun recordFailedReset() = write(positiveTime())

    private fun positiveTime(): Long = elapsed().also {
        if (it <= 0) throw IOException("elapsed realtime unavailable")
    }

    private fun read(): Long? {
        val bytes = try {
            Files.newByteChannel(file.toPath(), StandardOpenOption.READ, LinkOption.NOFOLLOW_LINKS).use {
                Channels.newInputStream(it).readBytes()
            }
        } catch (_: NoSuchFileException) { return null }
        // Missing or fully read invalid records prove nothing. Other I/O errors propagate:
        // an unreadable old high sample must not reappear after admitting a new process.
        val text = bytes.toString(Charsets.US_ASCII)
        if (!RECORD.matches(text)) return null
        return text.substringAfter('\n').dropLast(1).toLongOrNull()?.takeIf { it > 0 }
    }

    private fun write(value: Long) {
        val parent = file.parentFile ?: throw IOException("reset witness has no parent")
        Files.createDirectories(parent.toPath())
        val temp = Files.createTempFile(parent.toPath(), ".runtime-reset-", ".tmp")
        var failed: Throwable? = null
        try {
            FileOutputStream(temp.toFile()).use { out ->
                out.write("v1\n$value\n".toByteArray(Charsets.US_ASCII))
                out.fd.sync()
            }
            // One authoritative name, no backup that could later restore an old high value.
            Files.move(temp, file.toPath(), StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING)
            syncDirectory(parent)
        } catch (error: Throwable) {
            failed = error
            throw error
        } finally {
            try { Files.deleteIfExists(temp) } catch (cleanup: Throwable) {
                if (failed != null) failed.addSuppressed(cleanup) else throw cleanup
            }
        }
    }

    companion object { private val RECORD = Regex("v1\\n[1-9][0-9]{0,18}\\n") }
}
