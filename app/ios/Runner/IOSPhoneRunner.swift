import Foundation
import UIKit
import UserNotifications

/// Reaches the separately installed XCTest runner that reads and drives other apps.
/// A Mac can keep it running, or an opt-in build can start it through device services.
///
/// No sheet can appear over another app, so asking before each tap isn't possible. The user
/// grants a limited stretch of time instead, here, before leaving. Passwords, codes and payment
/// details stay refused throughout, by the runner, where the screen can be seen.
@MainActor
final class IOSPhoneRunner {
  private static let group = "group.io.github.ccch1mneyyy.dshgo"
  private static let grantLasts: TimeInterval = 30 * 60
  private static let missing =
    "手机操控没有运行，所以这一步没有执行。请告诉用户：先在 Mac 上运行 tooling/ios/phone-runner.sh，让手机操控的测试进程跑起来，再重试。不要自动反复重试。"

  private typealias Endpoint = PhoneRunnerEndpoint

  private let actions: IOSPhoneActions
  private let session: URLSession
  private let selfRunner: IOSPhoneSelfRunner
  private var selfOwnerID = UUID().uuidString
  private var grantedUntil: Date?

  init(actions: IOSPhoneActions, selfRunner: IOSPhoneSelfRunner? = nil) {
    self.actions = actions
    self.selfRunner = selfRunner ?? .shared
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.connectionProxyDictionary = [:]
    session = URLSession(configuration: configuration)
  }

  /// The run is over, and what the user granted was for it.
  func retire() {
    grantedUntil = nil
    selfRunner.stop(ownerID: selfOwnerID)
    selfOwnerID = UUID().uuidString
  }

  func cancelPreparation() { selfRunner.cancelPreparation(ownerID: selfOwnerID) }

  func run(_ request: IOSPhoneRequest, current: () -> Bool) async -> IOSPhoneOutcome {
    if request.action.kind == "runner-handoff" { return await handOver(request) }
    guard !Task.isCancelled, current() else { return .failure(IOSPhoneSelfRunnerError.cancelled.message) }
    let useSelfRunner = selfRunner.isConfigured
    var endpoint = useSelfRunner ? nil : readEndpoint()
    guard useSelfRunner || endpoint != nil else { return .failure(Self.missing) }
    guard await granted(request) else {
      return .failure(UIApplication.shared.applicationState == .active
        ? "用户没有允许操控手机。不要自动重试。"
        : "操控手机的授权还没有或已经过期，要等用户回到 DSH Go 才能问。")
    }
    // Both consent and a developer-service bootstrap can outlive the tool call.
    guard !Task.isCancelled, current() else { return .failure(IOSPhoneSelfRunnerError.cancelled.message) }
    if useSelfRunner {
      let ownerID = selfOwnerID
      let prepared = await selfRunner.prepare(ownerID: ownerID, current: current)
      guard selfOwnerID == ownerID, !Task.isCancelled, current() else { return .failure(IOSPhoneSelfRunnerError.cancelled.message) }
      switch prepared {
      case .success(let ready): endpoint = ready
      case .failure(let error):
        // This is still before any phone RPC. A native session that has not
        // confirmed shutdown must not race an already-running Mac runner.
        guard selfRunner.mayUseMacFallback, let existing = readEndpoint() else { return .failure(error.message) }
        endpoint = existing
      }
    }
    guard let endpoint else { return .failure(Self.missing) }
    return await call(endpoint, request: request, current: current)
  }

  private func granted(_ request: IOSPhoneRequest) async -> Bool {
    if let until = grantedUntil, until > Date() { return true }
    let allowed = await actions.confirm(
      request, title: "允许 AI 操控这台手机？",
      detail: "接下来 30 分钟，AI 可以看到屏幕上的内容，打开应用、点击和输入，切到别的应用时也一样。\n\n密码、验证码和支付信息它不能填，会交给你。\n\n想让它停，回到 DSH Go 结束这一轮。",
      allow: "允许 30 分钟", deny: "拒绝")
    if allowed { grantedUntil = Date().addingTimeInterval(Self.grantLasts) }
    return allowed
  }

