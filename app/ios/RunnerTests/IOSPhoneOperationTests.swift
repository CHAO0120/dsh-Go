import Foundation
import XCTest
@testable import Runner

/// Decode the actual IOSPhoneRequest envelope before constructing the immutable
/// production plan. All text is synthetic; this suite performs no phone action
/// and never reads a pasteboard, pairing record or other personal data.
@MainActor
final class IOSPhoneOperationTests: XCTestCase {
  private func request(method: String? = "screen", raw: String? = "{}", kind: String = "runner-call") throws -> Runner.IOSPhoneRequest {
    var action: [String: Any] = ["kind": kind]
    if let method { action["method"] = method }
    if let raw { action["params"] = raw }
    let envelope: [String: Any] = [
      "v": 1, "runId": "synthetic-engine", "id": UUID().uuidString,
      "owner": ["sessionId": "synthetic-session", "callId": "synthetic-call"],
      "action": action, "expiresAt": Date().addingTimeInterval(120).timeIntervalSince1970 * 1000,
    ]
    return try JSONDecoder().decode(Runner.IOSPhoneRequest.self, from: JSONSerialization.data(withJSONObject: envelope))
  }

  private func plan(_ method: String, _ parameters: [String: Any]) throws -> IOSPhoneOperation {
    let raw = String(decoding: try JSONSerialization.data(withJSONObject: parameters), as: UTF8.self)
    return try IOSPhoneOperation(request(method: method, raw: raw))
  }

  private func type(_ text: String, submit: Bool = false) throws -> IOSPhoneOperation {
    try plan("type", ["screen": "s1", "id": 1, "text": text, "submit": submit])
  }

  func testAllSupportedMethodsDecodeThroughTheRealRequestType() throws {
    let cases: [(String, [String: Any], Bool, Bool)] = [
      ("apps", [:], false, false), ("open", ["app": "test.synthetic.app"], false, false),
      ("screen", [:], true, false), ("tap", ["screen": "s1", "id": 1], true, true),
      ("tap_xy", ["observation": "s1", "x": 0, "y": 0], true, true),
      ("type", ["screen": "s1", "id": 1, "text": "synthetic"], true, true),
      ("scroll", ["screen": "s1", "direction": "down"], true, true),
      ("collect", ["screen": "s1", "list": 1], true, true),
      ("key", ["key": "home"], true, true),
    ]
    for (name, fields, target, observation) in cases {
      let value = try plan(name, fields)
      XCTAssertEqual(value.method.rawValue, name)
      XCTAssertEqual(value.needsTarget, target)
      XCTAssertEqual(value.requiresObservation, observation)
    }
  }

  func testOnlyRunnerCallWithAnExactSupportedMethodAndJSONObjectIsAccepted() throws {
    for kind in ["runner_call", "screen", "intent", ""] {
      XCTAssertThrowsError(try IOSPhoneOperation(request(kind: kind)))
    }
    for method in ["Screen", "screen ", "native", "prepareInput", "paste", "ascii", "handoff", ""] {
      XCTAssertThrowsError(try IOSPhoneOperation(request(method: method)))
    }
    XCTAssertThrowsError(try IOSPhoneOperation(request(method: nil)))
    XCTAssertThrowsError(try IOSPhoneOperation(request(raw: nil)))
    for raw in ["[]", "null", "true", "1", "\"screen\"", "{", "{\"image\":NaN}"] {
      XCTAssertThrowsError(try IOSPhoneOperation(request(raw: raw)))
    }
  }

  func testUnknownAndBackendSelectionArgumentsAreRejected() throws {
    for key in ["route", "backend", "provider", "nativeFrameId", "runId", "owner", "rawHid", "unknown"] {
      XCTAssertThrowsError(try plan("screen", [key: "synthetic"]))
      XCTAssertThrowsError(try plan("tap", ["screen": "s1", "id": 1, key: "synthetic"]))
    }
    XCTAssertThrowsError(try plan("open", ["app": "test.synthetic.app", "url": "https://example.invalid"]))
    XCTAssertThrowsError(try plan("type", ["screen": "s1", "id": 1, "text": "synthetic", "replace": false]))
  }

