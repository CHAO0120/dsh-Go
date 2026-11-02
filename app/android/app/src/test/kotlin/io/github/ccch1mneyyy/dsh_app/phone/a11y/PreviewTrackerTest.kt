package io.github.ccch1mneyyy.dsh_app.phone.a11y

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class PreviewTrackerTest {
    private val jpeg = byteArrayOf(1, 2, 3)

    @Test fun aNewerEventDropsTheImageBeforeTheRead() {
        val t = PreviewTracker()
        assertTrue(t.event(1))
        t.snapshot(1, jpeg, 10)
        assertTrue(t.event(2))
        assertNull(t.image)
        assertNull(t.capturedAt)
    }

    @Test fun aRepeatedOrOlderEventAsksForNothing() {
        val t = PreviewTracker()
        t.event(5)
        t.snapshot(5, jpeg, 10)
        assertFalse(t.event(5))
        assertFalse(t.event(4))
        assertArrayEquals(jpeg, t.image)
    }

    // An answer read before the task ended must not put its picture back after the event that hid it.
    @Test fun anOlderSnapshotCannotBringAnImageBack() {
        val t = PreviewTracker()
        t.event(3)
        t.snapshot(2, jpeg, 10)
        assertNull(t.image)
    }

    @Test fun aSnapshotWithoutAnImageAtTheSameRevisionStillHidesIt() {
        val t = PreviewTracker()
        t.event(3)
        t.snapshot(3, jpeg, 10)
        t.snapshot(3, null, null)
        assertNull(t.image)
    }

    @Test fun aSnapshotAheadOfTheEventsIsTakenAndItsLateEventAsksForNothing() {
        val t = PreviewTracker()
        t.snapshot(7, jpeg, 10)
        assertEquals(10L, t.capturedAt)
        assertFalse(t.event(7))
        assertArrayEquals(jpeg, t.image)
    }
}
