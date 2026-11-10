package io.github.ccch1mneyyy.dsh_app.runtime

import java.io.File
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class LogRedactorTest {
    @Test fun sharedDiagnosticsVectorsAndIdempotence() {
        val fixture = generateSequence(File("").absoluteFile) { it.parentFile }
            .map { File(it, "tooling/fixtures/diagnostic-redaction.json") }.first { it.isFile }
        val cases = JSONObject(fixture.readText()).getJSONArray("cases")
        for (index in 0 until cases.length()) {
            val case = cases.getJSONObject(index)
            val inputParts = case.getJSONArray("inputParts")
            val input = (0 until inputParts.length()).joinToString("") { inputParts.getString(it) }
            val expectedParts = case.getJSONArray("expectedParts")
            val expected = (0 until expectedParts.length()).joinToString("") { expectedParts.getString(it) }
            val actual = CrashClassifier.redact(input)
            assertEquals(case.getString("name"), expected, actual)
            assertEquals(case.getString("name"), actual, CrashClassifier.redact(actual))
        }
    }

    @Test fun longQuotedValuesDoNotOverflowTheRegexStack() {
        val input = "{\"password\":\"" + "SYNTHETIC ".repeat(20_000) + "\",\"attempt\":2}"
        assertEquals("{\"password\":\"•••\",\"attempt\":2}", CrashClassifier.redact(input))
        val ordinary = "ordinary".repeat(1000)
        assertEquals(ordinary, CrashClassifier.redact(ordinary))
    }

    @Test fun streamedPrivateKeysAreMaskedBeforeTheRunTailAndDoNotCrossStreams() {
        val stdout = LogRedactor()
        val stderr = LogRedactor()
        val begin = "-----BEGIN " + "OPENSSH PRIVATE KEY-----"
        val end = "-----END " + "OPENSSH PRIVATE KEY-----"
        assertEquals(begin, stdout.line(begin))
        assertEquals("ordinary stderr", stderr.line("ordinary stderr"))
        assertEquals("•••", stdout.line("SYNTHETIC-PRIVATE-MATERIAL"))
        assertEquals("•••", stdout.line(""))
        assertEquals(end + " after", stdout.line(end + " after"))
        assertEquals("next line", stdout.line("next line"))
    }

    @Test fun inlineBlocksAndAnotherUnfinishedBlockOnTheSameLineKeepState() {
        val stream = LogRedactor()
        val begin = "-----BEGIN " + "PRIVATE KEY-----"
        val end = "-----END " + "PRIVATE KEY-----"
        assertEquals("before ••• between $begin", stream.line("before $begin SYNTHETIC $end between $begin"))
        assertEquals("•••", stream.line("SYNTHETIC-TAIL"))
        assertEquals("•••$end after", stream.line("SYNTHETIC $end after"))
        assertEquals("new run", LogRedactor().line("new run"))
    }

    @Test fun failureSummaryMasksProviderKeysAndAssignments() {
        val failure = CrashClassifier.classify(1, null, 1, 1,
            listOf("dsh: startup failed: API_KEY=SYNTHETIC_VALUE password=synthetic"), false)
        assertEquals("startup failed: API_KEY=••• password=•••", failure.summary)
    }
}
