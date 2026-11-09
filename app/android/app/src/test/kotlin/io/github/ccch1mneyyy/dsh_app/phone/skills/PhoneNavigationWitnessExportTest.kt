package io.github.ccch1mneyyy.dsh_app.phone.skills

import io.github.ccch1mneyyy.dsh_app.phone.*
import org.junit.Assert.*
import org.junit.Test

/** Real trace/draft consumers; local witnesses are not Main device-producer evidence. */
class PhoneNavigationWitnessExportTest {
    private val owner = PhoneTasks.Owner(7, 1, true)
    private val trace = PhoneTaskTrace()
    private val drafts = PhoneSkillDrafts()
    private fun witness(uid: Int = 10123) = PhoneSkillNavigationWitness(uid, 164, 2, "a".repeat(64))
    private fun tap(t: PhoneTaskTrace = trace, nav: PhoneSkillNavigationWitness? = witness()) {
        t.finish(t.beginAction(owner, PhoneAction.Tap("s1", 1), null), true, false, true, nav)
    }
    private fun read(hasTask: Boolean = true, task: Any? = 7L, hasGeneration: Boolean = true, generation: Any? = 1L,
                     t: PhoneTaskTrace = trace): Map<*, *> = Json.parse(PhoneNavigationWitnessExport.read(
        3, hasTask, task, hasGeneration, generation, drafts, t).toString(Charsets.UTF_8)) as Map<*, *>

    @Test fun candidatesAndExactHistoricalWitnessAreReadOnly() {
        trace.start(owner); tap(); trace.complete(owner, true)
        assertTrue(drafts.offer(drafts.currentEpoch(), checkNotNull(trace.snapshot(owner))))
        val client = drafts.attachClient()
        val editor = drafts.open(client, PhoneTaskTrace.key(owner), true) as PhoneSkillDrafts.Shown
        val before = trace.snapshot(owner); val candidates = drafts.candidates()
        val listed = read(false, null, false, null)
        assertEquals("candidates", listed["kind"])
        val row = (listed["candidates"] as List<*>).single() as Map<*, *>
        assertEquals(setOf("taskId", "generation", "steps"), row.keys)
        assertEquals(7L, (row["taskId"] as Number).toLong())
        assertEquals(1L, (row["generation"] as Number).toLong())
        assertEquals(1, (row["steps"] as Number).toInt())
        val result = read(); assertEquals("witness", result["kind"])
        assertEquals(setOf("schema", "seq", "kind", "taskId", "generation", "ended", "eligible", "stepCount", "installation", "steps"), result.keys)
        assertEquals(before, trace.snapshot(owner)); assertEquals(candidates, drafts.candidates())
        assertEquals(editor, drafts.view(client, editor.view.draftId, 7))
    }

    @Test fun malformedOrPartialKeyNeverFallsBackToCandidateList() {
        trace.start(owner); tap(); trace.complete(owner, true)
        for (args in listOf(listOf(true, 7L, false, null), listOf(false, null, true, 1L),
            listOf(true, 7, true, 1L), listOf(true, 7L, true, 1), listOf(true, 0L, true, 1L),
            listOf(true, 7L, true, -1L), listOf(true, "9223372036854775808", true, 1L))) {
            assertEquals("invalid-key", read(args[0] as Boolean, args[1], args[2] as Boolean, args[3])["reason"])
        }
    }

    @Test fun unsupportedPrefixOrSuffixAndMixedInstallationRejectTheWholeTrace() {
        for (mode in listOf("prefix", "suffix", "missing", "installation")) {
            val local = PhoneTaskTrace(); local.start(owner)
            if (mode == "prefix") local.finish(local.beginOpen(owner, PhoneScreen.MAIN), true, false, true)
            tap(local, if (mode == "missing") null else witness())
            if (mode == "suffix") local.finish(local.beginOpen(owner, PhoneScreen.MAIN), true, false, true)
            if (mode == "installation") tap(local, witness(10124))
            local.complete(owner, true)
            val result = read(t = local)
            assertEquals("unavailable", result["kind"]); assertFalse(result.containsKey("steps"))
        }
    }

    @Test fun lateFinishAndDiscardCannotCreateHistoricalSuccess() {
        trace.start(owner)
        val ticket = trace.beginAction(owner, PhoneAction.Tap("s1", 1), null)
        trace.complete(owner, true); trace.finish(ticket, true, false, true, witness())
        assertEquals("unavailable", read()["kind"])
        trace.discard(PhoneTaskTrace.key(owner))
        assertEquals("unavailable", read()["kind"])
        assertEquals("unavailable", read(generation = 2L)["kind"])
    }
}
