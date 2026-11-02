package io.github.ccch1mneyyy.dsh_app.phone

import java.time.ZoneId
import org.junit.After
import org.junit.Assert.*
import org.junit.Test

/** Actual PhoneCore -> worker -> gate -> driver path; Android device interfaces are fakes. */
class PhoneCorePromptOwnerTest {
    private val tasks = PhoneTasks()
    private var confirm: () -> Decision = { Decision.ALLOW_ONCE }
    private var handoff: () -> HandoffResult = { HandoffResult.CONTINUE }
    private var beforeHandoff: () -> Unit = {}
    private var asked = 0
    private var enabled = true
    private var locked = false
    private var beforeLockRead: () -> Unit = {}
    private var driverRequests = 0
    private val main = Driver(PhoneScreen.MAIN)
    private val background = Driver(PhoneScreen.BACKGROUND)
    private val core = PhoneCore(object : PhoneEnv {
        override fun enabled() = enabled
        override fun policies() = PhonePolicies()
        override fun isLocked(): Boolean {
            val result = locked
            beforeLockRead()
            return result
        }
        override fun gate() = object : UserGate {
            override fun confirm(request: ConfirmRequest): Decision { asked++; return confirm() }
            override fun handoff(reason: String, timeoutMs: Long): HandoffResult { asked++; return handoff() }
            override fun status(text: String?) {}
        }
        override fun driver(screen: PhoneScreen): PhoneDriver {
            driverRequests++
            return if (screen == PhoneScreen.MAIN) main else background
        }
        override fun a11yState() = A11yState.CONNECTED
        override fun backgroundUnavailable() = "unavailable"
        override fun zone() = ZoneId.of("UTC")
        override fun notifyFix(kind: String) {}
        override fun beforeHandoff(screen: PhoneScreen): String? { beforeHandoff(); return null }
        override fun sleep(ms: Long) {}
        override fun system() = object : SystemApi {
            override fun apps() = listOf(AppEntry("Example", "example.app"))
            override fun isInstalled(pkg: String) = true
            override fun launch(app: AppEntry) = error("unexpected launch")
            override fun urlTarget(url: String) = error("unexpected URL")
            override fun openUrl(url: String, target: UrlTarget) = error("unexpected URL open")
            override fun intent(spec: IntentSpec, shareTo: AppEntry?) = error("unexpected intent")
            override fun notify(title: String, text: String) = error("unexpected notification")
            override fun clipboardSet(text: String) = error("unexpected clipboard")
            override fun clipboardGet() = error("unexpected clipboard")
        }
    }, tasks, ActionLog())

    private class Driver(override val screen: PhoneScreen) : PhoneDriver {
        var reads = 0
        var availabilityReads = 0
        var writes = 0
        var opens = 0
        val actions = mutableListOf<PhoneAction>()
        var onObserve: () -> Unit = {}
        var imageBytes: ByteArray? = null
        var secure = false
        var packageName = "example.app"
        var screenText = "Example"
        override fun availability(): Availability { availabilityReads++; return Availability(true) }
        override fun foregroundPackage() = "example.app"
        override fun observe(detail: Boolean, image: Boolean): ScreenSnapshot {
            reads++
            onObserve()
            return ScreenSnapshot("${screen.prefix}1", screenText, "Example", packageName,
                secure = secure, image = imageBytes.takeIf { image }, imageMime = "image/jpeg")
        }
        override fun collect(screenId: String, listElementId: Int, maxPages: Int, until: String?) = error("unexpected collect")
        override fun target(screenId: String, elementId: Int) = TargetInfo(screenId, elementId,
            "按钮", "发送", "example.app", "Example", false, false, false)
        override fun perform(action: PhoneAction): ActionResult { actions += action; writes++; return ActionResult(true, "done") }
        override fun open(packageName: String): ActionResult { opens++; return ActionResult(true, "opened") }
    }

