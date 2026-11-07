import Foundation
import Darwin

struct IOSPhoneCoreFailure: Error {
  let code: String
  var variant: String?
  var mayHaveActed = false
}

struct IOSPhoneCoreEvent: Decodable, Sendable {
  var stage: String?
  var code: String?
  var variant: String?
  var completedBytes: Int64?
  var totalBytes: Int64?
  var capabilities: [String: Bool]?
  var cleanupConfirmed: Bool?
  var vpnReachable: Bool?
  var pairingVerified: Bool?
  var lockdownReady: Bool?
  var ddiMounted: Bool?
  var mayHaveActed: Bool?
}

struct IOSPhoneCoreReply: Sendable {
  struct Metadata: Decodable, Sendable {
    var outcome: String?
    var code: String?
    var mayHaveActed: Bool?
    var cleanupConfirmed: Bool?
    var contentType: String?
    var kind: String?
    var width: Int?
    var height: Int?
    var interfaceOrientation: Int?
    var nativeFrameId: String?
    var pid: UInt32?
    var foregroundVerified: Bool?
  }
  let status: Int32
  let metadata: Metadata
  let bytes: Data?
}

private func phoneCoreString(_ pointer: UnsafePointer<CChar>?, limit: Int) -> String? {
  guard let pointer else { return nil }
  let count = strnlen(pointer, limit + 1)
  guard count <= limit else { return nil }
  return String(bytes: UnsafeRawBufferPointer(start: pointer, count: count), encoding: .utf8)
}

#if DSH_PHONE_SELF_RUNNER
private func phoneCoreEventCallback(_ handle: UInt64, _ run: UnsafePointer<CChar>?,
                                    _ kind: Int32, _ payload: UnsafePointer<CChar>?) {
  guard let runID = phoneCoreString(run, limit: 36), UUID(uuidString: runID) != nil else { return }
  let text = phoneCoreString(payload, limit: 8192) ?? ""
  Task { @MainActor in IOSPhoneCoreDevice.deliverEvent(handle: handle, runID: runID, kind: kind, text: text) }
}

private func phoneCoreResultCallback(_ handle: UInt64, _ requestID: UInt64, _ status: Int32,
                                     _ payload: UnsafePointer<CChar>?, _ bytes: UnsafePointer<UInt8>?, _ count: Int) {
  let text = phoneCoreString(payload, limit: 8192) ?? ""
  let validBytes = count >= 0 && count <= 16 * 1024 * 1024 && (count == 0 || bytes != nil)
    && (status == 0 || count == 0)
  // The ABI's pointers expire at callback return. Copy on this thread before
  // hopping to MainActor, including screenshots and the bounded apps response.
  let data = validBytes && count > 0 ? Data(bytes: bytes!, count: count) : nil
  Task { @MainActor in
    IOSPhoneCoreDevice.deliverResult(handle: handle, requestID: requestID,
      status: validBytes ? status : -1, text: text, bytes: data)
  }
}
#endif

/// Swift owner of the CoreDevice branch of the EXISTING Rust singleton. It does
/// not create another pairing/tunnel stack or replay uncertain input on XCTest.
@MainActor
final class IOSPhoneCoreDevice {
  typealias EventSink = @MainActor (UInt64, String, Int32, String) -> Void
  typealias ResultSink = @MainActor (UInt64, UInt64, Int32, String, Data?) -> Void
  struct NativeClient {
    // Metadata and pairing plist are separate, synchronously borrowed inputs.
    let start: @MainActor (String, Data, Data, @escaping EventSink) -> (Int32, UInt64)
    let request: @MainActor (UInt64, UInt64, Data, @escaping ResultSink) -> Int32
    let cancel: @MainActor (UInt64, UInt64) -> Void
    let stop: @MainActor (UInt64) -> Void
  }

  static let shared = IOSPhoneCoreDevice()
  private static var eventCallbacks: [String: EventSink] = [:]
  private static var resultCallbacks: [String: ResultSink] = [:]

  private final class Request {
    let id: UInt64
    let mutating: Bool
    var reply: Result<IOSPhoneCoreReply, IOSPhoneCoreFailure>?
    init(id: UInt64, mutating: Bool) { self.id = id; self.mutating = mutating }
  }