  func testBooleanFlagsRejectNumbersStringsAndNull() throws {
    let fields: [(String, [String: Any], String)] = [
      ("screen", [:], "image"), ("screen", [:], "detail"), ("screen", [:], "background"),
      ("open", ["app": "test.synthetic.app"], "background"),
      ("tap", ["screen": "s1", "id": 1], "long"),
      ("type", ["screen": "s1", "id": 1, "text": "synthetic"], "submit"),
    ]
    let invalidValues: [Any] = [NSNumber(value: 0), NSNumber(value: 1), NSNumber(value: 1.0), "true", NSNull()]
    for (method, base, key) in fields {
      for invalid in invalidValues {
        var input = base; input[key] = invalid
        XCTAssertThrowsError(try plan(method, input))
      }
      var input = base; input[key] = false
      XCTAssertNoThrow(try plan(method, input))
    }
    XCTAssertTrue(try plan("screen", ["image": true, "detail": true]).wantsImage)
    XCTAssertTrue(try plan("screen", ["image": true, "detail": true]).detail)
    XCTAssertThrowsError(try plan("screen", ["background": true]))
    XCTAssertThrowsError(try plan("open", ["app": "test.synthetic.app", "background": true]))
  }

  func testIntegerArgumentsRejectBooleanFractionalAndNonNumericValues() throws {
    let fields: [(String, [String: Any], String)] = [
      ("tap", ["screen": "s1"], "id"), ("type", ["screen": "s1", "text": "synthetic"], "id"),
      ("scroll", ["screen": "s1", "direction": "down"], "id"),
      ("collect", ["screen": "s1"], "list"),
      ("collect", ["screen": "s1", "list": 1], "max_pages"),
      ("tap_xy", ["observation": "s1", "y": 0], "x"),
      ("tap_xy", ["observation": "s1", "x": 0], "y"),
    ]
    let invalidValues: [Any] = [true, false, 1.5, -0.5, "1", NSNull()]
    for (method, base, key) in fields {
      for invalid in invalidValues {
        var input = base; input[key] = invalid
        XCTAssertThrowsError(try plan(method, input))
      }
    }
    for number in ["1e309", "1e308", "-1", "32768", "1.25"] {
      let raw = "{\"observation\":\"s1\",\"x\":\(number),\"y\":0}"
      XCTAssertThrowsError(try IOSPhoneOperation(request(method: "tap_xy", raw: raw)))
    }
  }

  func testIntegralJSONNumbersKeepTheirValidatedValueInThePlanAndDescription() throws {
    let tap = try IOSPhoneOperation(request(method: "tap", raw: "{\"screen\":\"s1\",\"id\":1.0}"))
    XCTAssertEqual(tap.parameters["id"] as? Int, 1)
    XCTAssertTrue(tap.consentDescription(targetLabel: nil).contains("编号 1"))
    let collect = try IOSPhoneOperation(request(method: "collect", raw: "{\"screen\":\"s1\",\"list\":1,\"max_pages\":30.0}"))
    XCTAssertEqual(collect.pages, 30)
    XCTAssertTrue(collect.consentDescription(targetLabel: nil).contains("30 页"))
    XCTAssertTrue(collect.consentDescription(targetLabel: nil).contains("29 次"))
  }

  func testIntegerRangesAcceptBothBoundariesAndRejectOutsideValues() throws {
    for id in [1, 400] { XCTAssertNoThrow(try plan("tap", ["screen": "s1", "id": id])) }
    for id in [0, 401, -1] { XCTAssertThrowsError(try plan("tap", ["screen": "s1", "id": id])) }
    for coordinate in [0, 32767] {
      XCTAssertNoThrow(try plan("tap_xy", ["observation": "s1", "x": coordinate, "y": coordinate]))
    }
    for coordinate in [-1, 32768] {
      XCTAssertThrowsError(try plan("tap_xy", ["observation": "s1", "x": coordinate, "y": 0]))
    }
    XCTAssertEqual(try plan("collect", ["screen": "s1", "list": 1]).pages, 10)
    for pages in [1, 30] {
      XCTAssertEqual(try plan("collect", ["screen": "s1", "list": 400, "max_pages": pages]).pages, pages)
    }
    for pages in [0, 31] {
      XCTAssertThrowsError(try plan("collect", ["screen": "s1", "list": 1, "max_pages": pages]))
    }
    for list in [0, 401] { XCTAssertThrowsError(try plan("collect", ["screen": "s1", "list": list])) }
  }