    private fun replace() { tasks.endTask(); tasks.begin() }
    private fun handoffCall() = core.call(PhoneToolCatalog.HANDOFF, mapOf("reason" to "User input"))
    private fun tapCall() = core.call(PhoneToolCatalog.TAP, mapOf("screen" to "s1", "id" to 1))
    @After fun close() = core.worker.shutdown()

    @Test fun currentHandoffContinuesAndReadsTheCurrentScreen() {
        assertFalse(handoffCall().isError)
        assertEquals(1, asked)
        assertEquals(1, main.reads)
    }

    @Test fun replacedTaskCannotContinueOldHandoffOrReadItsSuccessor() {
        handoff = { replace(); HandoffResult.CONTINUE }
        assertTrue(handoffCall().isError)
        assertEquals(0, main.reads)
        assertTrue(tasks.isActive)
    }

    @Test fun oldHandoffStopCannotStopItsSuccessor() {
        handoff = { replace(); HandoffResult.STOP }
        assertTrue(handoffCall().isError)
        assertTrue(tasks.isActive)
        assertFalse(tasks.isStopped())
    }

    @Test fun replacementDuringBeforeHandoffCannotAskUnderNewTask() {
        beforeHandoff = ::replace
        assertTrue(handoffCall().isError)
        assertEquals(0, asked)
    }

    @Test fun lateConfirmationCannotWriteIntoSuccessor() {
        confirm = { replace(); Decision.ALLOW_ONCE }
        assertTrue(tapCall().isError)
        assertEquals(1, asked)
        assertEquals(0, main.writes)
        assertTrue(tasks.isActive)
    }

    @Test fun lateBackgroundMoveConfirmationCannotMoveApplication() {
        confirm = { replace(); Decision.ALLOW_ONCE }
        assertTrue(core.call(PhoneToolCatalog.OPEN, mapOf("app" to "example.app", "background" to true)).isError)
        assertEquals(1, asked)
        assertEquals(0, background.opens)
        assertTrue(tasks.isActive)
    }

    @Test fun currentConfirmedWriteStillExecutesExactlyOnce() {
        assertFalse(tapCall().isError)
        assertEquals(1, asked)
        assertEquals(1, main.writes)
    }

    @Test fun missingTapXYObservationNamesTheActualRequiredParameter() {
        val result = core.call(PhoneToolCatalog.TAP_XY, mapOf("x" to 1, "y" to 2))
        assertTrue(result.isError)
        assertEquals("缺少 observation（屏幕号，如 s7）。先调用 screen 拿到屏幕号。", result.text)
        assertEquals(0, asked)
        assertEquals(0, main.writes)
    }

    @Test fun screenIsNotAnAliasForTapXYObservation() {
        val result = core.call(PhoneToolCatalog.TAP_XY, mapOf("screen" to "s1", "x" to 1, "y" to 2))
        assertTrue(result.isError)
        assertEquals("缺少 observation（屏幕号，如 s7）。先调用 screen 拿到屏幕号。", result.text)
        assertEquals(0, asked)
        assertEquals(0, main.writes)
    }

    @Test fun otherRequiredScreenArgumentsKeepTheirExistingName() {
        for (tool in listOf(PhoneToolCatalog.TAP, PhoneToolCatalog.TYPE, PhoneToolCatalog.SCROLL, PhoneToolCatalog.COLLECT)) {
            val result = core.call(tool, mapOf("observation" to "s1"))
            assertTrue(result.isError)
            assertEquals("缺少 screen（屏幕号，如 s7）。先调用 screen 拿到屏幕号。", result.text)
        }
        assertEquals(0, asked)
        assertEquals(0, main.writes)
    }

    @Test fun validObservationKeepsScreenRoutingCoordinatesAndConfirmation() {
        for ((sid, driver) in listOf("s1" to main, "b1" to background)) {
            val before = asked
            val result = core.call(PhoneToolCatalog.TAP_XY, mapOf("observation" to sid, "x" to 11, "y" to 22))
            assertFalse(result.isError)
            assertEquals(before + 1, asked)
            assertEquals(listOf(PhoneAction.TapXY(sid, 11, 22)), driver.actions)
            assertEquals(1, driver.writes)
        }
    }
    private fun await(latch: java.util.concurrent.CountDownLatch) =
        assertTrue(latch.await(5, java.util.concurrent.TimeUnit.SECONDS))

