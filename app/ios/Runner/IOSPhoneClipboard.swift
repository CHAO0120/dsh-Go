import Foundation
import UIKit

enum IOSPhoneClipboardError: String, Error {
  case foreground = "ERR_PHONE_CLIPBOARD_FOREGROUND_REQUIRED"
  case pending = "ERR_PHONE_CLIPBOARD_RESTORE_PENDING"
  case unavailable = "ERR_PHONE_CLIPBOARD_UNAVAILABLE"
  case tooLarge = "ERR_PHONE_CLIPBOARD_TOO_LARGE"
  case changed = "ERR_PHONE_CLIPBOARD_CHANGED"
  case stale = "ERR_PHONE_CLIPBOARD_STALE"
}

@MainActor
protocol IOSPhonePasteboardClient {
  var changeCount: Int { get }
  var itemCount: Int { get }
  func types() -> [[String]]?
  func data(type: String, item: Int) -> Data?
  func replace(_ items: [[String: Any]], expires: Date?)
}

@MainActor
private final class IOSPhoneSystemPasteboard: IOSPhonePasteboardClient {
  private var board: UIPasteboard { .general }
  var changeCount: Int { board.changeCount }
  var itemCount: Int { board.numberOfItems }
  func types() -> [[String]]? { board.types(forItemSet: nil) }
  func data(type: String, item: Int) -> Data? {
    guard let values = board.data(forPasteboardType: type, inItemSet: IndexSet(integer: item)),
      values.count == 1 else { return nil }
    return values[0]
  }
  func replace(_ items: [[String: Any]], expires: Date?) {
    var options: [UIPasteboard.OptionsKey: Any] = [.localOnly: true]
    if let expires { options[.expirationDate] = expires }
    board.setItems(items, options: options)
  }
}

/// Saves every materializable representation of a bounded pasteboard snapshot
/// in this process only. It has no export/log/file interface. UIKit supplies no
/// cross-process compare-and-swap and no paste-consumption acknowledgement;
/// counter/marker checks are conservative observations, not an atomic guarantee.
@MainActor
final class IOSPhoneClipboard {
  static let shared = IOSPhoneClipboard(client: IOSPhoneSystemPasteboard())
  private static let markerType = "io.github.ccch1mneyyy.dshgo.phone-paste-lease"
  private static let textType = "public.utf8-plain-text"
  private final class Lease {
    let id = UUID()
    let original: [[String: Data]]
    let temporaryText: Data
    let created = Date()
    var writtenCount: Int?
    var pasteAttempted = false
    var restoreRequested = false
    init(original: [[String: Data]], text: String) {
      self.original = original; self.temporaryText = Data(text.utf8)
    }
    var marker: Data { Data(id.uuidString.utf8) }
  }
  private let client: IOSPhonePasteboardClient
  private let foreground: () -> Bool
  private let settle: () async -> Void
  private var lease: Lease?
  private var busy = false
  var onStateChanged: (() -> Void)?

  init(client: IOSPhonePasteboardClient,
       foreground: @escaping () -> Bool = {
         UIApplication.shared.applicationState == .active && UIApplication.shared.isProtectedDataAvailable
       }, settle: @escaping () async -> Void = {
         await withCheckedContinuation { continuation in
           DispatchQueue.main.async { DispatchQueue.main.async { continuation.resume() } }
         }
       }) {
    self.client = client; self.foreground = foreground; self.settle = settle
  }

  var hasPendingRestore: Bool { lease != nil }
  var restorationID: UUID? { lease?.id }
  func status() -> [String: Any] {
    ["pendingRestore": lease != nil, "foregroundRequired": true, "memoryOnly": true,
     "pasteMayHaveBeenDispatched": lease?.pasteAttempted ?? false,
     "restoreRequested": lease?.restoreRequested ?? false]
  }

