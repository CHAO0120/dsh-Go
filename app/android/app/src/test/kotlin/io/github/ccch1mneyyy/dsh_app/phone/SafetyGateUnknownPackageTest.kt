package io.github.ccch1mneyyy.dsh_app.phone

import org.junit.Assert.*
import org.junit.Test

class SafetyGateUnknownPackageTest {
    private val unknown = listOf(null, "", " \t")

    @Test fun optionDefaultsOffAndPartialUpdatesKeepTheStoredChoice() {
        assertFalse(PhonePolicies().denyUnknownPackages)
        assertFalse(PhonePolicies.fromMap(null).denyUnknownPackages)
        val enabled = PhonePolicies.fromMap(mapOf("denyUnknownPackages" to true))
        assertTrue(enabled.denyUnknownPackages)
        for (value in listOf(null, "true", 1)) {
            assertEquals(enabled, PhonePolicies.fromMap(mapOf("denyUnknownPackages" to value), enabled))
        }
        assertTrue(PhonePolicies.fromMap(mapOf("confirmMode" to "always"), enabled).denyUnknownPackages)
        assertFalse(PhonePolicies.fromMap(mapOf("denyUnknownPackages" to false), enabled).denyUnknownPackages)
        assertEquals(enabled, PhonePolicies.fromMap(Json.parse(Json.write(enabled.toMap())) as Map<*, *>))
    }

    @Test fun defaultKeepsLegacyUnknownAppBehavior() {
        val gate = SafetyGate({ PhonePolicies(confirmMode = ConfirmMode.ALWAYS) }, PhoneTasks(), { null })
        for (pkg in unknown) {
            assertNull(gate.checkRead(pkg, null))
            assertSame(SafetyGate.Verdict.Allow, gate.checkWrite(WriteKind.TAP, null, pkg, null))
            assertSame(SafetyGate.Verdict.Allow, gate.checkWrite(WriteKind.SCROLL, null, pkg, null))
            val screen = ScreenSnapshot("s1", "ordinary", null, pkg)
            assertSame(screen, gate.filterScreen(screen))
        }
        val asking = SafetyGate({ PhonePolicies() }, PhoneTasks(), { null })
        assertTrue(asking.checkWrite(WriteKind.TAP, null, null, null) is SafetyGate.Verdict.Confirm)
    }

    @Test fun optedInUnknownAppsRefuseReadsAndWritesEvenWithExistingWaivers() {
        for (mode in ConfirmMode.entries) {
            val tasks = PhoneTasks().apply { begin(); waive() }
            val policy = PhonePolicies(confirmMode = mode, denyUnknownPackages = true,
                unlocks = PhoneUnlocks(systemPages = true, secretFields = true, ownApp = true))
            val gate = SafetyGate({ policy }, tasks, { null })
            for (pkg in unknown) {
                assertEquals("unknown-package", gate.checkRead(pkg, "Example")?.rule)
                assertEquals("unknown-package", gate.checkReadSources(policy, listOf("example.app", pkg))?.rule)
                for (kind in WriteKind.entries.filter { it != WriteKind.KEY }) {
                    val result = gate.checkWrite(kind, null, pkg, "Example")
                    assertEquals("unknown-package", (result as SafetyGate.Verdict.Refuse).rule)
                }
                assertSame(SafetyGate.Verdict.Allow, gate.checkWrite(WriteKind.KEY, null, pkg, null))
            }
        }
    }

    @Test fun knownPackagesKeepTheirExistingRules() {
        val gate = SafetyGate({ PhonePolicies(confirmMode = ConfirmMode.ALWAYS, denyUnknownPackages = true) }, PhoneTasks(), { null })
        assertNull(gate.checkRead("example.app", null))
        assertSame(SafetyGate.Verdict.Allow, gate.checkWrite(WriteKind.TAP, null, "example.app", null))
        assertEquals("deny-list", gate.checkRead("com.icbc", null)?.rule)
        assertEquals("own-app", gate.checkRead(SafetyRules.OWN_PACKAGE, null)?.rule)
        assertEquals("system-page", (gate.checkWrite(WriteKind.TAP, null, "com.android.settings", null) as SafetyGate.Verdict.Refuse).rule)
    }

    @Test fun unknownScreenContentAndImagesAreRemovedOnlyWhenOptedIn() {
        val gate = SafetyGate({ PhonePolicies(denyUnknownPackages = true) }, PhoneTasks(), { null })
        val known = ScreenSnapshot("s1", "ordinary", "Example", "example.app",
            image = byteArrayOf(1), imageMime = "image/png")
        for (pkg in unknown) {
            val filtered = gate.filterScreen(known.copy(packageName = pkg))
            assertFalse(filtered.text.contains("ordinary"))
            assertTrue(filtered.text.contains(SafetyGate.UNKNOWN_PACKAGE))
            assertNull(filtered.image)
            assertNull(filtered.imageMime)
        }
        val textSource = gate.filterScreen(known.copy(readPackages = setOf("")))
        assertFalse(textSource.text.contains("ordinary"))
        assertNull(textSource.image)
        val imageSource = gate.filterScreen(known.copy(imageReadPackages = setOf("")))
        assertTrue(imageSource.text.startsWith("ordinary\n"))
        assertNull(imageSource.image)
        assertSame(known, gate.filterScreen(known))
    }
}
