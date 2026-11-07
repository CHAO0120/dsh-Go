package io.github.ccch1mneyyy.dsh_app.phone.background

import io.github.ccch1mneyyy.dsh_app.phone.PhoneAction
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertThrows
import org.junit.Test

class BackgroundDisplayTest {
    @Test fun aFailedObservationReportsItsReasonAndInvalidatesOldElementNumbers() {
        for (code in listOf("treeUnavailable", "displayTargetChanged", "displayMissing", "systemOperationDenied")) {
            val display = withLastElement()
            assertNotNull(display.target("b7", 1))

            val failure = assertThrows(IllegalStateException::class.java) {
                display.requireObservation(false, code, null)
            }

            assertEquals(Reasons.of(code), failure.message)
            assertNull(display.target("b7", 1))
            assertNull(display.target("b8", 1))
        }
    }

    @Test fun aFailedObservationPreservesTheExistingExceptionTypeDetail() {
        val display = withLastElement()

        val failure = assertThrows(IllegalStateException::class.java) {
            display.requireObservation(false, "deviceUnavailable", "IllegalAccessException")
        }

        assertEquals(Reasons.of("deviceUnavailable", "IllegalAccessException"), failure.message)
        assertNull(display.target("b7", 1))
    }

    @Test fun aSuccessfulObservationMayProceedToDecodeItsSnapshot() {
        val display = withLastElement()

        display.requireObservation(true, null, null)

        // The decoder, not this response guard, replaces successful snapshots.
        assertNotNull(display.target("b7", 1))
    }

    @Test fun unnumberedScrollRejectsAnOldOrInvalidatedSnapshotBeforeOpeningAChannel() {
        val display = withLastElement()
        BackgroundDisplay::class.java.getDeclaredField("currentPackage").apply {
            isAccessible = true
            set(display, "example.opened")
        }
        fun assertStale(screenId: String) {
            val result = display.perform(PhoneAction.Scroll(screenId, null, PhoneAction.Direction.DOWN))
            assertFalse(result.ok)
            assertEquals(Reasons.of("staleSnapshot"), result.message)
            org.junit.Assert.assertTrue(result.staleSnapshot)
        }
        assertStale("b6")
        assertThrows(IllegalStateException::class.java) {
            display.requireObservation(false, "treeUnavailable", null)
        }
        assertStale("b7")
    }

    @Test fun collectRejectsAnOldOrInvalidatedScreenBeforeItsFirstObservation() {
        val display = withLastElement()
        BackgroundDisplay::class.java.getDeclaredField("currentPackage").apply {
            isAccessible = true
            set(display, "example.opened")
        }
        fun assertStale(id: String) {
            val error = assertThrows(IllegalStateException::class.java) {
                display.collect(id, 1, 2, null)
            }
            assertEquals(Reasons.of("staleSnapshot"), error.message)
        }
        assertStale("b6")
        assertNotNull(display.target("b7", 1))
        assertThrows(IllegalStateException::class.java) {
            display.requireObservation(false, "treeUnavailable", null)
        }
        assertStale("b7")
    }

    @Test fun refreshedCollectUsesNewItemsOnlyInsideTheSelectedSubtree() {
        val fresh = listElements().toMutableList()
        val selected = fresh[1]
        fresh[2] = fresh[2].copy(label = "updated left")
        assertEquals(listOf("updated left", "left", "nested"), BackgroundTree.refreshedListItems(selected, fresh))
        assertEquals(listOf("right"), BackgroundTree.refreshedListItems(fresh[5], fresh))
        assertEquals(emptyList<String>(), BackgroundTree.refreshedListItems(fresh[8], fresh))
    }

    @Test fun refreshedCollectRejectsChangedOrMissingListIdentity() {
        val old = listElements()
        val selected = old[1].copy(viewId = "example:id/left")
        val fresh = old.toMutableList().apply { this[1] = selected }
        for (changed in listOf(selected.copy(role = "文本"), selected.copy(label = "changed"),
            selected.copy(viewId = "example:id/right"), selected.copy(viewId = null),
            selected.copy(isScrollable = false))) {
            fresh[1] = changed
            assertNull(BackgroundTree.refreshedListItems(selected, fresh))
        }
        assertNull(BackgroundTree.refreshedListItems(selected, emptyList()))
        fresh[1] = selected
        assertEquals(listOf("left", "nested"), BackgroundTree.refreshedListItems(selected, fresh))
    }

