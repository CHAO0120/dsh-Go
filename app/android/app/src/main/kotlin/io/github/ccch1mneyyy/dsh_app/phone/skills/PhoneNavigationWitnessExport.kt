package io.github.ccch1mneyyy.dsh_app.phone.skills

import io.github.ccch1mneyyy.dsh_app.phone.PhoneScreen
import io.github.ccch1mneyyy.dsh_app.phone.Json

/** Bounded public facts from an existing trace, never a measured device-action count. */
internal object PhoneNavigationWitnessExport {
    fun unavailable(seq: Int, reason: String): ByteArray = Json.write(mapOf(
        "schema" to 1, "seq" to seq, "kind" to "unavailable", "reason" to reason)).toByteArray(Charsets.UTF_8)

    fun read(seq: Int, hasTask: Boolean, task: Any?, hasGeneration: Boolean, generation: Any?,
             drafts: PhoneSkillDrafts, trace: PhoneTaskTrace): ByteArray {
        val fields: Map<String, Any?>
        if (!hasTask && !hasGeneration) {
            fields = mapOf("kind" to "candidates", "candidates" to drafts.candidates().map {
                mapOf("taskId" to it.owner.taskId, "generation" to it.owner.lifecycle, "steps" to it.steps)
            })
        } else {
            if (!hasTask || !hasGeneration || task !is Long || generation !is Long || task <= 0 || generation <= 0)
                return unavailable(seq, "invalid-key")
            val snapshot = trace.snapshot(PhoneTaskTrace.OwnerKey(task, generation)) ?: return unavailable(seq, "unavailable")
            if (!snapshot.canDraft || snapshot.steps.any { it.action != PhoneTaskTrace.Action.TAP ||
                    it.screen != PhoneScreen.MAIN || it.receipt != PhoneTaskTrace.Receipt.RETURNED_OK ||
                    !it.postObservationAvailable || it.navigation == null }) return unavailable(seq, "unavailable")
            val app = checkNotNull(snapshot.steps.first().navigation)
            if (snapshot.steps.any { step -> checkNotNull(step.navigation).let {
                    it.uid != app.uid || it.version != app.version || it.updated != app.updated || it.signingDigest != app.signingDigest
                } }) return unavailable(seq, "unavailable")
            fields = mapOf("kind" to "witness", "taskId" to task, "generation" to generation,
                "ended" to snapshot.ended, "eligible" to snapshot.eligible, "stepCount" to snapshot.steps.size,
                "installation" to mapOf("uid" to app.uid, "version" to app.version, "updated" to app.updated,
                    "signingDigest" to app.signingDigest),
                "steps" to snapshot.steps.mapIndexed { index, step -> mapOf("index" to index,
                    "action" to step.action.name, "screen" to step.screen.name, "receipt" to step.receipt.name,
                    "postObservationAvailable" to step.postObservationAvailable, "witnessPresent" to true) })
        }
        val bytes = Json.write(mapOf("schema" to 1, "seq" to seq) + fields).toByteArray(Charsets.UTF_8)
        return if (bytes.size <= 16 * 1024) bytes else unavailable(seq, "limit")
    }
}