  private final class Run {
    let id = UUID().uuidString.lowercased()
    let ownerID: String
    let pairingGeneration: UUID
    let deadline: Date
    var handle: UInt64 = 0
    var capabilities: [String: Bool]?
    var checks: [String: Bool] = [:]
    var failure: IOSPhoneCoreFailure?
    var stopping = false
    var terminal = false
    var faulted = false
    var pending: Request?
    var nextRequest: UInt64 = 1
    var stopDeadline: Date?
    init(ownerID: String, pairingGeneration: UUID, deadline: Date) {
      self.ownerID = ownerID; self.pairingGeneration = pairingGeneration; self.deadline = deadline
    }
  }

  private let native: NativeClient?
  private let pairing: IOSPhonePairingStore
  private let cache: IOSPhoneDDICache
  private let port: () async -> UInt16
  private let now: () -> Date
  private var active: Run?
  private var starter: Task<Void, Never>?
  private(set) var state: [String: Any] = ["phase": "idle", "code": "OK"]
  var onStateChanged: (() -> Void)?

  convenience init() {
    self.init(native: Self.makeNativeClient(), pairing: .shared, cache: .shared,
      port: {
        let raw = Bundle.main.object(forInfoDictionaryKey: "DSHPhoneRemotePairingPort")
        if let raw {
          let value = (raw as? NSNumber)?.intValue ?? (raw as? String).flatMap(Int.init)
          return value.flatMap(UInt16.init(exactly:)) ?? 0
        }
        return await PhoneRemotePairingPort.resolve()
      })
  }

  init(native: NativeClient?, pairing: IOSPhonePairingStore, cache: IOSPhoneDDICache,
       port: @escaping () async -> UInt16, now: @escaping () -> Date = Date.init) {
    self.native = native; self.pairing = pairing; self.cache = cache; self.port = port; self.now = now
  }

  var isAvailable: Bool { native != nil }
  var maySwitchBackend: Bool { active == nil || active?.terminal == true }
  var isReady: Bool { active?.capabilities != nil && active?.stopping == false && active?.faulted == false }

  /// An observation must bind to this native generation, not just the reusable
  /// application-level owner string. This ID contains no credential.
  func currentRunID(ownerID: String) -> String? {
    guard let run = active, run.ownerID == ownerID, run.pairingGeneration == pairing.generation,
      run.capabilities != nil, !run.stopping, !run.terminal, !run.faulted else { return nil }
    return run.id
  }

  func prepare(ownerID: String, allowDDIMount: Bool = false,
               current: () -> Bool) async -> Result<[String: Bool], IOSPhoneCoreFailure> {
    guard native != nil else { return .failure(.init(code: "ERR_PHONE_NATIVE_UNAVAILABLE")) }
    guard pairing.hasRecord else { return .failure(.init(code: "ERR_PHONE_PAIRING_REQUIRED")) }
    var observed: Run?
    while !Task.isCancelled, current() {
      if let run = observed {
        if let failure = run.failure { return .failure(failure) }
        guard active === run, !run.stopping, !run.terminal, run.pairingGeneration == pairing.generation else {
          return .failure(.init(code: "ERR_PHONE_CANCELLED"))
        }
        if let capabilities = run.capabilities { return .success(capabilities) }
        if now() >= run.deadline {
          stop(run)
          return .failure(.init(code: "ERR_PHONE_PREPARATION_TIMEOUT"))
        }
      } else if let run = active {
        if run.faulted { return .failure(.init(code: "ERR_PHONE_STOP_UNCONFIRMED")) }
        if run.terminal { active = nil; continue }
        if run.ownerID != ownerID || run.pairingGeneration != pairing.generation { stop(run) }
        if run.stopping {
          if let deadline = run.stopDeadline, now() >= deadline {
            return .failure(.init(code: "ERR_PHONE_STOPPING"))
          }
        } else { observed = run }
      } else {
        let run = Run(ownerID: ownerID, pairingGeneration: pairing.generation,
          deadline: now().addingTimeInterval(allowDDIMount ? 600 : 95))
        active = run; observed = run
        begin(run, allowDDIMount: allowDDIMount)
      }
      do { try await Task.sleep(nanoseconds: 50_000_000) }
      catch { break }
    }
    if let observed, active === observed { stop(observed) }
    return .failure(.init(code: "ERR_PHONE_CANCELLED"))
  }