  func testRequiredAndOptionalStringsHaveByteLimitsAndRejectNull() throws {
    XCTAssertNoThrow(try plan("tap", ["screen": String(repeating: "s", count: 96), "id": 1]))
    XCTAssertThrowsError(try plan("tap", ["screen": String(repeating: "s", count: 97), "id": 1]))
    let invalidFields: [[String: Any]] = [["id": 1], ["screen": "", "id": 1], ["screen": NSNull(), "id": 1], ["screen": "s\0x", "id": 1]]
    for missing in invalidFields {
      XCTAssertThrowsError(try plan("tap", missing))
    }
    XCTAssertNoThrow(try plan("apps", ["query": String(repeating: "a", count: 256)]))
    XCTAssertThrowsError(try plan("apps", ["query": String(repeating: "a", count: 257)]))
    XCTAssertThrowsError(try plan("apps", ["query": NSNull()]))
    XCTAssertNoThrow(try plan("collect", ["screen": "s1", "list": 1, "until": String(repeating: "a", count: 1024)]))
    XCTAssertThrowsError(try plan("collect", ["screen": "s1", "list": 1, "until": String(repeating: "a", count: 1025)]))
    XCTAssertThrowsError(try plan("collect", ["screen": "s1", "list": 1, "until": ""]))
  }

  func testDirectionAndSystemKeyAllowlistsDoNotExposeRawHID() throws {
    for direction in ["up", "down", "left", "right"] {
      XCTAssertNoThrow(try plan("scroll", ["screen": "s1", "direction": direction]))
    }
    for direction in ["Down", "diagonal", "", "home"] {
      XCTAssertThrowsError(try plan("scroll", ["screen": "s1", "direction": direction]))
    }
    for key in ["home", "back", "notifications"] { XCTAssertNoThrow(try plan("key", ["key": key])) }
    for key in ["recents", "0xe3", "enter", "command+v", ""] {
      XCTAssertThrowsError(try plan("key", ["key": key]))
    }
  }

  func testASCIIIsValidatedAsACompleteBoundedString() throws {
    let maximum = String(repeating: "a", count: 1024)
    let accepted = try type(maximum)
    XCTAssertTrue(accepted.text == maximum)
    XCTAssertFalse(accepted.usesClipboard)
    XCTAssertThrowsError(try type(maximum + "b"))
    XCTAssertThrowsError(try type(""))
    XCTAssertThrowsError(try type("first line\nsecond line"))
    XCTAssertThrowsError(try type("first\tcolumn"))
    XCTAssertThrowsError(try type("中文\n下一行"))
    XCTAssertThrowsError(try type("中文\t下一列"))
  }

  func testUnicodeLimitCountsUTF8BytesAndNeverTruncatesOrSplits() throws {
    let maximum = String(repeating: "中", count: 1365) + "A"
    XCTAssertEqual(maximum.utf8.count, 4096)
    let accepted = try type(maximum)
    XCTAssertTrue(accepted.text == maximum)
    XCTAssertTrue(accepted.usesClipboard)
    XCTAssertThrowsError(try type(maximum + "B"))
    let mixed = String(repeating: "a", count: 4094) + "é"
    XCTAssertEqual(mixed.utf8.count, 4096)
    XCTAssertTrue(try type(mixed).usesClipboard)
    // An otherwise long ASCII string takes the separately bounded Unicode path
    // only when the FULL approved value actually contains a non-ASCII scalar.
    XCTAssertTrue(try type(String(repeating: "a", count: 1024) + "中").usesClipboard)
  }

