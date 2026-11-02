package io.github.ccch1mneyyy.dsh_app.phone

import org.junit.Assert.*
import org.junit.Test

class PhonePreviewTest {
    private val tasks = PhoneTasks(clock = { 1000L })
    private val preview = PhonePreview(tasks)
    private val bytes = byteArrayOf(1, 2, 3)

    private fun begin(): PhonePreview.Capture {
        val started = tasks.begin() as PhoneTasks.Begin.Go
        return preview.admit().also { preview.begin(it, tasks.activeOwner(started.taskId)) }
    }

    @Test fun beginAndPublishHaveDistinctRevisionsAndCopies() {
        val capture = begin()
        val pending = preview.snapshot(null)
        assertNull(pending.jpegBytes)
        assertEquals("noImage", pending.reason)
        preview.complete(capture, bytes, 42L, null)
        val ready = preview.snapshot(null)
        assertTrue(ready.revision > pending.revision)
        assertArrayEquals(bytes, ready.jpegBytes)
        assertEquals(42L, ready.capturedAt)
        ready.jpegBytes!![0] = 9
        bytes[1] = 9
        assertArrayEquals(byteArrayOf(1, 2, 3), preview.snapshot(null).jpegBytes)
    }

    @Test fun newerBeginRejectsOldDoneWithoutInvalidatingItsOwnCapture() {
        val old = begin()
        val next = begin()
        val nextRevision = preview.snapshot(null).revision
        preview.complete(old, bytes, 1L, null)
        assertEquals(nextRevision, preview.snapshot(null).revision)
        preview.complete(next, bytes, 2L, null)
        assertEquals(2L, preview.snapshot(null).capturedAt)
    }

    @Test fun sameTaskReleaseRejectsLateImageEvenWhileFrameWasNull() {
        val old = begin()
        preview.invalidate("unavailable", expectedTaskId = tasks.activeOwner()!!.taskId)
        val released = preview.snapshot(null).revision
        preview.complete(old, bytes, 1L, null)
        assertEquals(released, preview.snapshot(null).revision)
        assertNull(preview.snapshot(null).jpegBytes)
        assertEquals("unavailable", preview.snapshot(null).reason)
    }

    @Test fun oldTaskReleaseCannotClearSuccessorFrameOrPendingCapture() {
        val old = begin()
        val oldTaskId = tasks.activeOwner()!!.taskId
        tasks.endTask()
        val next = begin()
        val pendingRevision = preview.revision()
        preview.invalidate("unavailable", expectedTaskId = oldTaskId)
        assertEquals(pendingRevision, preview.revision())
        preview.complete(next, bytes, 2L, null)
        val ready = preview.snapshot(null)
        preview.invalidate("unavailable", expectedTaskId = oldTaskId)
        preview.complete(old, bytes, 1L, null)
        assertEquals(ready.revision, preview.revision())
        assertEquals(2L, preview.snapshot(null).capturedAt)
        preview.invalidate("unavailable", expectedTaskId = ready.taskId)
        assertNull(preview.snapshot(null).jpegBytes)
    }

    @Test fun noImageResultDoesNotRetainThePreviousFrame() {
        val first = begin()
        preview.complete(first, bytes, 1L, null)
        val next = begin()
        preview.complete(next, null, null, null)
        assertNull(preview.snapshot(null).jpegBytes)
        assertEquals("noImage", preview.snapshot(null).reason)
    }

    @Test fun queuedOldFailureCannotClearSuccessorImage() {
        preview.complete(begin(), bytes, 1L, null)
        val queued = preview.admit()
        tasks.endTask()
        preview.complete(begin(), bytes, 2L, null)
        val ready = preview.snapshot(null)
        preview.complete(queued, null, null, null)
        assertEquals(ready.revision, preview.snapshot(null).revision)
        assertEquals(2L, preview.snapshot(null).capturedAt)
    }

    @Test fun finishedCallerCannotBeginCaptureLater() {
        val started = tasks.begin() as PhoneTasks.Begin.Go
        val queued = preview.admit()
        preview.complete(queued, null, null, null)
        preview.complete(begin(), bytes, 2L, null)
        val ready = preview.snapshot(null)
        preview.begin(queued, tasks.activeOwner(started.taskId))
        assertEquals(ready.revision, preview.snapshot(null).revision)
        assertEquals(2L, preview.snapshot(null).capturedAt)
    }

    @Test fun getterRejectsEndedOwnerEvenBeforeTaskListenerRuns() {
        preview.complete(begin(), bytes, 1L, null)
        tasks.endTask()
        assertNull(preview.snapshot(null).jpegBytes)
        assertEquals("inactive", preview.snapshot(null).reason)
    }

    @Test fun lateTaskNotificationChecksCurrentStoredOwner() {
        val old = begin()
        tasks.endTask()
        preview.complete(begin(), bytes, 2L, null)
        val ready = preview.snapshot(null)
        // A listener invoked for an old snapshot always rechecks the stored actual owner.
        preview.taskChanged()
        preview.complete(old, bytes, 1L, null)
        assertEquals(ready.revision, preview.snapshot(null).revision)
        assertEquals(2L, preview.snapshot(null).capturedAt)
    }
    @Test fun oldBlockedCompletionDoesNotClearNewerImage() {
        val old = begin()
        val blocked = "locked"
        preview.complete(begin(), bytes, 2L, null)
        val ready = preview.snapshot(null)
        preview.complete(old, null, null, blocked)
        assertEquals(ready.revision, preview.snapshot(null).revision)
        assertEquals(2L, preview.snapshot(null).capturedAt)
    }

    @Test fun oldGetterFactReturnsOldUnavailableWithoutClearingNewImage() {
        preview.complete(begin(), bytes, 1L, null)
        val checked = preview.revision()
        val blocked = "locked"
        preview.complete(begin(), bytes, 2L, null)
        val ready = preview.snapshot(null)
        val stale = preview.snapshot(blocked, checked)
        assertEquals(checked, stale.revision)
        assertNull(stale.jpegBytes)
        assertEquals(ready.revision, preview.snapshot(null).revision)
        assertEquals(2L, preview.snapshot(null).capturedAt)
        preview.invalidate("unavailable", checked)
        assertEquals(ready.revision, preview.snapshot(null).revision)
    }

    @Test fun retiredChannelIdentityCannotClearItsReplacementFrame() {
        val first = Any()
        val replacement = Any()
        val channel = java.util.concurrent.atomic.AtomicReference(first)
        preview.complete(begin(), bytes, 1L, null)
        preview.invalidateIfCurrent { channel.getAndSet(replacement) !== replacement }
        preview.complete(begin(), bytes, 2L, null)
        val ready = preview.snapshot(null)
        preview.invalidateIfCurrent { channel.compareAndSet(first, null) }
        assertEquals(ready.revision, preview.snapshot(null).revision)
        assertNotNull(preview.snapshot(null).jpegBytes)
        preview.invalidateIfCurrent { channel.compareAndSet(replacement, null) }
        assertNull(preview.snapshot(null).jpegBytes)
        assertTrue(preview.snapshot(null).revision > ready.revision)
    }

}