  func request(_ values: [String: Any], ownerID: String,
               current: () -> Bool) async -> Result<IOSPhoneCoreReply, IOSPhoneCoreFailure> {
    guard !Task.isCancelled, current(), let native, let run = active,
      run.ownerID == ownerID, run.pairingGeneration == pairing.generation,
      run.capabilities != nil, !run.stopping, !run.faulted, !run.terminal else {
      return .failure(.init(code: "ERR_PHONE_CORE_NOT_READY"))
    }
    guard run.pending == nil, run.nextRequest < UInt64.max else { return .failure(.init(code: "ERR_PHONE_BUSY")) }
    guard let bytes = try? JSONSerialization.data(withJSONObject: values), bytes.count <= 16_384,
      let operation = values["op"] as? String else { return .failure(.init(code: "ERR_PHONE_ARGUMENTS")) }
    let pending = Request(id: run.nextRequest, mutating: !["screenshot", "apps"].contains(operation))
    run.nextRequest += 1
    run.pending = pending
    let accepted = native.request(run.handle, pending.id, bytes) { [weak self, weak run] handle, id, status, text, data in
      guard let self, let run else { return }
      self.receiveResult(run, handle: handle, id: id, status: status, text: text, bytes: data)
    }
    guard accepted == 0 else {
      if run.pending === pending { run.pending = nil }
      return .failure(.init(code: Self.acceptanceCode(accepted)))
    }
    let deadline = now().addingTimeInterval(["ascii", "prepareInput"].contains(operation) ? 110 : 35)
    while true {
      guard !Task.isCancelled, current(), active === run, !run.stopping,
        !run.terminal, !run.faulted, run.pairingGeneration == pairing.generation,
        now() < deadline else {
        native.cancel(run.handle, pending.id)
        stop(run)
        // Dispatch may already have happened. The late result and terminal
        // callback still own cleanup, but this caller never retries/falls back.
        return .failure(.init(code: "ERR_PHONE_ACTION_UNCONFIRMED", mayHaveActed: pending.mutating))
      }
      // Cancellation, revocation and an inline native callback can all occur
      // before request() returns. A stored result is not authority to report a
      // success after this exact owner/call has ceased to be current.
      if let reply = pending.reply { return reply }
      do { try await Task.sleep(nanoseconds: 20_000_000) }
      catch { /* Next iteration cancels the exact request and retires its owner. */ }
    }
  }

  func stop(ownerID: String? = nil) {
    guard let run = active, ownerID == nil || ownerID == run.ownerID else { return }
    stop(run)
  }

  private func stop(_ run: Run) {
    guard active === run, !run.stopping, !run.terminal, !run.faulted else { return }
    run.stopping = true; run.capabilities = nil
    run.stopDeadline = now().addingTimeInterval(12)
    starter?.cancel(); starter = nil
    if run.handle == 0 {
      run.terminal = true; active = nil
      setState(["phase": "idle", "code": "OK"])
    } else {
      setState(["phase": "stopping", "code": "ERR_PHONE_STOPPING"])
      native?.stop(run.handle)
    }
  }

  private func begin(_ run: Run, allowDDIMount: Bool) {
    setState(["phase": "starting", "stage": "pairing", "code": "OK"])
    starter = Task { [weak self, weak run] in
      guard let self, let run else { return }
      let servicePort = await self.port()
      guard !Task.isCancelled, self.active === run, !run.stopping,
        run.pairingGeneration == self.pairing.generation, self.now() < run.deadline,
        let native = self.native else { return }
      guard servicePort != 0 else {
        run.failure = .init(code: "ERR_PHONE_CONFIGURATION"); run.terminal = true
        self.setState(["phase": "failed", "code": "ERR_PHONE_CONFIGURATION"]); return
      }
      do {
        let configuration: [String: Any] = [
          "runId": run.id, "host": "10.7.0.1", "port": servicePort,
          "allowDDIMount": allowDDIMount,
          "ddiCache": self.cache.nativeConfiguration(),
        ]
        let encoded = try JSONSerialization.data(withJSONObject: configuration)
        guard encoded.count <= 96 * 1024 else { throw IOSPhonePairingError.tooLarge }
        let (status, handle) = try { () throws -> (Int32, UInt64) in
          let record = try self.pairing.load()
          guard !record.isEmpty, record.count <= IOSPhonePairingRecord.maximumBytes else {
            throw IOSPhonePairingError.tooLarge
          }
          // End this local hold at synchronous start. The store may deliberately
          // share Data backing storage; resetBytes could first create a CoW copy
          // and cannot promise to erase the retained session/Keychain record.
          return native.start(run.id, encoded, record) { [weak self, weak run] handle, id, kind, text in
            guard let self, let run else { return }
            self.receive(run, handle: handle, runID: id, kind: kind, text: text)
          }
        }()
        if run.handle != 0, run.handle != handle {
          run.faulted = true; run.failure = .init(code: "ERR_PHONE_CORE_PROTOCOL")
        } else { run.handle = handle }
        if status != 0 || handle == 0 {
          run.failure = .init(code: Self.acceptanceCode(status)); run.terminal = true
          self.setState(["phase": "failed", "code": run.failure!.code])
        }
      } catch {
        run.failure = .init(code: (error as? IOSPhonePairingError)?.code ?? "ERR_PHONE_CONFIGURATION")
        run.terminal = true
        self.setState(["phase": "failed", "code": run.failure!.code])
      }
    }
  }