  /// Called only AFTER the native per-call button, while the app is foreground.
  /// Failure before replace leaves the pasteboard alone; failure after replace
  /// retains the original for the foreground restore flow.
  func begin(text: String, current: @escaping () -> Bool) async throws -> UUID {
    guard !busy, lease == nil else { throw IOSPhoneClipboardError.pending }
    guard foreground(), current(), !Task.isCancelled else { throw IOSPhoneClipboardError.foreground }
    guard !text.isEmpty, text.utf8.count <= 4096, !text.contains("\0") else { throw IOSPhoneClipboardError.tooLarge }
    busy = true
    defer { busy = false }
    let count = client.changeCount
    let number = client.itemCount
    guard (0...16).contains(number) else { throw IOSPhoneClipboardError.tooLarge }
    let types: [[String]]? = number == 0 ? [] : client.types()
    guard let types, types.count == number else { throw IOSPhoneClipboardError.unavailable }
    var snapshot: [[String: Data]] = []
    var bytes = 0
    for (index, representations) in types.enumerated() {
      guard !representations.isEmpty, representations.count <= 32,
        Set(representations).count == representations.count else { throw IOSPhoneClipboardError.tooLarge }
      var item: [String: Data] = [:]
      for type in representations {
        guard !type.isEmpty, type.utf8.count <= 256, !type.contains("\0"),
          let data = client.data(type: type, item: index) else { throw IOSPhoneClipboardError.unavailable }
        // UIKit materializes a representation before returning its size. This
        // caps retained data; it cannot promise a pre-allocation OS read limit.
        guard data.count <= 4 * 1024 * 1024 - bytes else { throw IOSPhoneClipboardError.tooLarge }
        bytes += data.count; item[type] = data
      }
      snapshot.append(item)
    }
    // changeCount is published at an event-loop boundary, not necessarily by a
    // synchronous setter. This yield is not a paste ACK or a fixed-delay proof.
    await settle()
    guard foreground(), current(), !Task.isCancelled else { throw IOSPhoneClipboardError.foreground }
    guard client.changeCount == count, client.itemCount == number,
      (number == 0 || client.types() == types), matches(snapshot),
      client.changeCount == count else { throw IOSPhoneClipboardError.changed }
    let saved = Lease(original: snapshot, text: text)
    lease = saved
    client.replace([[Self.textType: saved.temporaryText, Self.markerType: saved.marker]],
      expires: Date().addingTimeInterval(10 * 60))
    await settle()
    guard lease === saved else { throw IOSPhoneClipboardError.stale }
    saved.writtenCount = client.changeCount
    guard current(), !Task.isCancelled, foreground(), saved.writtenCount != count,
      owns(saved) else {
      saved.restoreRequested = true; onStateChanged?()
      throw IOSPhoneClipboardError.changed
    }
    onStateChanged?()
    return saved.id
  }

  /// Reads only our private marker and the already-approved temporary text. If
  /// UIKit denies this in the background, or another copy replaced it, refuse
  /// the paste. Never substitute another clipboard value or send a prefix.
  func validateForPaste(_ id: UUID) throws {
    guard let saved = lease, saved.id == id else { throw IOSPhoneClipboardError.stale }
    guard owns(saved) else { throw IOSPhoneClipboardError.changed }
    saved.pasteAttempted = true
  }

  func requestRestore(_ id: UUID) {
    guard let saved = lease, saved.id == id else { return }
    saved.restoreRequested = true; onStateChanged?()
    // If no HID paste was even attempted, foreground cancellation can restore
    // immediately. A potentially dispatched paste requires a new real user
    // confirmation after returning, rather than restoring behind the target.
    if !saved.pasteAttempted, foreground() {
      Task { [weak self, weak saved] in
        guard let self, let saved, self.lease === saved, !saved.pasteAttempted else { return }
        try? await self.restore(id: id, overwriteChanged: false, current: { self.lease === saved && !saved.pasteAttempted })
      }
    }
  }

  /// overwriteChanged may be true only following the separate foreground sheet
  /// that explicitly asks to replace a changed clipboard with the saved one.
  func restore(id: UUID? = nil, overwriteChanged: Bool = false,
               current: @escaping () -> Bool) async throws {
    guard !busy, let saved = lease, id == nil || saved.id == id else { throw IOSPhoneClipboardError.stale }
    guard foreground(), current(), !Task.isCancelled else { throw IOSPhoneClipboardError.foreground }
    busy = true
    defer { busy = false }
    await settle()
    guard lease === saved, foreground(), current(), !Task.isCancelled else { throw IOSPhoneClipboardError.stale }
    guard overwriteChanged || owns(saved) else { throw IOSPhoneClipboardError.changed }
    let items: [[String: Any]] = saved.original.map { item in item.mapValues { $0 as Any } }
    // The current marker/count are checked immediately before this write. UIKit
    // offers no atomic compare-and-swap with an external clipboard writer.
    client.replace(items, expires: nil)
    await settle()
    guard lease === saved, foreground(), current(), !Task.isCancelled else { throw IOSPhoneClipboardError.stale }
    // An ignored/failed UIKit write must not discard the only retained copy.
    // Verify the representations themselves; the counter can still be pending
    // until the event loop publishes it and is not a write acknowledgement.
    guard matches(saved.original) else { throw IOSPhoneClipboardError.unavailable }
    lease = nil
    onStateChanged?()
    // The original localOnly/expiry metadata is not readable through this API;
    // restoration preserves representations, uses localOnly=true, and does not
    // claim to reconstruct the previous Handoff or expiration policy.
  }