    private fun previewCall(background: Boolean = false, image: Boolean = true) =
        core.call(PhoneToolCatalog.SCREEN, mapOf("background" to background, "image" to image))

    @Test fun previewReadsOnlyTheFinalMainOrBackgroundImageWithoutObservingAgain() {
        assertEquals("inactive", core.previewSnapshot().reason)
        core.call(PhoneToolCatalog.APPS, emptyMap())
        assertEquals("noImage", core.previewSnapshot().reason)
        for ((driver, isBackground) in listOf(main to false, background to true)) {
            driver.imageBytes = byteArrayOf(1, 2, 3)
            val before = System.currentTimeMillis()
            val output = previewCall(isBackground)
            val reads = main.reads + background.reads
            val requests = driverRequests
            val availability = main.availabilityReads + background.availabilityReads
            val snapshot = core.previewSnapshot()
            assertArrayEquals(output.image, snapshot.jpegBytes)
            assertEquals(tasks.activeOwner()!!.taskId, snapshot.taskId)
            assertTrue(snapshot.capturedAt!! >= before)
            assertTrue(snapshot.capturedAt!! <= System.currentTimeMillis())
            repeat(3) { core.previewSnapshot() }
            assertEquals(reads, main.reads + background.reads)
            assertEquals(requests, driverRequests)
            assertEquals(availability, main.availabilityReads + background.availabilityReads)
            assertEquals(0, main.writes + background.writes + main.opens + background.opens)
        }
    }

    @Test fun previewNoImageAndSecureResultsClearPreviousImage() {
        main.imageBytes = byteArrayOf(1)
        assertNotNull(previewCall().image)
        assertNotNull(core.previewSnapshot().jpegBytes)
        previewCall(image = false)
        assertNull(core.previewSnapshot().jpegBytes)
        assertNotNull(previewCall().image)
        main.secure = true
        assertNull(previewCall().image)
        assertNull(core.previewSnapshot().jpegBytes)
    }

    @Test fun previewOwnAppAndSensitiveScreenNeverRetainEarlierImage() {
        main.imageBytes = byteArrayOf(1)
        for ((pkg, text) in listOf(SafetyRules.OWN_PACKAGE to "Example", SafetyRules.DEFAULT_DENY.first() to "Example",
            "example.app" to "«银行卡••••1234»", "example.app" to "«身份证••••1234»")) {
            main.packageName = "example.app"
            main.screenText = "Example"
            assertNotNull(previewCall().image)
            main.packageName = pkg
            main.screenText = text
            assertNull(previewCall().image)
            assertNull(core.previewSnapshot().jpegBytes)
        }
    }

    @Test fun previewOldTaskAndSameTaskReleaseCannotPublishLateImage() {
        main.imageBytes = byteArrayOf(1)
        main.onObserve = { replace() }
        previewCall()
        assertNull(core.previewSnapshot().jpegBytes)
        main.onObserve = { core.invalidatePreview(tasks.activeOwner()!!.taskId) }
        previewCall()
        assertNull(core.previewSnapshot().jpegBytes)
        main.onObserve = {}
        assertNotNull(previewCall().image)
        assertNotNull(core.previewSnapshot().jpegBytes)
        tasks.endTask()
        assertNull(core.previewSnapshot().jpegBytes)
    }

    @Test fun oldBackgroundReleaseCannotClearNewMainTaskImage() {
        background.imageBytes = byteArrayOf(1)
        previewCall(background = true)
        val oldTaskId = core.previewSnapshot().taskId!!
        tasks.endTask()
        main.imageBytes = byteArrayOf(2)
        previewCall()
        val ready = core.previewSnapshot()
        core.invalidatePreview(oldTaskId)
        assertEquals(ready.revision, core.previewSnapshot().revision)
        assertArrayEquals(byteArrayOf(2), core.previewSnapshot().jpegBytes)
    }

