import Foundation
import UIKit
import XCTest
@testable import Runner

/// Presents the production Runner confirmation controller in the host app's
/// real foreground window. Only the person's button taps and the grant clock
/// are synthetic. No phone action, remote request, notification response, or
/// human approval is claimed. These UIKit tests must fail if no usable UI exists.
@MainActor
final class IOSPhoneTaskConsentTests: XCTestCase {
  private static let grantTitle = "允许 AI 操控这台手机？"
  private static let callTitle = "允许这一次手机动作？"
  private static let grantButton = "允许 30 分钟"
  private static let callButton = "允许这一次"
  private static let denyButton = "拒绝"
  private static let clipboardTitle = "准备本次非 ASCII 粘贴？"
  private static let clipboardButton = "准备剪贴板"
  private static let clipboardDeny = "取消输入"

  private enum FixtureFailure: Error {
    case unavailableUI
    case unexpectedSheet
    case completedBeforeSheet
    case missingCompletion
    case cleanupTimeout
  }

  @MainActor
  private final class State {
    let host: UIViewController
    var clock: TimeInterval? = 1000
    var current = true
    var presentationAttempts = 0
    var admittedContinuations = 0
    init(host: UIViewController) { self.host = host }
  }

  @MainActor
  private final class RunningApproval {
    let request: Runner.IOSPhoneRequest
    let finished: XCTestExpectation
    private(set) var answer: Bool?
    private var task: Task<Void, Never>?

    init(request: Runner.IOSPhoneRequest, fixture: Fixture, finished: XCTestExpectation, clipboard: Bool = false) {
      self.request = request
      self.finished = finished
      task = Task { @MainActor [self] in
        let allowed: Bool
        if clipboard {
          allowed = await fixture.consent.prepareClipboard(request, current: { fixture.state.current })
        } else {
          allowed = await fixture.consent.approve(request,
            detail: "合成测试：本次只检查确认状态，不执行实际手机动作。",
            needsTarget: false, current: { fixture.state.current })
        }
        answer = allowed
        // A recording consumer of the real consent result, never an actual
        // executor. A false result must not reach this synthetic continuation.
        if allowed { fixture.state.admittedContinuations += 1 }
        finished.fulfill()
      }
    }

    func cancel() { task?.cancel() }
  }

  @MainActor
  private final class Fixture {
    let state: State
    let actions: Runner.IOSPhoneActions
    let consent: Runner.IOSPhoneTaskConsent
    var operations: [RunningApproval] = []
    // Keep observed controllers alive so a later allocation cannot reuse a
    // released controller's ObjectIdentifier during the same test.
    var sheets: [Runner.IOSPhoneApproval] = []

    init(host: UIViewController) {
      let state = State(host: host)
      self.state = state
      let actions = Runner.IOSPhoneActions(presenter: {
        state.presentationAttempts += 1
        return state.host
      })
      self.actions = actions
      consent = Runner.IOSPhoneTaskConsent(actions: actions, now: { state.clock })
    }

    func retireAndCancel() {
      state.current = false
      consent.retire()
      for operation in operations {
        operation.cancel()
        actions.cancel(operation.request.id)
      }
    }
  }