  private func receive(_ run: Run, handle: UInt64, runID: String, kind: Int32, text: String) {
    guard active === run, run.id == runID, handle != 0, !run.terminal, !run.faulted else { return }
    if run.handle == 0 { run.handle = handle } // Native callbacks may precede start's return.
    guard run.handle == handle, text.utf8.count <= 8192,
      let event = try? JSONDecoder().decode(IOSPhoneCoreEvent.self, from: Data(text.utf8)) else {
      run.failure = .init(code: "ERR_PHONE_CORE_PROTOCOL"); stop(run); return
    }
    if let value = event.vpnReachable { run.checks["vpnReachable"] = value }
    if let value = event.pairingVerified { run.checks["pairingVerified"] = value }
    if let value = event.lockdownReady { run.checks["lockdownReady"] = value }
    if let value = event.ddiMounted { run.checks["ddiMounted"] = value }
    switch kind {
    case 0, 5:
      guard !run.stopping else { return }
      var value: [String: Any] = ["phase": "starting", "code": "OK"]
      if let stage = event.stage, ["pairing", "tunnel", "services", "verifyingAssets", "personalizing", "uploading", "mounting", "refreshingServices"].contains(stage) { value["stage"] = stage }
      if let count = event.completedBytes, count >= 0 { value["completedBytes"] = count }
      if let total = event.totalBytes, total > 0 { value["totalBytes"] = total }
      value["checks"] = run.checks; setState(value)
    case 1:
      guard !run.stopping, !run.faulted, let capabilities = event.capabilities,
        run.pairingGeneration == pairing.generation else { stop(run); return }
      run.capabilities = capabilities
      setState(["phase": "ready", "code": "OK", "capabilities": capabilities, "checks": run.checks])
    case 2, 3, 4:
      let code = Self.safeCode(event.code) ?? (kind == 2 ? "OK" : "ERR_PHONE_CORE_PROTOCOL")
      run.capabilities = nil
      run.failure = .init(code: kind == 2 ? "ERR_PHONE_CANCELLED" : code,
        variant: ["personalized", "cryptex"].contains(event.variant ?? "") ? event.variant : nil,
        mayHaveActed: event.mayHaveActed ?? (kind == 4))
      run.faulted = kind == 4
      run.terminal = kind != 4
      if let pending = run.pending, pending.reply == nil {
        pending.reply = .failure(.init(code: "ERR_PHONE_ACTION_UNCONFIRMED", mayHaveActed: pending.mutating))
      }
      run.pending = nil
      Self.eventCallbacks.removeValue(forKey: run.id)
      Self.resultCallbacks = Self.resultCallbacks.filter { !$0.key.hasPrefix("\(handle):") }
      var value: [String: Any] = ["phase": kind == 2 ? "idle" : (kind == 4 ? "faulted" : "failed"), "code": code]
      if let variant = run.failure?.variant { value["variant"] = variant }
      value["checks"] = run.checks
      setState(value)
    default:
      run.failure = .init(code: "ERR_PHONE_CORE_PROTOCOL"); stop(run)
    }
  }

