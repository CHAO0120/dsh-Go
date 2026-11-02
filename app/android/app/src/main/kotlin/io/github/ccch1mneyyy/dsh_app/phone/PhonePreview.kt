package io.github.ccch1mneyyy.dsh_app.phone

import java.util.concurrent.CopyOnWriteArrayList

/** A copy of the last image actually returned by screen; never a request to capture a screen. */
data class PhonePreviewSnapshot(
    val revision: Long,
    val jpegBytes: ByteArray? = null,
    val taskId: Long? = null,
    val capturedAt: Long? = null,
    val reason: String? = null,
    /** The image came from the background screen, not the one the user is looking at. */
    val background: Boolean = false,
) {
    fun toMap(): Map<String, Any?> = if (jpegBytes != null) mapOf(
        "revision" to revision, "available" to true,
        "jpegBytes" to jpegBytes, "taskId" to taskId, "capturedAt" to capturedAt,
    ) else mapOf("revision" to revision, "available" to false, "reason" to reason)
}

/** One frame and one revision, shared by native and Flutter readers. No device calls under [lock]. */
internal class PhonePreview(private val tasks: PhoneTasks) {
    private val lock = Any()
    private val listeners = CopyOnWriteArrayList<(Long) -> Unit>()
    private var revision = 0L
    private var owner: PhoneTasks.Owner? = null
    private var jpeg: ByteArray? = null
    private var capturedAt: Long? = null
    private var background = false
    private var reason = "inactive"

    /** Admission may name an old frame; begin replaces it with this worker's actual task owner. */
    class Capture internal constructor(
        internal var owner: PhoneTasks.Owner?,
        internal var revision: Long,
        internal var finished: Boolean = false,
    )

    fun admit(): Capture = synchronized(lock) {
        Capture(owner.takeIf { jpeg != null }, revision)
    }

    fun begin(capture: Capture, current: PhoneTasks.Owner?) {
        val changed = synchronized(lock) {
            if (capture.finished || current == null || !tasks.isCurrent(current)) return
            clearLocked("noImage")
            owner = current
            capture.owner = current
            capture.revision = revision
            revision
        }
        emit(changed)
    }

    /** Only the caller returning its actual final ToolOutput invokes this, never the worker. */
    fun complete(capture: Capture, bytes: ByteArray?, obtainedAt: Long?, blocked: String?, onBackground: Boolean = false) {
        val changed = synchronized(lock) {
            capture.finished = true
            val expected = capture.owner ?: return
            if (revision != capture.revision || !tasks.isCurrent(expected)) return
            clearLocked(blocked ?: "noImage")
            if (blocked == null && bytes != null && obtainedAt != null) {
                owner = expected
                jpeg = bytes.copyOf()
                capturedAt = obtainedAt
                background = onBackground
            }
            revision
        }
        emit(changed)
    }

    /** Listener snapshots may arrive late: check the stored owner, including an in-flight frame. */
    fun taskChanged() {
        val changed = synchronized(lock) {
            if (owner?.let { !tasks.isCurrent(it) } != true) return
            clearLocked(if (tasks.activeOwner() == null) "inactive" else "noImage")
            revision
        }
        emit(changed)
    }

    /** The predicate performs only the caller's atomic channel replacement/CAS, never device work. */
    fun invalidateIfCurrent(current: () -> Boolean) {
        val changed = synchronized(lock) {
            if (!current()) return
            clearLocked("unavailable")
            revision
        }
        emit(changed)
    }

    fun revision(): Long = synchronized(lock) { revision }

    fun invalidate(unavailable: String, expectedRevision: Long? = null, expectedTaskId: Long? = null) {
        val changed = synchronized(lock) {
            if (expectedRevision != null && revision != expectedRevision) return
            if (expectedTaskId != null && owner?.taskId != expectedTaskId) return
            clearLocked(unavailable)
            revision
        }
        emit(changed)
    }

    fun snapshot(blocked: String?, checkedRevision: Long = revision()): PhonePreviewSnapshot {
        var changed: Long? = null
        val result = synchronized(lock) {
            // Device facts were read outside this lock; an old fact cannot clear a newer state.
            if (revision != checkedRevision) return@synchronized PhonePreviewSnapshot(
                checkedRevision, reason = blocked ?: "noImage")
            val invalid = blocked ?: when {
                owner?.let { !tasks.isCurrent(it) } == true ->
                    if (tasks.activeOwner() == null) "inactive" else "noImage"
                reason == "inactive" && tasks.activeOwner() != null -> "noImage"
                else -> null
            }
            if (invalid != null && (owner != null || jpeg != null || reason != invalid)) {
                clearLocked(invalid)
                changed = revision
            }
            PhonePreviewSnapshot(revision, jpeg?.copyOf(), owner?.taskId.takeIf { jpeg != null },
                capturedAt, if (jpeg == null) reason else null, background && jpeg != null)
        }
        changed?.let(::emit)
        return result
    }

    fun addListener(listener: (Long) -> Unit) {
        listeners += listener
        listener(synchronized(lock) { revision })
    }

    fun removeListener(listener: (Long) -> Unit) { listeners -= listener }

    private fun clearLocked(unavailable: String) {
        revision++
        owner = null
        jpeg = null
        capturedAt = null
        background = false
        reason = unavailable
    }

    private fun emit(value: Long) {
        listeners.forEach { listener -> runCatching { listener(value) } }
    }
}
