package io.github.ccch1mneyyy.dsh_app.runtime

/** Credential masking before engine output enters the run tail or the disk logger. */
class LogRedactor {
    // One instance per stdout/stderr pump, so an unfinished key cannot leak its next line.
    private var inPrivateKey = false

    /** Only PEM needs stream state; the disk logger masks all other formats once. */
    fun line(raw: String): String {
        val text = ANSI.replace(raw, "")
        val out = StringBuilder()
        var at = 0
        while (at < text.length || inPrivateKey) {
            if (inPrivateKey) {
                val end = KEY_END.find(text, at)
                if (end == null) return out.append(MARK).toString()
                if (end.range.first > at) out.append(MARK)
                out.append(end.value)
                at = end.range.last + 1
                inPrivateKey = false
            } else {
                val begin = KEY_BEGIN.find(text, at)
                if (begin == null) return out.append(text.substring(at)).toString()
                out.append(text, at, begin.range.first)
                val end = KEY_END.find(text, begin.range.last + 1)
                if (end == null) {
                    inPrivateKey = true
                    return out.append(begin.value).toString()
                }
                out.append(MARK)
                at = end.range.last + 1
            }
        }
        return out.toString()
    }

    companion object {
        private const val MARK = "•••"
        private val ANSI = Regex("""\x1B\[[0-9;?]*[ -/]*[@-~]""")
        private val KEY_BEGIN = Regex("""-----BEGIN [A-Z0-9 ]{0,40}PRIVATE KEY-----""")
        private val KEY_END = Regex("""-----END [A-Z0-9 ]{0,40}PRIVATE KEY-----""")
        private val KEY_BLOCK = Regex("""${KEY_BEGIN.pattern}[\s\S]*?(?:${KEY_END.pattern}|$)""")
        private val ADDRESS = Regex("""(?<![A-Za-z0-9_])[a-z][a-z0-9+.-]{1,15}://[^\s/:@?#]{0,256}:([^\s/@?#]+)@""")
        // Different run classes can overlap; scan each before merging the ranges.
        private val PROVIDERS = listOf(
            """sk-(?=[A-Za-z0-9_-]{0,255}[0-9])[A-Za-z0-9_-]{20,}|glpat-[A-Za-z0-9_-]{20,}""",
            """gh[pousr]_[A-Za-z0-9]{36,}|npm_[A-Za-z0-9]{36,}|hf_[A-Za-z0-9]{30,}|""" +
                """(?:sk|rk)_(?:live|test)_[A-Za-z0-9]{16,}|whsec_[A-Za-z0-9]{24,}|""" +
                """(?:AKIA|ASIA)[A-Z0-9]{16}(?![A-Za-z0-9_])|LTAI[A-Za-z0-9]{12,20}(?![A-Za-z0-9_])|""" +
                """AKID[A-Za-z0-9]{28,36}(?![A-Za-z0-9_])""",
            """github_pat_[A-Za-z0-9_]{22,}""",
            """xox[abprs]-[A-Za-z0-9-]{10,}""",
        ).map { Regex("""(?<![A-Za-z0-9_])(?:$it)""") }
        // These shapes can also overlap themselves; capture without consuming them.
        private val OVERLAPPING_PROVIDER = Regex(
            """(?<![A-Za-z0-9_])(?=(AIza[A-Za-z0-9_-]{35}|""" +
                """eyJ[A-Za-z0-9_-]{8,2048}\.eyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}))""",
        )
        private val PREFIXES = listOf(
            "github_pat_", "sk_live_", "sk_test_", "rk_live_", "rk_test_", "whsec_", "glpat-",
            "xoxa-", "xoxb-", "xoxp-", "xoxr-", "xoxs-", "ghp_", "gho_", "ghu_", "ghs_", "ghr_",
            "npm_", "hf_", "sk-", "AIza", "AKIA", "ASIA", "LTAI", "AKID",
        )
        private val TOKEN = Regex("token=[A-Za-z0-9._~%-]+")
        private val AUTH = Regex("""(?<![A-Za-z0-9_])(Bearer|Basic)\s+(?!•)[A-Za-z0-9._~+/=-]+""", RegexOption.IGNORE_CASE)
        private val AUTH_SCHEME = Regex("""^(?:Bearer|Basic)(?![A-Za-z0-9_])""", RegexOption.IGNORE_CASE)
        private val MASKED_AUTH = Regex("""^(?:Bearer|Basic)\s+•••$""", RegexOption.IGNORE_CASE)
        private val SECRET_NAME = Regex(
            """(?<![A-Za-z0-9_])[A-Za-z0-9_.-]*(?:passw(?:or)?d|passphrase|secret|credential|cookie|authorization)[A-Za-z0-9_.-]*"?\s*[:=]\s*""",
            RegexOption.IGNORE_CASE,
        )
        private val KEY_ASSIGNMENT = Regex(
            """(?<![A-Za-z0-9_])([A-Za-z0-9_.-]*(?:api[_-]?key|apikey|access[_-]?key|private[_-]?key|token)[A-Za-z0-9_.-]*)("?\s*[:=]\s*["']?)(?!•)(?![0-9]+(?:[\s"',;&]|$))([^\s"',;&]{8,})""",
            RegexOption.IGNORE_CASE,
        )

        /** Same secret formats as diagnostics/redact.dart; runtime log length limits stay unchanged. */
        fun redact(raw: String): String {
            var text = ANSI.replace(raw, "")
            val spans = mutableListOf<IntRange>()
            KEY_BLOCK.findAll(text).forEach { spans.add(it.range) }
            PROVIDERS.forEach { pattern -> pattern.findAll(text).forEach { spans.add(it.range) } }
            OVERLAPPING_PROVIDER.findAll(text).forEach { spans.add(it.groups[1]!!.range) }
            ADDRESS.findAll(text).forEach { spans.add(it.groups[1]!!.range) }
            if (spans.isNotEmpty()) {
                val merged = mutableListOf<IntRange>()
                for (span in spans.sortedBy { it.first }) {
                    val previous = merged.lastOrNull()
                    if (previous != null && span.first <= previous.last) {
                        merged[merged.lastIndex] = previous.first..maxOf(previous.last, span.last)
                    } else merged.add(span)
                }
                val out = StringBuilder()
                var at = 0
                for (span in merged) {
                    out.append(text, at, span.first).append(mask(text.substring(span)))
                    at = span.last + 1
                }
                text = out.append(text, at, text.length).toString()
            }
            text = TOKEN.replace(text, "token=$MARK")
            text = AUTH.replace(text) { "${it.groupValues[1]} $MARK" }
            text = secretAssignments(text)
            return KEY_ASSIGNMENT.replace(text) { "${it.groupValues[1]}${it.groupValues[2]}$MARK" }
        }

        // Scan quoted values without a repeated regex group: JVM regex recursion can
        // overflow on long log values, and runtime logs deliberately keep their byte limit.
        private fun secretAssignments(text: String): String {
            val out = StringBuilder()
            var copied = 0
            var cursor = 0
            while (true) {
                val name = SECRET_NAME.find(text, cursor) ?: break
                val start = name.range.last + 1
                var at = start
                val quote = text.getOrNull(at)?.takeIf { it == '\'' || it == '"' }
                if (quote != null) {
                    at++
                    while (at < text.length && text[at] != quote && text[at] != '\r' && text[at] != '\n') {
                        if (text[at] == '\\') {
                            if (at + 1 == text.length || text[at + 1] == '\r' || text[at + 1] == '\n') break
                            at++
                        }
                        at++
                    }
                    if (at < text.length && text[at] == quote) {
                        val value = text.substring(start + 1, at)
                        out.append(text, copied, start + 1)
                        out.append(if (value.isEmpty() || MASKED_AUTH.matches(value)) value else MARK).append(quote)
                        copied = at + 1
                        cursor = copied
                        continue
                    }
                }
                val valueStart = start + if (quote == null) 0 else 1
                at = valueStart
                while (at < text.length && !text[at].isWhitespace() && text[at] !in "\"',;&") at++
                val value = text.substring(valueStart, at)
                if (value.isNotEmpty() && !value.startsWith('•') &&
                    !AUTH_SCHEME.containsMatchIn(value)) {
                    out.append(text, copied, valueStart).append(MARK)
                    copied = at
                }
                cursor = maxOf(at, start)
            }
            return out.append(text, copied, text.length).toString()
        }

        private fun mask(value: String): String {
            if (value.startsWith("-----BEGIN")) {
                if (!value.contains('\n')) return MARK
                val end = KEY_END.find(value)?.value
                return KEY_BEGIN.find(value)!!.value + "\n$MARK" + (end?.let { "\n$it" } ?: "")
            }
            return (PREFIXES.firstOrNull { value.startsWith(it) } ?: "") + MARK
        }
    }
}