  private func readEndpoint() -> Endpoint? {
    guard
      let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.group),
      let data = try? Data(contentsOf: directory.appendingPathComponent("phone-runner/endpoint.json")),
      data.count <= 4096, let endpoint = try? JSONDecoder().decode(Endpoint.self, from: data), endpoint.isValid(),
      endpoint.runId == nil
    else { return nil }
    return endpoint
  }

  private func call(_ endpoint: Endpoint, request: IOSPhoneRequest, current: () -> Bool) async -> IOSPhoneOutcome {
    guard !Task.isCancelled, current(), request.expiresAt > Date().timeIntervalSince1970 * 1000,
      endpoint.runId == nil || selfRunner.owns(endpoint) else {
      return .failure(IOSPhoneSelfRunnerError.cancelled.message)
    }
    guard let url = URL(string: "http://127.0.0.1:\(endpoint.port)/rpc"),
      let arguments = try? JSONSerialization.jsonObject(with: Data((request.action.params ?? "{}").utf8))
    else { return .failure("参数无效。") }
    var values: [String: Any] = ["method": request.action.method ?? "", "params": arguments, "expiresAt": request.expiresAt]
    if let runId = endpoint.runId { values["runId"] = runId }
    guard let body = try? JSONSerialization.data(withJSONObject: values) else { return .failure("参数无效。") }
    var http = URLRequest(url: url)
    http.httpMethod = "POST"
    http.timeoutInterval = min(110, max(0.001, (request.expiresAt - Date().timeIntervalSince1970 * 1000) / 1000))
    http.setValue("Bearer " + endpoint.token, forHTTPHeaderField: "Authorization")
    http.setValue("application/json", forHTTPHeaderField: "Content-Type")
    http.httpBody = body
    do {
      let (data, response) = try await session.data(for: http)
      guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return .failure("手机操控返回了无效结果，请核对屏幕，不要自动重试。")
      }
      guard (response as? HTTPURLResponse)?.statusCode == 200, result["ok"] as? Bool == true else {
        let message = result["error"] as? String ?? "手机操控没有完成这一步。"
        return .failure(message + "\n这一步不会自动重试。")
      }
      var text = result["text"] as? String ?? ""
      if let warning = result["warning"] as? String { text += "\n（注意：\(warning)）" }
      let image = (result["image"] as? String).flatMap { Data(base64Encoded: $0) }
      return IOSPhoneOutcome(text: text, isError: false, image: image)
    } catch let error as URLError where error.code == .cannotConnectToHost {
      return .failure(endpoint.runId == nil ? Self.missing : "端上 XCTest 运行器已经不可连接。请检查运行器，不要自动重复这一步。")
    } catch {
      return .failure("手机操控这一步的结果未知，请核对屏幕，不要自动重试。")
    }
  }

  /// The user does something themselves, likely in another app, and comes back to say they did.
  /// A notification is how they find out when DSH Go isn't in front. Tapping it only opens the app.
  private func handOver(_ request: IOSPhoneRequest) async -> IOSPhoneOutcome {
    let reason = request.action.text ?? ""
    if UIApplication.shared.applicationState != .active {
      let content = UNMutableNotificationContent()
      content.title = "AI 请你接手"
      content.body = reason
      try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: request.id, content: content, trigger: nil))
    }
    while !Task.isCancelled, request.expiresAt > Date().timeIntervalSince1970 * 1000 {
      if UIApplication.shared.applicationState == .active, UIApplication.shared.isProtectedDataAvailable {
        let finished = await actions.confirm(
          request, title: "AI 请你接手", detail: "\(reason)\n\n可以先切到别的应用去做，做完回来点「继续」。",
          allow: "继续", deny: "停止", waitsForever: true)
        if finished { return .success("用户说做完了。先用 screen 看一下现在的屏幕。") }
        // Leaving the app dismisses the sheet, which isn't an answer. Asked again on the way back.
        if UIApplication.shared.applicationState == .active { return .failure("用户选择停止。不要自动重试。") }
      }
      try? await Task.sleep(nanoseconds: 1_000_000_000)
    }
    return .failure("用户没有在时间内回来。")
  }
}
