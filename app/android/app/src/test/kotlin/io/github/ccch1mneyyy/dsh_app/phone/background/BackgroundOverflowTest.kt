package io.github.ccch1mneyyy.dsh_app.phone.background

import org.junit.Assert.*
import org.junit.Test

class BackgroundOverflowTest {
    private val elements = listOf(Element(1, "文本", "已列出的内容", Region.MIDDLE))

    @Test fun backgroundHintOnlyDescribesAlreadyReadOmissions() {
        val text = BackgroundTree.render("b1", null, true, false, elements,
            background = true, poorTree = false, overflow = 1)
        assertTrue(text.contains("本次已读取的元素中另有 1 项未列出"))
        assertTrue(text.contains("未列出的元素没有可用编号"))
        assertFalse(text.contains("collect"))
        assertFalse(text.contains("scroll"))
        assertTrue(text.contains("共 1 项"))
    }

    @Test fun absentAndZeroDoNotClaimCompleteness() {
        val absent = BackgroundTree.render("b1", null, true, false, elements,
            background = true, poorTree = false)
        val zero = BackgroundTree.render("b1", null, true, false, elements,
            background = true, poorTree = false, overflow = 0)
        assertEquals(absent, zero)
        assertFalse(zero.contains("未列出"))
    }

    @Test fun mainScreenOverflowHintIsUnchanged() {
        val text = BackgroundTree.render("s1", null, true, false, elements,
            background = false, poorTree = false, overflow = 2)
        assertTrue(text.endsWith("  …另有 2 项，用 collect 或 scroll"))
    }
}