  func testUnsupportedControlScalarsRefuseTheWholeInput() throws {
    for scalar in [0x00, 0x01, 0x08, 0x09, 0x0a, 0x0b, 0x0d, 0x1b, 0x1f, 0x7f, 0x80, 0x85, 0x9f,
                   0x061c, 0x200e, 0x200f, 0x2028, 0x2029, 0x202a, 0x202b, 0x202c, 0x202d, 0x202e,
                   0x2066, 0x2067, 0x2068, 0x2069] {
      let character = try XCTUnwrap(UnicodeScalar(scalar))
      let input = "safe prefix" + String(character) + "safe suffix"
      XCTAssertThrowsError(try type(input))
    }
    XCTAssertThrowsError(try type("safe prefix\u{1b}中safe suffix"))
  }

  func testShortAllDigitInputsAreHandedToTheUser() throws {
    for input in ["123", "1234", "12345", "123456", "1234567", "12345678",
                  " 123456 ", "12-34-56", "1 2 3 4 5 6", "１２３４５６", "١٢٣٤٥٦"] {
      XCTAssertThrowsError(try type(input)) { error in
        XCTAssertTrue((error as? IOSPhoneOperationError)?.message.contains("handoff") == true)
      }
    }
  }

  func testUnicodeHyphenNumericCodesAreHandedToTheUser() throws {
    for separator in ["\u{2010}", "\u{2011}", "\u{2013}", "\u{2212}"] {
      for input in ["123" + separator + "456", "１２３" + separator + "４５６",
                    "١٢٣" + separator + "٤٥٦"] {
        XCTAssertThrowsError(try type(input)) { error in
          XCTAssertTrue((error as? IOSPhoneOperationError)?.message.contains("handoff") == true)
        }
      }
    }
    for input in ["1\u{2010}2\u{2011}3", "12\u{2212}34\u{2013}56",
                  "\u{00a0}12\u{2010}34\u{2011}56\u{00a0}"] {
      XCTAssertThrowsError(try type(input))
    }
  }

  func testUnicodeCodeSeparatorsKeepTheThreeThroughEightDigitBoundary() throws {
    for separator in ["\u{2010}", "\u{2011}", "\u{2013}", "\u{2212}"] {
      for count in [2, 3, 8, 9] {
        let input = Array(repeating: "1", count: count).joined(separator: separator)
        if (3...8).contains(count) {
          XCTAssertThrowsError(try type(input))
        } else {
          let accepted = try type(input)
          XCTAssertEqual(accepted.text, input)
          XCTAssertEqual(accepted.parameters["text"] as? String, input)
        }
      }
    }
  }

  func testOrdinaryUnicodeHyphenatedTextIsPreservedExactly() throws {
    for input in ["Room\u{2010}123", "synthetic\u{2011}text", "A\u{2212}123", "word\u{2013}word"] {
      let accepted = try type(input)
      XCTAssertEqual(accepted.text, input)
      XCTAssertEqual(accepted.parameters["text"] as? String, input)
      XCTAssertTrue(accepted.consentDescription(targetLabel: nil).contains(input))
    }
  }

  func testEveryConsentIdentifierRejectsControlsBeforeAPlanExists() throws {
    let fields: [(String, [String: Any], String)] = [
      ("apps", [:], "query"), ("open", [:], "app"),
      ("tap", ["id": 1], "screen"), ("tap_xy", ["x": 0, "y": 0], "observation"),
      ("type", ["id": 1, "text": "synthetic"], "screen"),
      ("scroll", ["direction": "down"], "screen"),
      ("collect", ["list": 1], "screen"),
      ("collect", ["screen": "s1", "list": 1], "until"),
      ("key", ["key": "home"], "screen"),
    ]
    let controls = Array(0x00...0x1f) + Array(0x7f...0x9f)
      + [0x061c, 0x200e, 0x200f, 0x2028, 0x2029]
      + Array(0x202a...0x202e) + Array(0x2066...0x2069)
    for (method, base, field) in fields {
      for codePoint in controls {
        var input = base
        input[field] = "safe" + String(try XCTUnwrap(UnicodeScalar(codePoint))) + "suffix"
        XCTAssertThrowsError(try plan(method, input), "accepted \(method).\(field), U+\(String(codePoint, radix: 16))")
      }
    }
  }