  private static func top() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
  }

  private static func buttons(in view: UIView) -> [UIButton] {
    view.subviews.flatMap { child -> [UIButton] in
      if let button = child as? UIButton { return [button] }
      return buttons(in: child)
    }
  }

  private static func labels(in view: UIView) -> [UILabel] {
    view.subviews.flatMap { child -> [UILabel] in
      if let label = child as? UILabel { return [label] }
      return labels(in: child)
    }
  }

  private func readyHost() async throws -> UIViewController {
    for _ in 0..<300 {
      if UIApplication.shared.applicationState == .active,
        UIApplication.shared.isProtectedDataAvailable,
        let host = Self.top(), host.viewIfLoaded?.window != nil,
        !host.isBeingPresented, !host.isBeingDismissed,
        !(host is Runner.IOSPhoneApproval)
      {
        return host
      }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    XCTFail("a foreground, unlocked host window was not available")
    throw FixtureFailure.unavailableUI
  }

  private func withFixture(_ body: (Fixture) async throws -> Void) async throws {
    let fixture = Fixture(host: try await readyHost())
    var failure: Error?
    do { try await body(fixture) } catch { failure = error }
    fixture.retireAndCancel()
    do {
      var settled = false
      for _ in 0..<500 {
        if fixture.operations.allSatisfy({ $0.answer != nil }),
          fixture.state.host.presentedViewController == nil
        {
          settled = true
          break
        }
        try await Task.sleep(nanoseconds: 20_000_000)
      }
      if !settled {
        XCTFail("the owned confirmation did not settle during cleanup")
        throw FixtureFailure.cleanupTimeout
      }
    } catch { if failure == nil { failure = error } }
    if let failure { throw failure }
  }

  private func request(run: String = "synthetic-consent-run",
                       session: String = "synthetic-consent-session", clipboard: Bool = false) throws -> Runner.IOSPhoneRequest {
    let params = clipboard ? "{\"screen\":\"s1\",\"id\":1,\"text\":\"合成输入\"}" : "{}"
    let envelope: [String: Any] = [
      "v": 1, "runId": run, "id": UUID().uuidString,
      "owner": ["sessionId": session, "callId": UUID().uuidString],
      "action": ["kind": "runner-call", "method": clipboard ? "type" : "apps", "params": params],
      "expiresAt": Date().addingTimeInterval(600).timeIntervalSince1970 * 1000,
    ]
    return try JSONDecoder().decode(Runner.IOSPhoneRequest.self,
      from: JSONSerialization.data(withJSONObject: envelope))
  }

  private func start(_ fixture: Fixture, run: String = "synthetic-consent-run",
                     session: String = "synthetic-consent-session", clipboard: Bool = false) throws -> RunningApproval {
    let finished = expectation(description: "production consent settled")
    finished.assertForOverFulfill = true
    let operation = RunningApproval(request: try request(run: run, session: session, clipboard: clipboard),
      fixture: fixture, finished: finished, clipboard: clipboard)
    fixture.operations.append(operation)
    return operation
  }

  private func nextSheet(_ fixture: Fixture, operation: RunningApproval,
                         grant: Bool, clipboard: Bool = false) async throws -> Runner.IOSPhoneApproval {
    for _ in 0..<500 {
      if operation.answer != nil {
        XCTFail("consent settled before its expected native confirmation appeared")
        throw FixtureFailure.completedBeforeSheet
      }
      if let sheet = Self.top() as? Runner.IOSPhoneApproval,
        !fixture.sheets.contains(where: { $0 === sheet }),
        sheet.viewIfLoaded?.window != nil,
        !sheet.isBeingPresented, !sheet.isBeingDismissed
      {
        fixture.sheets.append(sheet)
        let heading = clipboard ? Self.clipboardTitle : (grant ? Self.grantTitle : Self.callTitle)
        let allow = clipboard ? Self.clipboardButton : (grant ? Self.grantButton : Self.callButton)
        let deny = clipboard ? Self.clipboardDeny : Self.denyButton
        guard Self.labels(in: sheet.view).contains(where: { $0.text == heading }),
          Self.buttons(in: sheet.view).contains(where: { $0.currentTitle == allow }),
          Self.buttons(in: sheet.view).contains(where: { $0.currentTitle == deny })
        else {
          XCTFail("the native sheet did not match the required approval stage")
          throw FixtureFailure.unexpectedSheet
        }
        XCTAssertEqual(UIApplication.shared.applicationState, .active)
        XCTAssertTrue(UIApplication.shared.isProtectedDataAvailable)
        return sheet
      }
      // Poll only to observe the actual window and transition predicates. An
      // elapsed delay alone never establishes that a sheet exists or is ready.
      try await Task.sleep(nanoseconds: 20_000_000)
    }
    XCTFail("the expected production confirmation did not become visible")
    throw FixtureFailure.unavailableUI
  }

  private func button(_ title: String, in sheet: Runner.IOSPhoneApproval) throws -> UIButton {
    let matching = Self.buttons(in: sheet.view).filter { $0.currentTitle == title }
    XCTAssertEqual(matching.count, 1)
    return try XCTUnwrap(matching.first)
  }

  private func answer(_ sheet: Runner.IOSPhoneApproval, title: String) throws {
    let button = try button(title, in: sheet)
    guard Self.top() === sheet, sheet.viewIfLoaded?.window != nil,
      !sheet.isBeingPresented, !sheet.isBeingDismissed,
      button.isEnabled, button.window != nil
    else {
      XCTFail("synthetic tap requires the owned, visible, settled native sheet")
      throw FixtureFailure.unavailableUI
    }
    button.sendActions(for: .touchUpInside)
  }

  private func completed(_ operation: RunningApproval, expected: Bool) async throws {
    await fulfillment(of: [operation.finished], timeout: 10)
    guard let answer = operation.answer else {
      XCTFail("consent did not produce a result")
      throw FixtureFailure.missingCompletion
    }
    XCTAssertEqual(answer, expected)
  }

  @discardableResult
  private func establish(_ fixture: Fixture, run: String = "synthetic-consent-run",
                         session: String = "synthetic-consent-session") async throws -> RunningApproval {
    let operation = try start(fixture, run: run, session: session)
    let grant = try await nextSheet(fixture, operation: operation, grant: true)
    try answer(grant, title: Self.grantButton)
    let call = try await nextSheet(fixture, operation: operation, grant: false)
    try answer(call, title: Self.callButton)
    try await completed(operation, expected: true)
    XCTAssertTrue(fixture.consent.isGranted)
    return operation
  }

  func testInitialApprovalNeedsTaskGrantThenSeparateCallSheet() async throws {
    try await withFixture { fixture in
      let operation = try self.start(fixture)
      let grant = try await self.nextSheet(fixture, operation: operation, grant: true)
      XCTAssertFalse(fixture.consent.isGranted)
      XCTAssertNil(operation.answer)
      XCTAssertEqual(fixture.state.admittedContinuations, 0)
      XCTAssertEqual(fixture.state.presentationAttempts, 1)

      try self.answer(grant, title: Self.grantButton)
      let call = try await self.nextSheet(fixture, operation: operation, grant: false)
      XCTAssertFalse(grant === call)
      XCTAssertTrue(fixture.consent.isGranted)
      XCTAssertEqual(fixture.consent.remainingSeconds, 1800)
      XCTAssertNil(operation.answer)
      XCTAssertEqual(fixture.state.admittedContinuations, 0)
      XCTAssertEqual(fixture.state.presentationAttempts, 2)

      try self.answer(call, title: Self.callButton)
      try await self.completed(operation, expected: true)
      XCTAssertEqual(fixture.state.admittedContinuations, 1)
      XCTAssertEqual(fixture.sheets.count, 2)
    }
  }

  func testReusedTaskGrantStillRequiresFreshCallSheetAndDoesNotExtendExpiry() async throws {
    try await withFixture { fixture in
      try await self.establish(fixture)
      fixture.state.clock = 1060
      let operation = try self.start(fixture)
      let call = try await self.nextSheet(fixture, operation: operation, grant: false)
      XCTAssertEqual(fixture.sheets.count, 3)
      XCTAssertEqual(fixture.state.presentationAttempts, 3)
      XCTAssertEqual(fixture.state.admittedContinuations, 1)
      XCTAssertNil(operation.answer)
      XCTAssertEqual(fixture.consent.remainingSeconds, 1740)

      try self.answer(call, title: Self.callButton)
      try await self.completed(operation, expected: true)
      XCTAssertEqual(fixture.state.admittedContinuations, 2)
      XCTAssertEqual(fixture.consent.remainingSeconds, 1740)
    }
  }

  func testDenyingTaskGrantNeverAdmitsCallOrCreatesGrant() async throws {
    try await withFixture { fixture in
      let operation = try self.start(fixture)
      let grant = try await self.nextSheet(fixture, operation: operation, grant: true)
      try self.answer(grant, title: Self.denyButton)
      try await self.completed(operation, expected: false)
      XCTAssertFalse(fixture.consent.isGranted)
      XCTAssertEqual(fixture.state.admittedContinuations, 0)
      XCTAssertEqual(fixture.state.presentationAttempts, 1)
    }
  }

  func testDenyingPerCallSheetNeverAdmitsActionDespiteTaskGrant() async throws {
    try await withFixture { fixture in
      let operation = try self.start(fixture)
      let grant = try await self.nextSheet(fixture, operation: operation, grant: true)
      try self.answer(grant, title: Self.grantButton)
      let call = try await self.nextSheet(fixture, operation: operation, grant: false)
      try self.answer(call, title: Self.denyButton)
      try await self.completed(operation, expected: false)
      XCTAssertTrue(fixture.consent.isGranted)
      XCTAssertEqual(fixture.state.admittedContinuations, 0)
      XCTAssertEqual(fixture.state.presentationAttempts, 2)
    }
  }

  func testRetiredGrantSheetCannotCreateOrAnswerReplacementGrant() async throws {
    try await withFixture { fixture in
      let oldOperation = try self.start(fixture)
      let oldGrant = try await self.nextSheet(fixture, operation: oldOperation, grant: true)
      let staleButton = try self.button(Self.grantButton, in: oldGrant)
      fixture.consent.retire()
      try self.answer(oldGrant, title: Self.grantButton)
      try await self.completed(oldOperation, expected: false)
      XCTAssertFalse(fixture.consent.isGranted)
      XCTAssertEqual(fixture.state.admittedContinuations, 0)

      let replacement = try self.start(fixture)
      let newGrant = try await self.nextSheet(fixture, operation: replacement, grant: true)
      // Explicit synthetic delivery to a retained, no-longer-visible button.
      // The old controller must not answer the new production confirmation.
      staleButton.sendActions(for: .touchUpInside)
      XCTAssertNil(replacement.answer)
      XCTAssertTrue(Self.top() === newGrant)
      XCTAssertFalse(newGrant.isBeingDismissed)
      XCTAssertFalse(fixture.consent.isGranted)
      try self.answer(newGrant, title: Self.grantButton)
      let newCall = try await self.nextSheet(fixture, operation: replacement, grant: false)
      try self.answer(newCall, title: Self.callButton)
      try await self.completed(replacement, expected: true)
      XCTAssertEqual(fixture.state.admittedContinuations, 1)
    }
  }

  func testRetiredPerCallSheetCannotDonateItsAnswerToNewCall() async throws {
    try await withFixture { fixture in
      let oldOperation = try self.start(fixture)
      let oldGrant = try await self.nextSheet(fixture, operation: oldOperation, grant: true)
      try self.answer(oldGrant, title: Self.grantButton)
      let oldCall = try await self.nextSheet(fixture, operation: oldOperation, grant: false)
      let staleButton = try self.button(Self.callButton, in: oldCall)
      fixture.consent.retire()
      XCTAssertFalse(fixture.consent.isGranted)
      try self.answer(oldCall, title: Self.callButton)
      try await self.completed(oldOperation, expected: false)

      let replacement = try self.start(fixture)
      let newGrant = try await self.nextSheet(fixture, operation: replacement, grant: true)
      try self.answer(newGrant, title: Self.grantButton)
      let newCall = try await self.nextSheet(fixture, operation: replacement, grant: false)
      staleButton.sendActions(for: .touchUpInside)
      XCTAssertNil(replacement.answer)
      XCTAssertTrue(Self.top() === newCall)
      XCTAssertFalse(newCall.isBeingDismissed)
      XCTAssertEqual(fixture.state.admittedContinuations, 0)
      try self.answer(newCall, title: Self.callButton)
      try await self.completed(replacement, expected: true)
      XCTAssertEqual(fixture.state.admittedContinuations, 1)
    }
  }

  func testChangingSessionOrEngineRequiresANewTaskGrant() async throws {
    try await withFixture { fixture in
      try await self.establish(fixture)
      let owners = [
        ("synthetic-consent-run", "another-session"),
        ("another-engine", "another-session"),
      ]
      for (index, owner) in owners.enumerated() {
        fixture.state.clock = 1010 + Double(index)
        let operation = try self.start(fixture, run: owner.0, session: owner.1)
        let grant = try await self.nextSheet(fixture, operation: operation, grant: true)
        XCTAssertNil(operation.answer)
        XCTAssertEqual(fixture.state.admittedContinuations, index + 1)
        try self.answer(grant, title: Self.grantButton)
        let call = try await self.nextSheet(fixture, operation: operation, grant: false)
        try self.answer(call, title: Self.callButton)
        try await self.completed(operation, expected: true)
        XCTAssertEqual(fixture.consent.remainingSeconds, 1800)
      }
      XCTAssertEqual(fixture.state.admittedContinuations, 3)
      XCTAssertEqual(fixture.state.presentationAttempts, 6)
    }
  }

  func testGrantClockRejectsExactExpiryBackwardUnavailableAndNonfiniteSamples() async throws {
    try await withFixture { fixture in
      try await self.establish(fixture)
      XCTAssertEqual(fixture.consent.remainingSeconds, 1800)
      fixture.state.clock = 2799.999
      XCTAssertTrue(fixture.consent.isGranted)
      XCTAssertEqual(fixture.consent.remainingSeconds, 0.001, accuracy: 0.000000001)

      // These are injected clock samples, not a real 30-minute wait or a
      // device sleep/resume test. Every invalid sample must fail this read.
      let invalid: [TimeInterval?] = [2800, 2800.001, 999, nil,
        TimeInterval.nan, TimeInterval.infinity, -TimeInterval.infinity]
      for sample in invalid {
        fixture.state.clock = sample
        XCTAssertFalse(fixture.consent.isGranted)
        XCTAssertEqual(fixture.consent.remainingSeconds, 0)
      }
    }
  }

  func testOwnerTupleCannotCollideThroughColonDelimitedIdentifiers() async throws {
    try await withFixture { fixture in
      try await self.establish(fixture, run: "synthetic:engine", session: "session")
      // These distinct pairs concatenate to the same colon-delimited text.
      // Their task grants must nevertheless remain distinct owners.
      let replacement = try self.start(fixture, run: "synthetic", session: "engine:session")
      let grant = try await self.nextSheet(fixture, operation: replacement, grant: true)
      XCTAssertNil(replacement.answer)
      XCTAssertEqual(fixture.state.admittedContinuations, 1)
      try self.answer(grant, title: Self.denyButton)
      try await self.completed(replacement, expected: false)
      XCTAssertEqual(fixture.state.admittedContinuations, 1)
      XCTAssertEqual(fixture.state.presentationAttempts, 3)
    }
  }

  func testGrantExpiresWhilePerCallSheetIsVisibleAndLateAllowIsRejected() async throws {
    try await withFixture { fixture in
      let operation = try self.start(fixture)
      let grant = try await self.nextSheet(fixture, operation: operation, grant: true)
      try self.answer(grant, title: Self.grantButton)
      let call = try await self.nextSheet(fixture, operation: operation, grant: false)
      fixture.state.clock = 2800
      XCTAssertFalse(fixture.consent.isGranted)
      try self.answer(call, title: Self.callButton)
      try await self.completed(operation, expected: false)
      XCTAssertEqual(fixture.state.admittedContinuations, 0)
    }
  }

  func testUnavailableClockAtTaskGrantCompletionCannotCreateGrant() async throws {
    try await withFixture { fixture in
      fixture.state.clock = nil
      let operation = try self.start(fixture)
      let grant = try await self.nextSheet(fixture, operation: operation, grant: true)
      try self.answer(grant, title: Self.grantButton)
      try await self.completed(operation, expected: false)
      XCTAssertFalse(fixture.consent.isGranted)
      XCTAssertEqual(fixture.state.presentationAttempts, 1)
      XCTAssertEqual(fixture.state.admittedContinuations, 0)
    }
  }

  func testRevokedCurrentOwnerCannotAdmitVisiblePerCallApproval() async throws {
    try await withFixture { fixture in
      let operation = try self.start(fixture)
      let grant = try await self.nextSheet(fixture, operation: operation, grant: true)
      try self.answer(grant, title: Self.grantButton)
      let call = try await self.nextSheet(fixture, operation: operation, grant: false)
      fixture.state.current = false
      try self.answer(call, title: Self.callButton)
      try await self.completed(operation, expected: false)
      XCTAssertEqual(fixture.state.admittedContinuations, 0)
    }
  }

  func testClipboardPreparationCannotCreateItsOwnGrantOrUseANonTextRequest() async throws {
    let fixture = Fixture(host: UIViewController())
    let text = try request(clipboard: true)
    let withoutGrant = await fixture.consent.prepareClipboard(text, current: { true })
    XCTAssertFalse(withoutGrant)
    let nonText = await fixture.consent.prepareClipboard(try request(), current: { true })
    XCTAssertFalse(nonText)
    XCTAssertEqual(fixture.state.presentationAttempts, 0)
    XCTAssertFalse(fixture.consent.isGranted)
  }

  func testClipboardPreparationNeedsItsOwnNativeSheetWithoutExtendingTheGrant() async throws {
    try await withFixture { fixture in
      try await self.establish(fixture)
      fixture.state.clock = 1010
      let operation = try self.start(fixture, clipboard: true)
      let sheet = try await self.nextSheet(fixture, operation: operation, grant: false, clipboard: true)
      XCTAssertNil(operation.answer)
      XCTAssertEqual(fixture.state.admittedContinuations, 1)
      XCTAssertEqual(fixture.consent.remainingSeconds, 1790)
      try self.answer(sheet, title: Self.clipboardButton)
      try await self.completed(operation, expected: true)
      XCTAssertEqual(fixture.state.admittedContinuations, 2)
      XCTAssertEqual(fixture.consent.remainingSeconds, 1790)
      XCTAssertEqual(fixture.sheets.count, 3)
    }
  }

  func testDeniedClipboardSheetCannotDonateAnApproval() async throws {
    try await withFixture { fixture in
      try await self.establish(fixture)
      let operation = try self.start(fixture, clipboard: true)
      let sheet = try await self.nextSheet(fixture, operation: operation, grant: false, clipboard: true)
      try self.answer(sheet, title: Self.clipboardDeny)
      try await self.completed(operation, expected: false)
      XCTAssertEqual(fixture.state.admittedContinuations, 1)
    }
  }

  func testClipboardSheetRejectsRetiredOwnerAndCannotSwitchSessions() async throws {
    try await withFixture { fixture in
      try await self.establish(fixture)
      let wrongOwner = try self.start(fixture, session: "another-session", clipboard: true)
      try await self.completed(wrongOwner, expected: false)
      XCTAssertEqual(fixture.state.presentationAttempts, 2)
      let operation = try self.start(fixture, clipboard: true)
      let sheet = try await self.nextSheet(fixture, operation: operation, grant: false, clipboard: true)
      fixture.consent.retire()
      try self.answer(sheet, title: Self.clipboardButton)
      try await self.completed(operation, expected: false)
      XCTAssertEqual(fixture.state.admittedContinuations, 1)
    }
  }
}
