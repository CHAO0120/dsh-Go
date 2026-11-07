package io.github.ccch1mneyyy.dsh_app.phone

import java.time.Instant
import java.time.ZoneId
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class CalendarIntentDefaultEndTest {
    private fun calendar(zone: String, begin: String, vararg options: Pair<String, Any?>): IntentSpec.Calendar {
        val args = Args(mapOf("kind" to "calendar", "title" to "date boundary", "begin" to begin, *options))
        return when (val parsed = IntentSpec.parse(args, ZoneId.of(zone))) {
            is Either.Left -> error(parsed.value)
            is Either.Right -> parsed.value as IntentSpec.Calendar
        }
    }

    private fun millis(iso: String) = Instant.parse(iso).toEpochMilli()

    @Test fun springDayEndsAtTheNextLocalMidnight() {
        val spec = calendar("America/New_York", "2026-03-08")
        assertTrue(spec.allDay)
        assertEquals(millis("2026-03-08T05:00:00Z"), spec.beginMs)
        assertEquals(millis("2026-03-09T04:00:00Z"), spec.endMs)
        assertEquals(23L * 3_600_000L, spec.endMs - spec.beginMs)
    }

    @Test fun autumnDayIncludesTheRepeatedHour() {
        val spec = calendar("America/New_York", "2026-11-01", "all_day" to true)
        assertEquals(millis("2026-11-01T04:00:00Z"), spec.beginMs)
        assertEquals(millis("2026-11-02T05:00:00Z"), spec.endMs)
        assertEquals(25L * 3_600_000L, spec.endMs - spec.beginMs)
    }

    @Test fun anOrdinaryDateKeepsItsLocalMidnightEncoding() {
        val spec = calendar("Asia/Shanghai", "2026-10-24")
        assertEquals(millis("2026-10-23T16:00:00Z"), spec.beginMs)
        assertEquals(millis("2026-10-24T16:00:00Z"), spec.endMs)
    }

    @Test fun aShiftedDayStartDoesNotShiftTheFollowingDayStart() {
        val spec = calendar("America/Sao_Paulo", "2018-11-04")
        assertEquals(millis("2018-11-04T03:00:00Z"), spec.beginMs)
        assertEquals(millis("2018-11-05T02:00:00Z"), spec.endMs)
    }

    @Test fun anExplicitEndStillUsesTheProvidedTime() {
        val spec = calendar("America/New_York", "2026-03-08", "end" to "2026-03-09T01:00")
        assertEquals(millis("2026-03-09T05:00:00Z"), spec.endMs)
    }

    @Test fun aDateExplicitlyMarkedTimedStillDefaultsToOneHour() {
        val spec = calendar("America/New_York", "2026-03-08", "all_day" to false)
        assertFalse(spec.allDay)
        assertEquals(millis("2026-03-08T05:00:00Z"), spec.beginMs)
        assertEquals(millis("2026-03-08T06:00:00Z"), spec.endMs)
    }

    @Test fun aTimeBearingAllDayInputKeepsItsExistingDuration() {
        val spec = calendar("America/New_York", "2026-03-08T00:30", "all_day" to true)
        assertEquals(millis("2026-03-08T05:30:00Z"), spec.beginMs)
        assertEquals(millis("2026-03-09T05:30:00Z"), spec.endMs)
    }
}