    @Test fun previewLockAndMasterOffClearWithoutAnotherCapture() {
        main.imageBytes = byteArrayOf(1)
        previewCall()
        val reads = main.reads
        locked = true
        assertEquals("locked", core.previewSnapshot().reason)
        assertNull(core.previewSnapshot().jpegBytes)
        locked = false
        assertNull(core.previewSnapshot().jpegBytes)
        previewCall()
        enabled = false
        assertEquals("unavailable", core.previewSnapshot().reason)
        assertEquals(reads + 1, main.reads)
    }

    @Test fun interruptedOuterCallCannotPublishAnObserveThatReturnsLater() {
        val entered = java.util.concurrent.CountDownLatch(1)
        val release = java.util.concurrent.CountDownLatch(1)
        val returned = java.util.concurrent.CountDownLatch(1)
        var output: ToolOutput? = null
        main.imageBytes = byteArrayOf(1)
        main.onObserve = {
            entered.countDown()
            var waiting = true
            while (waiting) {
                try { release.await(); waiting = false } catch (_: InterruptedException) { }
            }
        }
        val caller = Thread { try { output = previewCall() } finally { returned.countDown() } }
        caller.start()
        try {
            await(entered)
            caller.interrupt()
            await(returned)
            assertTrue(output!!.isError)
            assertNull(output!!.image)
            assertNull(core.previewSnapshot().jpegBytes)
        } finally { release.countDown() }
        // A real next worker call is the completion barrier for the abandoned observe.
        core.call(PhoneToolCatalog.APPS, emptyMap())
        assertNull(core.previewSnapshot().jpegBytes)
    }

    @Test fun lateGetterLockFactCannotClearANewerActualScreen() {
        main.imageBytes = byteArrayOf(1)
        previewCall()
        val entered = java.util.concurrent.CountDownLatch(1)
        val release = java.util.concurrent.CountDownLatch(1)
        val returned = java.util.concurrent.CountDownLatch(1)
        var old: PhonePreviewSnapshot? = null
        locked = true
        beforeLockRead = { entered.countDown(); release.await() }
        val reader = Thread { try { old = core.previewSnapshot() } finally { returned.countDown() } }
        reader.start()
        try {
            await(entered)
            beforeLockRead = {}
            locked = false
            main.imageBytes = byteArrayOf(2)
            previewCall()
            val current = core.previewSnapshot()
            release.countDown()
            await(returned)
            assertNull(old!!.jpegBytes)
            assertTrue(old!!.revision < current.revision)
            assertEquals(current.revision, core.previewSnapshot().revision)
            assertArrayEquals(byteArrayOf(2), core.previewSnapshot().jpegBytes)
        } finally { beforeLockRead = {}; release.countDown() }
    }

    @Test fun lateFinalLockFactCannotClearANewerActualScreen() {
        val entered = java.util.concurrent.CountDownLatch(1)
        val release = java.util.concurrent.CountDownLatch(1)
        val returned = java.util.concurrent.CountDownLatch(1)
        main.imageBytes = byteArrayOf(1)
        main.onObserve = {
            locked = true
            beforeLockRead = { entered.countDown(); release.await() }
        }
        val caller = Thread { try { previewCall() } finally { returned.countDown() } }
        caller.start()
        try {
            await(entered)
            beforeLockRead = {}
            locked = false
            main.onObserve = {}
            main.imageBytes = byteArrayOf(2)
            previewCall()
            val current = core.previewSnapshot()
            release.countDown()
            await(returned)
            assertEquals(current.revision, core.previewSnapshot().revision)
            assertArrayEquals(byteArrayOf(2), core.previewSnapshot().jpegBytes)
        } finally { beforeLockRead = {}; release.countDown() }
    }

}
