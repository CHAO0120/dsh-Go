import Foundation
import UIKit
import UserNotifications

/// A thirty-minute task grant and a new native button tap for every tool call.
/// Neither a notification, a model result, nor the general approval service can
/// supply the per-call answer. Only IOSPhoneActions' current native sheet can.
@MainActor
final class IOSPhoneTaskConsent {
  private struct Owner: Equatable {
    let runID: String
    let sessionID: String
  }
  private let actions: IOSPhoneActions
  private let now: () -> TimeInterval?
  private var grantOwner: Owner?
  private var grantedAt: TimeInterval?
  private var grantedUntil: TimeInterval?
  private var generation = UUID()

  init(actions: IOSPhoneActions, now: @escaping () -> TimeInterval? = IOSPhoneContinuousTime.now) {
    self.actions = actions; self.now = now
  }

  func retire() {
    generation = UUID(); grantOwner = nil; grantedAt = nil; grantedUntil = nil
  }

  var isGranted: Bool {
    remainingSeconds > 0
  }

  var remainingSeconds: TimeInterval {
    guard let start = grantedAt, let until = grantedUntil,
      let now = self.now(), now.isFinite,
      now >= start, now < until else { return 0 }
    return until - now
  }

  func approve(_ request: IOSPhoneRequest, detail: String, needsTarget: Bool, preview: Data? = nil,
               current: @escaping () -> Bool) async -> Bool {
    let operation = generation
    let owner = Owner(runID: request.runId, sessionID: request.owner.sessionId)
    let live = { !Task.isCancelled && current() && self.generation == operation
      && request.expiresAt > Date().timeIntervalSince1970 * 1000 }
    guard live(), detail.utf8.count <= 16_384,
      await waitForForeground(request, current: live) else { return false }
    if grantOwner != owner || !isGranted {
      let granted = await actions.confirm(request, title: "允许 AI 操控这台手机？",
        detail: "授权接下来 30 分钟的本次手机操控任务。它可读取屏幕、打开应用、触摸和输入；每个实际调用仍会在这里单独问你。\n\n密码、验证码和支付信息交给你处理。切到其他 App 时需保持宠物画中画；暂停、关闭连接或结束任务会撤销本次资格。",
        allow: "允许 30 分钟", deny: "拒绝")
      guard granted, live(), foreground, let now = self.now(), now.isFinite else { return false }
      grantOwner = owner; grantedAt = now; grantedUntil = now + 30 * 60
    }
    guard live(), isGranted else { return false }
    let suffix = needsTarget
      ? "\n\n允许后，请自行切回要操控的界面。DSH Go 会重新核对屏幕；界面变化或画中画停止时不继续。通知点击本身不批准。"
      : "\n\n仅执行本次调用；这不批准后续动作。"
    let clipboardSteps = (try? IOSPhoneOperation(request))?.usesClipboard == true
      ? "\n\n如果使用 CoreDevice 输入非 ASCII 文字：先切回目标检查焦点，再回到 DSH Go 确认临时剪贴板，最后切回目标粘贴。即使没有通知，也请在焦点点击后回到本 App；焦点检查未通过时不会修改剪贴板。"
      : ""
    let allowed = await actions.confirm(request, title: "允许这一次手机动作？",
      detail: detail + suffix + clipboardSteps, allow: "允许这一次", deny: "拒绝", preview: preview)
    return allowed && live() && isGranted && grantOwner == owner && foreground
  }

  func prepareForeground(_ request: IOSPhoneRequest, current: () -> Bool) async -> Bool {
    await waitForForeground(request, current: current)
  }

  /// A focus check in the target must precede this additional staging sheet.
  /// Returning to DSH Go alone does not authorize a clipboard replacement.
  func prepareClipboard(_ request: IOSPhoneRequest, current: @escaping () -> Bool) async -> Bool {
    guard (try? IOSPhoneOperation(request))?.usesClipboard == true else { return false }
    let operation = generation
    let owner = Owner(runID: request.runId, sessionID: request.owner.sessionId)
    let live = { !Task.isCancelled && current() && self.generation == operation
      && self.grantOwner == owner && self.isGranted
      && request.expiresAt > Date().timeIntervalSince1970 * 1000 }
    guard live(), await waitForForeground(request, current: live,
      notificationBody: "已检查本次输入目标的键盘线索。请回到 DSH Go 确认临时剪贴板；尚未修改剪贴板或输入文字。"),
      live(), foreground else { return false }
    let allowed = await actions.confirm(request, title: "准备本次非 ASCII 粘贴？",
      detail: "刚才已复核目标画面并检查键盘和敏感输入线索；这些线索不是输入焦点或安全性的证明。\n\n现在会在前台保存原剪贴板，并临时写入本次已批准的全文。原内容只保存在本 App 内存，不发送给模型。\n\n允许后请在 30 秒内自行切回刚才的输入界面，期间不要复制其他内容。DSH Go 会再次核对画面；后台无法回读剪贴板，不能保证发现其他 App 的并发复制。\n\n粘贴后请回到 DSH Go 核对并恢复原剪贴板；App 终止会丢失保存的原内容。取消不会撤回已派发的焦点点击。",
      allow: "准备剪贴板", deny: "取消输入")
    return allowed && live() && foreground
  }

  /// Waiting for the user to choose a target is not an automatic app switch.
  /// A protected-data lock or an actual loss of PiP stops admission immediately.
  func waitForTarget(_ request: IOSPhoneRequest, current: () -> Bool) async -> Bool {
    let operation = generation
    let deadline = min(Date().addingTimeInterval(45), Date(timeIntervalSince1970: request.expiresAt / 1000))
    while !Task.isCancelled, current(), generation == operation, isGranted,
      Date() < deadline, UIApplication.shared.isProtectedDataAvailable {
      if UIApplication.shared.applicationState == .background {
        // Give the system's automatic PiP transition a bounded opportunity to
        // complete, but never infer keep-alive merely from a configured source.
        let pipDeadline = min(Date().addingTimeInterval(3), deadline)
        while Date() < pipDeadline, !IOSPetOverlay.shared.isKeepingAlive,
          !Task.isCancelled, current(), generation == operation,
          UIApplication.shared.applicationState == .background,
          UIApplication.shared.isProtectedDataAvailable {
          do { try await Task.sleep(nanoseconds: 50_000_000) } catch { return false }
        }
        return current() && generation == operation && isGranted && !Task.isCancelled
          && UIApplication.shared.applicationState == .background
          && UIApplication.shared.isProtectedDataAvailable && IOSPetOverlay.shared.isKeepingAlive
      }
      do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return false }
    }
    return false
  }

  private var foreground: Bool {
    UIApplication.shared.applicationState == .active && UIApplication.shared.isProtectedDataAvailable
  }

  private func waitForForeground(_ request: IOSPhoneRequest, current: () -> Bool,
                                notificationBody: String = "请回到 DSH Go 查看这一次动作。点这条通知只打开 App，不会批准或执行。") async -> Bool {
    if foreground { return current() }
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    if current(), [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) {
      let content = UNMutableNotificationContent()
      content.title = "手机操控等待你确认"
      content.body = notificationBody
      // No action/category identifiers and no tool arguments or clipboard data.
      try? await center.add(UNNotificationRequest(identifier: request.id, content: content, trigger: nil))
    }
    defer { center.removeDeliveredNotifications(withIdentifiers: [request.id]) }
    while !Task.isCancelled, current() {
      if foreground { return true }
      do { try await Task.sleep(nanoseconds: 100_000_000) } catch { return false }
    }
    return false
  }
}