  func testConsentFieldsAreQuotedAndEscapedWithoutChangingExecutionArguments() throws {
    let raw = "Synthetic \"name\"\\suffix"
    let quoted = "\"Synthetic \\\"name\\\"\\\\suffix\""
    let open = try plan("open", ["app": raw])
    XCTAssertTrue(open.consentDescription(targetLabel: nil).hasPrefix("打开应用：" + quoted + "。"))
    XCTAssertEqual(open.parameters["app"] as? String, raw)
    let apps = try plan("apps", ["query": raw])
    XCTAssertTrue(apps.consentDescription(targetLabel: nil).hasSuffix("筛选：" + quoted))
    XCTAssertEqual(apps.parameters["query"] as? String, raw)
    let tap = try plan("tap", ["screen": raw, "id": 1])
    XCTAssertTrue(tap.consentDescription(targetLabel: nil).contains("屏幕 " + quoted + " 的编号"))
    XCTAssertEqual(tap.screen, raw)
    let xy = try plan("tap_xy", ["observation": raw, "x": 1, "y": 2])
    XCTAssertTrue(xy.consentDescription(targetLabel: nil).contains("截图 " + quoted + " 中的像素"))
    let input = try plan("type", ["screen": raw, "id": 1, "text": "full approved text"])
    XCTAssertTrue(input.consentDescription(targetLabel: nil).contains("屏幕 " + quoted + " 的编号"))
  }

  func testDisplayIsBoundedButApprovedTextAndIdentifiersAreNeverTruncated() throws {
    let app = String(repeating: "a", count: 256)
    let open = try plan("open", ["app": app])
    XCTAssertTrue(open.consentDescription(targetLabel: nil).hasPrefix("打开应用：\"" + String(repeating: "a", count: 80) + "…\"。"))
    XCTAssertFalse(open.consentDescription(targetLabel: nil).contains(String(repeating: "a", count: 81)))
    XCTAssertEqual(open.parameters["app"] as? String, app)
    let exact = try plan("apps", ["query": String(repeating: "中", count: 80)])
    XCTAssertTrue(exact.consentDescription(targetLabel: nil).hasSuffix("\"" + String(repeating: "中", count: 80) + "\""))
    let combined = "A" + String(repeating: "\u{0301}", count: 90)
    let query = try plan("apps", ["query": combined])
    XCTAssertTrue(query.consentDescription(targetLabel: nil).hasSuffix("\"A" + String(repeating: "\u{0301}", count: 79) + "…\""))
    XCTAssertEqual(query.parameters["query"] as? String, combined)
    let text = String(repeating: "中", count: 1000)
    let input = try type(text)
    XCTAssertTrue(input.consentDescription(targetLabel: nil).contains(text))
    XCTAssertEqual(input.text, text)
  }

  func testOCRTargetLabelsCannotAddLinesOrDirectionControlsToConsent() throws {
    let value = try plan("tap", ["screen": "s1", "id": 1])
    let label = "first\nsecond\t\u{202e}\u{2028}\u{2029}\"\\"
    let description = value.consentDescription(targetLabel: label)
    XCTAssertTrue(description.hasSuffix("上次观察中的目标：\"first\\u000Asecond\\u0009\\u202E\\u2028\\u2029\\\"\\\\\""))
    XCTAssertEqual(description.filter { $0 == "\n" }.count, 1)
    XCTAssertFalse(description.contains("\u{202e}"))
    XCTAssertFalse(description.contains("\u{2028}"))
    XCTAssertFalse(description.contains("\u{2029}"))
  }

