import UIKit
import XCTest

/// The browser and the system tools on the real frameworks, in the app's own process, with nothing
/// mocked but the person tapping the sheet. tools-check.mjs grants the permissions first and puts
/// each answer through the same checks the engine applies. The tools' sources are compiled into
/// this bundle, so it needs nothing of Flutter. photos_select isn't here: its picker runs in
/// another process, out of reach of a test in this one.
@MainActor
final class NativeToolsTests: XCTestCase {
  private enum Expect: String {
    case ok, refused, either
  }

  private final class Once {
    private var taken = false
    func take() -> Bool {
      if taken { return false }
      taken = true
      return true
    }
  }

  private var tapping: Task<Void, Never>?
  private var saying = true

  static func top() -> UIViewController? {
    let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
    let scene = scenes.first { $0.activationState == .foregroundActive } ?? scenes.first
    var top = scene?.windows.first { $0.isKeyWindow }?.rootViewController
    while let presented = top?.presentedViewController { top = presented }
    return top
  }

  private func ready() async throws {
    for _ in 0..<300 {
      if UIApplication.shared.applicationState == .active, UIApplication.shared.isProtectedDataAvailable,
        Self.top()?.viewIfLoaded?.window != nil
      {
        return
      }
      try await Task.sleep(nanoseconds: 100_000_000)
    }
    XCTFail("the app never came to the front")
    throw CancellationError()
  }

  private static func buttons(in view: UIView) -> [UIButton] {
    view.subviews.flatMap { subview -> [UIButton] in
      if let button = subview as? UIButton { return [button] }
      return buttons(in: subview)
    }
  }

