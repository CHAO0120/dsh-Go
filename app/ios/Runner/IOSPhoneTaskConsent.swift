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
    let allowed = await actions.confirm(request, title: "允许这一次手机动作？",
      detail: detail + suffix, allow: "允许这一次", deny: "拒绝", preview: preview)
    return allowed && live() && isGranted && grantOwner == owner && foreground
  }

  func prepareForeground(_ request: IOSPhoneRequest, current: () -> Bool) async -> Bool {
    await waitForForeground(request, current: current)
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

  private func waitForForeground(_ request: IOSPhoneRequest, current: () -> Bool) async -> Bool {
    if foreground { return current() }
    let center = UNUserNotificationCenter.current()
    let settings = await center.notificationSettings()
    if current(), [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) {
      let content = UNMutableNotificationContent()
      content.title = "手机操控等待你确认"
      content.body = "请回到 DSH Go 查看这一次动作。点这条通知只打开 App，不会批准或执行。"
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