  func testRawParameterJSONHasItsOwnLimitBeforeAnyPlanCanBeUsed() throws {
    let base = "{\"query\":\"synthetic\"}"
    let maximum = base + String(repeating: " ", count: 16_384 - base.utf8.count)
    XCTAssertEqual(maximum.utf8.count, 16_384)
    XCTAssertNoThrow(try IOSPhoneOperation(request(method: "apps", raw: maximum)))
    XCTAssertThrowsError(try IOSPhoneOperation(request(method: "apps", raw: maximum + " ")))
  }

  func testConsentDisplaysTheCompleteUnicodeValueAndBothExtraBehaviors() throws {
    let input = "SYNTHETIC-BEGIN " + String(repeating: "中", count: 1000) + " SYNTHETIC-END"
    let value = try type(input, submit: true)
    let description = value.consentDescription(targetLabel: "Synthetic destination")
    XCTAssertTrue(description.contains(input), "approval omitted part of the validated input")
    XCTAssertTrue(description.contains("替换原内容"))
    XCTAssertTrue(description.contains("Synthetic destination"))
    XCTAssertTrue(description.contains("临时使用剪贴板"))
    XCTAssertTrue(description.contains("CoreDevice 路线"))
    XCTAssertTrue(description.contains("不发送给模型"))
    XCTAssertTrue(description.contains("回到 DSH Go 恢复原内容"))
    XCTAssertTrue(description.contains("本 App 在恢复前终止"))
    XCTAssertTrue(description.contains("还请求按回车／发送"))
    XCTAssertTrue(description.contains("完整输入文字"))
    XCTAssertTrue(description.contains("不会自动派发回车／发送按键"))
    XCTAssertTrue(description.contains("只返回固定状态"))
    XCTAssertTrue(value.usesClipboard)
    XCTAssertTrue(value.submits)
  }

  func testASCIIConsentDoesNotClaimClipboardOrAnUnrequestedSubmit() throws {
    let value = try type("synthetic ASCII")
    let description = value.consentDescription(targetLabel: nil)
    XCTAssertTrue(description.contains("synthetic ASCII"))
    XCTAssertTrue(description.contains("替换原内容"))
    XCTAssertFalse(description.contains("剪贴板"))
    XCTAssertFalse(description.contains("回车／发送"))
    XCTAssertFalse(value.usesClipboard)
    XCTAssertFalse(value.submits)
  }

  func testASCIIRequestedSubmitStillDescribesItsReadbackGate() throws {
    let value = try type("synthetic ASCII", submit: true)
    let description = value.consentDescription(targetLabel: nil)
    XCTAssertFalse(value.usesClipboard)
    XCTAssertTrue(value.submits)
    XCTAssertTrue(description.contains("只有新的读屏能核对完整输入文字时才继续"))
    XCTAssertFalse(description.contains("只返回固定状态"))
  }

  func testReadAndTapDescriptionsPreserveTheRequestedScope() throws {
    let textOnly = try plan("screen", ["image": false])
    let withImage = try plan("screen", ["image": true])
    XCTAssertFalse(textOnly.consentDescription(targetLabel: nil).contains("标号截图"))
    XCTAssertTrue(withImage.consentDescription(targetLabel: nil).contains("标号截图"))
    let tap = try plan("tap", ["screen": "s7", "id": 12, "long": true])
    let tapDescription = tap.consentDescription(targetLabel: "Synthetic label")
    XCTAssertTrue(tapDescription.hasPrefix("长按"))
    XCTAssertTrue(tapDescription.contains("s7"))
    XCTAssertTrue(tapDescription.contains("编号 12"))
    XCTAssertTrue(tapDescription.contains("Synthetic label"))
    let coordinates = try plan("tap_xy", ["observation": "s9", "x": 123, "y": 456])
    XCTAssertTrue(coordinates.consentDescription(targetLabel: nil).contains("s9"))
    XCTAssertTrue(coordinates.consentDescription(targetLabel: nil).contains("(123, 456)"))
    let open = try plan("open", ["app": "test.synthetic.app"])
    XCTAssertTrue(open.consentDescription(targetLabel: nil).contains("不代表应用已到前台"))
  }
}