  func discardSaved(id: UUID? = nil) throws {
    guard !busy, foreground(), let saved = lease, id == nil || saved.id == id else {
      throw IOSPhoneClipboardError.foreground
    }
    lease = nil; onStateChanged?()
    // No attempt to overwrite the current clipboard. Swift/Data copies prevent
    // a truthful promise of universal memory zeroization here.
  }

  /// Run before a later phone call. This sheet is separate from that call's own
  /// approval and cannot donate its tap as permission to operate another app.
  func resolvePending(_ request: IOSPhoneRequest, actions: IOSPhoneActions,
                      current: @escaping () -> Bool) async -> Bool {
    guard let saved = lease else { return true }
    guard foreground(), current() else { return false }
    let prompt = saved.pasteAttempted
      ? "请先核对目标应用已经完成或取消粘贴。恢复原剪贴板前不会再发送粘贴；原内容仅保存在本 App 内存，不发送给模型。"
      : "上次没有派发粘贴；恢复临时保存的原剪贴板后，才会另行询问新的手机动作。"
    let allowed = await actions.confirm(request, title: "恢复原剪贴板？", detail: prompt,
      allow: "已核对，恢复", deny: "暂不恢复")
    guard allowed, current(), foreground(), lease === saved else { return false }
    do {
      try await restore(id: saved.id, current: current)
      return current()
    } catch IOSPhoneClipboardError.changed {
      let replace = await actions.confirm(request, title: "剪贴板已经变化",
        detail: "现在的剪贴板已不属于上次临时粘贴。是否用保存的旧内容覆盖它？暂不恢复会保留现在的剪贴板和本 App 中的旧副本；可到设置中另行决定。",
        allow: "覆盖并恢复旧内容", deny: "暂不恢复")
      guard replace, current(), foreground(), lease === saved else { return false }
      do {
        try await restore(id: saved.id, overwriteChanged: true, current: current)
        return current()
      } catch { return false }
    } catch { return false }
  }

  private func owns(_ saved: Lease) -> Bool {
    guard let count = saved.writtenCount, client.changeCount == count, client.itemCount == 1,
      let types = client.types(), types.count == 1,
      Set(types[0]) == Set([Self.markerType, Self.textType]), types[0].count == 2,
      client.data(type: Self.markerType, item: 0) == saved.marker,
      client.data(type: Self.textType, item: 0) == saved.temporaryText,
      client.changeCount == count, client.itemCount == 1,
      let finalTypes = client.types(), finalTypes.count == 1 else { return false }
    return finalTypes[0].count == 2 && Set(finalTypes[0]) == Set([Self.markerType, Self.textType])
  }

  /// Content read-back also narrows the interval before changeCount publishes.
  /// No sequence of these reads is a cross-process atomic snapshot or CAS.
  private func matches(_ original: [[String: Data]]) -> Bool {
    let count = client.changeCount
    guard client.itemCount == original.count else { return false }
    if original.isEmpty { return client.changeCount == count && client.itemCount == 0 }
    guard let types = client.types(), types.count == original.count else { return false }
    for (index, item) in original.enumerated() {
      guard types[index].count == item.count, Set(types[index]) == Set(item.keys) else { return false }
      for (type, data) in item where client.data(type: type, item: index) != data { return false }
    }
    guard client.changeCount == count, client.itemCount == original.count,
      let finalTypes = client.types(), finalTypes.count == original.count else { return false }
    return zip(finalTypes, original).allSatisfy { $0.0.count == $0.1.count && Set($0.0) == Set($0.1.keys) }
  }
}