    @Test fun collectFollowsTheUniqueSignatureWhenPageIdsMove() {
        val original = listOf(
            Element(1, "列表", "left list", Region.MIDDLE, isScrollable = true),
            Element(2, "文本", "left one", Region.MIDDLE, indent = 1),
            Element(3, "列表", "right list", Region.MIDDLE, isScrollable = true),
            Element(4, "文本", "outside until", Region.MIDDLE, indent = 1),
        )
        val selected = original[2]
        assertEquals(selected, BackgroundTree.followCollectedList(selected, original))
        val fresh = listOf(
            original[0], original[1],
            Element(3, "文本", "left two", Region.MIDDLE, indent = 1),
            selected.copy(id = 4),
            Element(5, "文本", "right new", Region.MIDDLE, indent = 1),
        )
        val followed = BackgroundTree.followCollectedList(selected, fresh)!!
        assertEquals(4, followed.id)
        assertEquals(listOf("right new"), BackgroundTree.refreshedListItems(followed, fresh))
        assertEquals(3, selected.id)
    }

    @Test fun collectStopsForAmbiguousMissingOrChangedSemanticLists() {
        val selected = Element(1, "列表", "", Region.MIDDLE, isScrollable = true)
        assertEquals(selected, BackgroundTree.followCollectedList(selected, listOf(selected)))
        assertNull(BackgroundTree.followCollectedList(selected, listOf(selected, selected.copy(id = 3))))
        assertNull(BackgroundTree.followCollectedList(selected, emptyList()))
        for (changed in listOf(selected.copy(isScrollable = false), selected.copy(role = "文本"),
            selected.copy(label = "different"), selected.copy(viewId = "example:id/other"),
            selected.copy(region = Region.TOP), selected.copy(indent = 1))) {
            assertNull(BackgroundTree.followCollectedList(selected, listOf(changed)))
        }
        val named = selected.copy(viewId = "example:id/list")
        assertNull(BackgroundTree.followCollectedList(named, listOf(selected)))
        assertNull(BackgroundTree.followCollectedList(named, listOf(named, named.copy(id = 2))))
    }

    @Test fun onePageCollectRejectsMissingAndNonScrollableTargets() {
        val display = withLists()
        for ((id, reason) in listOf(0 to "elementMissing", 99 to "elementMissing", 1 to "inputRejected", 8 to "inputRejected")) {
            val error = assertThrows(IllegalStateException::class.java) { display.collect("b7", id, 1, null) }
            assertEquals(Reasons.of(reason), error.message)
        }
        val stale = assertThrows(IllegalStateException::class.java) { display.collect("b6", 2, 1, null) }
        assertEquals(Reasons.of("staleSnapshot"), stale.message)
        assertNotNull(display.target("b7", 2))
    }

    private fun withLists(): BackgroundDisplay {
        val display = withLastElement()
        BackgroundDisplay::class.java.getDeclaredField("currentPackage").apply {
            isAccessible = true
            set(display, "example.opened")
        }
        val elements = listElements()
        BackgroundDisplay::class.java.getDeclaredField("lastElements").apply {
            isAccessible = true
            set(display, elements)
        }
        return display
    }

    private fun listElements() = listOf(
            Element(1, "文本", "header", Region.MIDDLE),
            Element(2, "列表", "", Region.MIDDLE, isScrollable = true),
            Element(3, "文本", "left", Region.MIDDLE, indent = 1),
            Element(4, "列表", "left", Region.MIDDLE, indent = 1, isScrollable = true),
            Element(5, "文本", "nested", Region.MIDDLE, indent = 2),
            Element(6, "列表", "", Region.MIDDLE, isScrollable = true),
            Element(7, "文本", "right", Region.MIDDLE, indent = 1),
            Element(8, "列表", "not scrollable", Region.MIDDLE),
            Element(9, "文本", "", Region.MIDDLE, isScrollable = true),
        )

    private fun withLastElement(): BackgroundDisplay {
        val display = BackgroundDisplay(
            channelProvider = { error("response validation must not start a connection") },
            releaseChannelProvider = { error("response validation must not release the display") },
        )
        BackgroundDisplay::class.java.getDeclaredField("lastScreenId").apply {
            isAccessible = true
            set(display, "b7")
        }
        BackgroundDisplay::class.java.getDeclaredField("lastElements").apply {
            isAccessible = true
            set(display, listOf(Element(1, "按钮", "确定", Region.MIDDLE)))
        }
        return display
    }

    @Test fun onlyBackIsSentToTheBackgroundScreen() {
        val display = BackgroundDisplay(
            channelProvider = { error("a refused key must not reach the privileged channel") },
            releaseChannelProvider = { error("a refused key must not release the background screen") },
        )
        // An app is open on the background screen (set directly: opening one needs the channel).
        BackgroundDisplay::class.java.getDeclaredField("currentPackage").apply {
            isAccessible = true
            set(display, "example.opened")
        }

        for (key in PhoneAction.GlobalKey.entries - PhoneAction.GlobalKey.BACK) {
            val result = display.perform(PhoneAction.Key("b1", key))
            assertFalse(key.name, result.ok)
            assertEquals("后台屏不支持该系统键，未执行；请用返回或打开指定应用", result.message)
        }
    }
}