  /// Stands in for the person: answers every sheet as `saying` says, once it's fully on screen.
  private func startTapping() {
    tapping = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        if let self, let sheet = Self.top() as? IOSPhoneApproval, sheet.viewIfLoaded?.window != nil,
          !sheet.isBeingPresented, !sheet.isBeingDismissed
        {
          // Deny comes first on the sheet, allow second.
          let choices = Self.buttons(in: sheet.view)
          if let choice = self.saying ? choices.last : choices.first {
            choice.sendActions(for: .touchUpInside)
          }
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
      }
    }
  }

  private func request(_ kind: String, _ fields: [String: Any], session: String) throws -> IOSPhoneRequest {
    var action = fields
    action["kind"] = kind
    let body: [String: Any] = [
      "v": 1, "runId": "tools-check", "id": UUID().uuidString,
      "owner": ["sessionId": session, "callId": UUID().uuidString],
      "action": action, "expiresAt": Date().timeIntervalSince1970 * 1000 + 300_000,
    ]
    return try JSONDecoder().decode(IOSPhoneRequest.self, from: JSONSerialization.data(withJSONObject: body))
  }

  private func note(_ row: [String: Any]) {
    guard let directory = ProcessInfo.processInfo.environment["DSH_TOOLS_CHECK_DIR"],
      let data = try? JSONSerialization.data(withJSONObject: row)
    else { return }
    let file = URL(fileURLWithPath: directory).appendingPathComponent("rows.jsonl")
    if !FileManager.default.fileExists(atPath: file.path) {
      FileManager.default.createFile(atPath: file.path, contents: nil)
    }
    guard let handle = try? FileHandle(forWritingTo: file) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    try? handle.write(contentsOf: data + Data("\n".utf8))
  }

  /// A permission prompt nobody is there for would otherwise hold the whole run.
  private func timed(
    _ group: String, _ name: String, _ args: [String: Any], _ expect: Expect, seconds: Double = 60,
    _ body: @escaping @MainActor () async -> IOSPhoneOutcome
  ) async -> IOSPhoneOutcome {
    let started = Date()
    let once = Once()
    let answer: IOSPhoneOutcome = await withCheckedContinuation { continuation in
      Task { @MainActor in
        let value = await body()
        if once.take() { continuation.resume(returning: value) }
      }
      Task { @MainActor in
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        if once.take() { continuation.resume(returning: .failure("timed out after \(Int(seconds)) s")) }
      }
    }
    var row: [String: Any] = [
      "group": group, "name": name, "args": args, "expect": expect.rawValue, "isError": answer.isError,
      "text": String(answer.text.prefix(8000)), "ms": Int(Date().timeIntervalSince(started) * 1000),
    ]
    if let image = answer.image { row["imageBytes"] = image.count }
    note(row)
    switch expect {
    case .ok: XCTAssertFalse(answer.isError, "\(name): \(answer.text)")
    case .refused: XCTAssertTrue(answer.isError, "\(name) should have been refused: \(answer.text)")
    case .either: break
    }
    return answer
  }

  private func parsed(_ answer: IOSPhoneOutcome) -> [String: Any] {
    guard !answer.isError, let brace = answer.text.firstIndex(of: "{"),
      let data = String(answer.text[brace...]).data(using: .utf8),
      let value = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return [:] }
    return value
  }

  // MARK: The system tools

  @discardableResult
  private func system(
    _ tools: IOSSystemTools, _ name: String, _ args: [String: Any] = [:], session: String = "session-a", expect: Expect = .ok
  ) async throws -> [String: Any] {
    let params = String(decoding: try JSONSerialization.data(withJSONObject: args), as: UTF8.self)
    let call = try request("system-\(name)", ["params": params], session: session)
    let answer = await timed("system", name, args, expect) {
      await tools.run(call, authorize: { true }, current: { true })
    }
    return parsed(answer)
  }

  private func ids(_ value: [String: Any]) -> [String] {
    ((value["items"] as? [[String: Any]]) ?? []).compactMap { $0["id"] as? String }
  }

  func testSystemTools() async throws {
    try await ready()
    startTapping()
    defer { tapping?.cancel() }
    let actions = IOSPhoneActions(presenter: { NativeToolsTests.top() })
    let tools = IOSSystemTools(actions: actions, presenter: { NativeToolsTests.top() })
    defer { tools.retire() }

    // Saying no writes nothing.
    let declined = "DSH tools check declined \(UUID().uuidString.prefix(8))"
    saying = false
    try await system(tools, "reminders_create", ["title": declined], expect: .refused)
    saying = true
    let afterDecline = try await system(tools, "reminders_list", ["query": declined, "limit": 5, "include_completed": true])
    XCTAssertEqual(ids(afterDecline), [])

    let title = "DSH tools check \(UUID().uuidString.prefix(8))"
    let due = "2031-03-04T05:06:07.000Z"
    let created = try await system(tools, "reminders_create", ["title": title, "notes": "from the check", "due": due])
    let item = created["item"] as? [String: Any]
    XCTAssertEqual(item?["title"] as? String, title)
    XCTAssertEqual(item?["due"] as? String, due)
    let listed = try await system(tools, "reminders_list", ["query": title, "limit": 5, "include_completed": false])
    let row = (listed["items"] as? [[String: Any]])?.first
    XCTAssertEqual(row?["id"] as? String, item?["id"] as? String)
    XCTAssertEqual(row?["version"] as? String, item?["version"] as? String, "a reminder's version changed with nothing touching it")
    if let id = row?["id"] as? String, let version = row?["version"] as? String {
      let done = try await system(tools, "reminders_complete", ["id": id, "version": version, "completed": true])
      XCTAssertEqual((done["item"] as? [String: Any])?["completed"] as? Bool, true)
      // The version it was checked against has gone, so a second go at the same one is refused.
      try await system(tools, "reminders_complete", ["id": id, "version": version, "completed": false], expect: .refused)
      let open = try await system(tools, "reminders_list", ["query": title, "limit": 5, "include_completed": false])
      XCTAssertEqual(ids(open), [])
      let all = try await system(tools, "reminders_list", ["query": title, "limit": 5, "include_completed": true])
      XCTAssertEqual(ids(all), [id])
    }

    let name = "Toolcheck\(UUID().uuidString.prefix(6))"
    let contact = try await system(
      tools, "contacts_create", ["given_name": name, "family_name": "Check", "phone": "+86 138 0000 0000", "email": "tool.check@example.com"])
    XCTAssertEqual(contact["committed"] as? Bool, true)
    let found = try await system(tools, "contacts_search", ["query": name, "limit": 5, "fields": ["email", "phone"]])
    XCTAssertEqual(ids(found), [contact["id"] as? String ?? ""])
    let person = (found["items"] as? [[String: Any]])?.first
    XCTAssertEqual(person?["email"] as? [String], ["tool.check@example.com"])

    let place = try await system(tools, "location_current")
    XCTAssertEqual(place["latitude"] as? Double ?? 0, 31.2304, accuracy: 0.01)
    XCTAssertEqual(place["longitude"] as? Double ?? 0, 121.4737, accuracy: 0.01)

    // What photos_select leaves behind, from a picture with text on it.
    let picture = UIGraphicsImageRenderer(size: CGSize(width: 900, height: 300)).pngData { context in
      UIColor.white.setFill()
      context.fill(CGRect(x: 0, y: 0, width: 900, height: 300))
      NSString(string: "DSH Go 工具检查 12345").draw(
        at: CGPoint(x: 40, y: 100),
        withAttributes: [.font: UIFont.systemFont(ofSize: 72), .foregroundColor: UIColor.black])
    }
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).png")
    try picture.write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let handle = "abcdefghijklmnopqrstuvwxyz012345"
    tools.picked[handle] = IOSSystemTools.Picked(session: "session-a", file: file, expires: Date().addingTimeInterval(600))
    let read = try await system(tools, "vision_ocr", ["image_handle": handle, "max_bytes": 8192])
    let text = read["text"] as? String ?? ""
    XCTAssertTrue(text.contains("DSH"), "read: \(text)")
    XCTAssertTrue(text.contains("工具"), "read: \(text)")
    try await system(tools, "vision_ocr", ["image_handle": handle, "max_bytes": 8192], session: "session-b", expect: .refused)
  }

  // MARK: The browser tools

  @discardableResult
  private func web(
    _ browser: IOSBrowser, _ name: String, _ args: [String: Any] = [:], expect: Expect = .ok, seconds: Double = 90
  ) async throws -> IOSPhoneOutcome {
    let call = try request("browser-\(name)", args, session: "session-a")
    return await timed("browser", name, args, expect, seconds: seconds) {
      await browser.run(call, current: { true })
    }
  }

  private func read(_ browser: IOSBrowser) async throws -> [String: Any] {
    parsed(try await web(browser, "read", ["maxBytes": 49152]))
  }

  private func element(_ page: [String: Any], _ test: ([String: Any]) -> Bool) -> [String: Any]? {
    (page["elements"] as? [[String: Any]])?.first(where: test)
  }

  private func target(_ element: [String: Any]?, _ page: [String: Any]) throws -> [String: Any] {
    [
      "ref": try XCTUnwrap(element?["ref"] as? String, "no such element in \(page["url"] ?? "?")"),
      "epoch": try XCTUnwrap(page["epoch"] as? Int, "no epoch"),
    ]
  }

  func testBrowser() async throws {
    try await ready()
    startTapping()
    defer { tapping?.cancel() }
    let actions = IOSPhoneActions(presenter: { NativeToolsTests.top() })
    let browser = IOSBrowser(actions: actions, presenter: { NativeToolsTests.top() })
    defer { browser.retire() }

    try await web(browser, "read", expect: .refused)
    try await web(browser, "open", ["url": "http://127.0.0.1:8080/"], expect: .refused)
    saying = false
    try await web(browser, "open", ["url": "https://example.com/"], expect: .refused)
    saying = true
    try await web(browser, "open", ["url": "https://example.com/"])

    var page = try await read(browser)
    XCTAssertEqual(page["title"] as? String, "Example Domain")
    XCTAssertTrue((page["text"] as? String ?? "").contains("Example Domain"))

    let shot = try await web(browser, "screenshot")
    XCTAssertGreaterThan(shot.image?.count ?? 0, 1000)

    let document = element(page) { $0["role"] as? String == "document" }
    var scroll = try target(document, page)
    scroll["direction"] = "down"
    try await web(browser, "scroll", scroll)

    // The one link leaves for a site nobody has approved: it stays put and says so.
    page = try await read(browser)
    try await web(browser, "click", try target(element(page) { $0["role"] as? String == "link" }, page))
    try await Task.sleep(nanoseconds: 3_000_000_000)
    let answer = try await web(browser, "read", ["maxBytes": 49152])
    XCTAssertTrue(answer.text.contains("还没有批准"), "no note about the blocked link: \(answer.text.prefix(600))")
    XCTAssertEqual(parsed(answer)["title"] as? String, "Example Domain")

    // A page with a form. It's someone else's site, so being unable to reach it isn't a failure.
    let opened = try await web(browser, "open", ["url": "https://www.wikipedia.org/"], expect: .either)
    if !opened.isError {
      page = try await read(browser)
      let box = element(page) { ($0["role"] as? String) == "searchbox" || ($0["role"] as? String) == "textbox" }
      var fill = try target(box, page)
      fill["text"] = "Swift"
      try await web(browser, "fill", fill)

      page = try await read(browser)
      let list = element(page) { (($0["state"] as? [String: Any])?["options"] as? [[String: Any]])?.isEmpty == false }
      let options = (list?["state"] as? [String: Any])?["options"] as? [[String: Any]] ?? []
      let other = options.first { $0["selected"] as? Bool != true }
      var select = try target(list, page)
      select["text"] = try XCTUnwrap(other?["ref"] as? String, "no option to choose")
      try await web(browser, "select", select)

      page = try await read(browser)
      let chosen = element(page) { $0["ref"] as? String == list?["ref"] as? String }
      let now = (chosen?["state"] as? [String: Any])?["options"] as? [[String: Any]] ?? []
      XCTAssertEqual(now.first { $0["selected"] as? Bool == true }?["ref"] as? String, other?["ref"] as? String)

      let again = element(page) { ($0["role"] as? String) == "searchbox" || ($0["role"] as? String) == "textbox" }
      var press = try target(again, page)
      press["key"] = "Escape"
      try await web(browser, "press", press)

      try await web(browser, "back")
      page = try await read(browser)
      XCTAssertEqual(page["title"] as? String, "Example Domain")
    }

    try await web(browser, "close")
    try await web(browser, "read", expect: .refused)
  }
}