  private func receiveResult(_ run: Run, handle: UInt64, id: UInt64, status: Int32, text: String, bytes: Data?) {
    guard active === run, run.handle == handle, let pending = run.pending,
      pending.id == id, pending.reply == nil else { return }
    guard !run.stopping, !run.terminal, !run.faulted,
      run.pairingGeneration == pairing.generation else {
      pending.reply = .failure(.init(code: "ERR_PHONE_ACTION_UNCONFIRMED", mayHaveActed: pending.mutating))
      run.pending = nil
      return
    }
    guard (0...3).contains(status), text.utf8.count <= 8192,
      let metadata = try? JSONDecoder().decode(IOSPhoneCoreReply.Metadata.self, from: Data(text.utf8)),
      ["read", "dispatched", "notSent", "uncertain"].contains(metadata.outcome ?? ""),
      metadata.code == nil || Self.safeCode(metadata.code) != nil,
      status == 0 || bytes == nil else {
      pending.reply = .failure(.init(code: "ERR_PHONE_CORE_PROTOCOL", mayHaveActed: pending.mutating))
      run.pending = nil; stop(run); return
    }
    if metadata.kind == "apps", (bytes?.count ?? 0) > 1024 * 1024 {
      pending.reply = .failure(.init(code: "ERR_PHONE_CORE_PROTOCOL")); run.pending = nil; stop(run); return
    }
    pending.reply = .success(IOSPhoneCoreReply(status: status, metadata: metadata, bytes: bytes))
    run.pending = nil
  }

  private func setState(_ value: [String: Any]) { state = value; onStateChanged?() }
  private static func safeCode(_ value: String?) -> String? {
    guard let value, !value.isEmpty, value.utf8.count <= 96,
      value.utf8.allSatisfy({ (65...90).contains($0) || (48...57).contains($0) || $0 == 95 }) else { return nil }
    return value
  }
  private static func acceptanceCode(_ status: Int32) -> String {
    switch status {
    case 1, 7: return "ERR_PHONE_ARGUMENTS"
    case 2: return "ERR_PHONE_BUSY"
    case 3: return "ERR_PHONE_STALE_REQUEST"
    case 4: return "ERR_PHONE_CORE_NOT_READY"
    case 5: return "ERR_PHONE_STOPPING"
    case 6: return "ERR_PHONE_STOP_UNCONFIRMED"
    default: return "ERR_PHONE_NATIVE_UNAVAILABLE"
    }
  }

  static func deliverEvent(handle: UInt64, runID: String, kind: Int32, text: String) {
    eventCallbacks[runID]?(handle, runID, kind, text)
  }
  static func deliverResult(handle: UInt64, requestID: UInt64, status: Int32, text: String, bytes: Data?) {
    let key = "\(handle):\(requestID)"
    let callback = resultCallbacks.removeValue(forKey: key)
    callback?(handle, requestID, status, text, bytes)
  }

  private static func makeNativeClient() -> NativeClient? {
    #if DSH_PHONE_SELF_RUNNER
    guard let identity = phoneCoreString(dsh_phone_core_build_identity(), limit: 128),
      identity == "dsh-phone-core:1;idevice=3854a5df4a5a6dee71ffce4d8befc2ea356a8065" else { return nil }
    return NativeClient(start: { runID, data, pairing, callback in
      eventCallbacks[runID] = callback
      var handle: UInt64 = 0
      let status = data.withUnsafeBytes { raw in
        pairing.withUnsafeBytes { record in
          dsh_phone_core_start_bytes(raw.bindMemory(to: UInt8.self).baseAddress, raw.count,
            record.bindMemory(to: UInt8.self).baseAddress, record.count, phoneCoreEventCallback, &handle)
        }
      }
      if status != 0 { eventCallbacks.removeValue(forKey: runID) }
      return (status, handle)
    }, request: { handle, requestID, data, callback in
      let key = "\(handle):\(requestID)"
      resultCallbacks[key] = callback
      let status = data.withUnsafeBytes { raw in
        dsh_phone_core_request(handle, requestID, raw.bindMemory(to: UInt8.self).baseAddress, raw.count, phoneCoreResultCallback)
      }
      if status != 0 { resultCallbacks.removeValue(forKey: key) }
      return status
    }, cancel: { dsh_phone_core_cancel($0, $1) }, stop: { dsh_phone_core_stop($0) })
    #else
    return nil
    #endif
  }
}
