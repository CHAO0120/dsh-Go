import AVFoundation
import Flutter
import Speech
import UIKit

// dsh/voice and its events, after android/.../voice/VoicePlugin.kt: the system's
// recognizer with partial results, and a 16 kHz PCM recorder for the engine's own
// recognizer. Everything but the audio tap runs on the main thread.

private typealias VoiceEmit = ([String: Any]) -> Void

private protocol VoiceSession: AnyObject {
  /// The `VoiceError` code for losing the microphone.
  var audioFailure: Int { get }
  func start() throws
  func finish(_ result: @escaping FlutterResult)
  func discard()
}

final class VoiceChannel: NSObject, FlutterStreamHandler {
  private let methods: FlutterMethodChannel
  private let events: FlutterEventChannel
  private var sink: FlutterEventSink?
  private var session: VoiceSession?
  private var sessionId: Int?

  init(messenger: any FlutterBinaryMessenger) {
    methods = FlutterMethodChannel(name: "dsh/voice", binaryMessenger: messenger)
    events = FlutterEventChannel(name: "dsh/voice/events", binaryMessenger: messenger)
    super.init()
    events.setStreamHandler(self)
    methods.setMethodCallHandler { [weak self] call, result in
      guard let self else { return result(FlutterMethodNotImplemented) }
      self.handle(call, result: result)
    }
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(interrupted),
      name: AVAudioSession.interruptionNotification,
      object: nil
    )
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events
    return nil
  }

  func onCancel(withArguments arguments: Any?) -> FlutterError? {
    sink = nil
    endSession()
    return nil
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = arguments(call)
    switch call.method {
    case "capabilities":
      let speech = SFSpeechRecognizer.authorizationStatus()
      let refused = speech == .denied || speech == .restricted
      result([
        "recognizer": !refused && Self.recognizer(nil)?.isAvailable == true,
        "recorder": AVAudioSession.sharedInstance().isInputAvailable,
      ])
    case "permission":
      result(AVAudioSession.sharedInstance().recordPermission == .granted ? "granted" : "denied")
    case "requestPermission": requestPermission(result)
    case "openSettings": openAppSettings(UIApplication.openSettingsURLString, result: result)
    case "startRecognizer": startRecognizer(args, result: result)
    case "startRecorder":
      let seconds = min(max(args["maxSeconds"] as? Int ?? 60, 1), 600)
      begin(args, result: result) { RecorderSession(maxSeconds: seconds, emit: $0) }
    case "stop":
      guard let session else { return result(nil) }
      session.finish(result)
    case "cancel":
      endSession()
      result(nil)
    default: result(FlutterMethodNotImplemented)
    }
  }

  /// The microphone is what's asked for; the recognizer's own question comes with
  /// it, so dictating doesn't stop for a second dialog. Refused, the recorder works
  /// without it and `capabilities` stops offering the recognizer.
  private func requestPermission(_ result: @escaping FlutterResult) {
    let audio = AVAudioSession.sharedInstance()
    switch audio.recordPermission {
    case .granted: askSpeech { result("granted") }
    case .denied: result("blocked")
    default:
      audio.requestRecordPermission { granted in
        onMain {
          if granted {
            self.askSpeech { result("granted") }
          } else {
            result("denied")
          }
        }
      }
    }
  }

  private func askSpeech(then done: @escaping () -> Void) {
    guard SFSpeechRecognizer.authorizationStatus() == .notDetermined else { return done() }
    SFSpeechRecognizer.requestAuthorization { _ in onMain(done) }
  }

  private func startRecognizer(_ args: [String: Any], result: @escaping FlutterResult) {
    guard SFSpeechRecognizer.authorizationStatus() == .authorized else {
      return result(Self.failure("permission", code: 9))
    }
    guard let recognizer = Self.recognizer(args["language"] as? String) else {
      return result(Self.failure("recognizer", code: 12))
    }
    guard recognizer.isAvailable else { return result(Self.failure("recognizer", code: 2)) }
    begin(args, result: result) { RecognizerSession(recognizer: recognizer, emit: $0) }
  }

  private func begin(
    _ args: [String: Any],
    result: @escaping FlutterResult,
    make: (@escaping VoiceEmit) -> VoiceSession
  ) {
    guard let id = args["sessionId"] as? Int else { return result(Self.failure("arguments", code: 5)) }
    endSession()
    guard AVAudioSession.sharedInstance().recordPermission == .granted else {
      return result(Self.failure("permission", code: 9))
    }
    let next = make { [weak self] event in self?.send(event, from: id) }
    do {
      try next.start()
      session = next
      sessionId = id
      result(nil)
    } catch {
      next.discard()
      result(Self.failure("audio", code: next.audioFailure))
    }
  }

  private func send(_ event: [String: Any], from id: Int) {
    guard id == sessionId else { return }
    var event = event
    event["sessionId"] = id
    sink?(event)
    if event["type"] as? String == "end" {
      session = nil
      sessionId = nil
    }
  }

  private func endSession() {
    session?.discard()
    session = nil
    sessionId = nil
  }

  /// A call or an alarm took the microphone.
  @objc private func interrupted(_ note: Notification) {
    guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      AVAudioSession.InterruptionType(rawValue: raw) == .began
    else { return }
    onMain { [weak self] in
      guard let self, let session = self.session, let id = self.sessionId else { return }
      session.discard()
      self.send(["type": "error", "code": session.audioFailure], from: id)
      self.send(["type": "end"], from: id)
    }
  }

  /// The phone's language, then the others the person reads: `en_CN` and the like
  /// have no recognizer of their own.
  private static func recognizer(_ language: String?) -> SFSpeechRecognizer? {
    if let language { return SFSpeechRecognizer(locale: Locale(identifier: language)) }
    return SFSpeechRecognizer()
      ?? Locale.preferredLanguages.lazy.compactMap { SFSpeechRecognizer(locale: Locale(identifier: $0)) }.first
  }

  private static func failure(_ code: String, code voiceCode: Int) -> FlutterError {
    FlutterError(code: code, message: nil, details: ["code": voiceCode])
  }
}

// MARK: - The system's recognizer

private final class RecognizerSession: VoiceSession {
  let audioFailure = 3

  private let recognizer: SFSpeechRecognizer
  private let emit: VoiceEmit
  private let microphone = Microphone()
  private let request = SFSpeechAudioBufferRecognitionRequest()
  private var task: SFSpeechRecognitionTask?
  private var over = false

  init(recognizer: SFSpeechRecognizer, emit: @escaping VoiceEmit) {
    self.recognizer = recognizer
    self.emit = emit
  }

  func start() throws {
    request.shouldReportPartialResults = true
    // On the phone when it can be: what's said stays here.
    request.requiresOnDeviceRecognition = recognizer.supportsOnDeviceRecognition
    try microphone.start { [request = self.request, emit = self.emit] buffer in
      request.append(buffer)
      let level = inputLevel(buffer)
      onMain { emit(["type": "level", "value": level]) }
    }
    task = recognizer.recognitionTask(with: request) { [weak self] result, error in
      onMain { self?.heard(result, error) }
    }
  }

  /// The final text arrives as an event, as it does on Android.
  func finish(_ result: @escaping FlutterResult) {
    microphone.stop()
    request.endAudio()
    result(nil)
  }

  func discard() {
    over = true
    microphone.stop()
    request.endAudio()
    task?.cancel()
    task = nil
  }

  private func heard(_ result: SFSpeechRecognitionResult?, _ error: Error?) {
    guard !over else { return }
    if let result, !result.isFinal {
      return emit(["type": "partial", "text": result.bestTranscription.formattedString])
    }
    discard()
    if let result {
      emit(["type": "final", "text": result.bestTranscription.formattedString])
    } else {
      emit(["type": "error", "code": error.map(Self.code) ?? 7])
    }
    emit(["type": "end"])
  }

  /// `kAFAssistantErrorDomain`'s codes as the `SpeechRecognizer.ERROR_*` ones Dart's
  /// messages are keyed on.
  private static func code(_ error: Error) -> Int {
    switch (error as NSError).code {
    case 1110: return 7  // No speech detected.
    case 1700: return 9  // Not authorized.
    case 203: return 2  // Retry: the service couldn't be reached.
    default: return 5
    }
  }
}

// MARK: - The recorder

private final class RecorderSession: VoiceSession {
  let audioFailure = 100

  private static let sampleRate = 16_000
  private static let bytesPerSample = 2

  private let emit: VoiceEmit
  private let maxBytes: Int
  private let microphone = Microphone()
  private var pcm = Data()
  private var over = false

  init(maxSeconds: Int, emit: @escaping VoiceEmit) {
    maxBytes = maxSeconds * Self.sampleRate * Self.bytesPerSample
    self.emit = emit
  }

  func start() throws {
    guard
      let target = AVAudioFormat(
        commonFormat: .pcmFormatInt16,
        sampleRate: Double(Self.sampleRate),
        channels: 1,
        interleaved: true
      )
    else { throw NoMicrophone() }
    var converter: AVAudioConverter?
    try microphone.start { [weak self] buffer in
      if converter == nil { converter = AVAudioConverter(from: buffer.format, to: target) }
      guard let active = converter, let chunk = Self.converted(buffer, with: active, to: target) else { return }
      let level = inputLevel(buffer)
      onMain { self?.add(chunk, level: level) }
    }
  }

  func finish(_ result: @escaping FlutterResult) {
    microphone.stop()
    // Queued behind what the tap had already sent here.
    onMain { [self] in
      over = true
      result(pcm.isEmpty ? nil : FlutterStandardTypedData(bytes: Self.wav(pcm)))
      emit(["type": "end"])
    }
  }

  func discard() {
    over = true
    microphone.stop()
    pcm = Data()
  }

  private func add(_ chunk: Data, level: Double) {
    guard !over else { return }
    emit(["type": "level", "value": level])
    guard pcm.count < maxBytes else { return }
    pcm.append(chunk.prefix(maxBytes - pcm.count))
    if pcm.count >= maxBytes { emit(["type": "limit"]) }
  }

  private static func converted(
    _ buffer: AVAudioPCMBuffer,
    with converter: AVAudioConverter,
    to target: AVAudioFormat
  ) -> Data? {
    let ratio = target.sampleRate / buffer.format.sampleRate
    let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1
    guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return nil }
    var handed = false
    var failure: NSError?
    let status = converter.convert(to: out, error: &failure) { _, state in
      if handed {
        state.pointee = .noDataNow
        return nil
      }
      handed = true
      state.pointee = .haveData
      return buffer
    }
    guard status != .error, out.frameLength > 0, let samples = out.int16ChannelData?[0] else { return nil }
    return Data(bytes: samples, count: Int(out.frameLength) * bytesPerSample)
  }

  /// 16 kHz mono PCM16, what the engine's recognizer reads.
  private static func wav(_ pcm: Data) -> Data {
    var data = Data()
    func tag(_ text: String) { data.append(contentsOf: text.utf8) }
    func put<T: FixedWidthInteger>(_ value: T) {
      withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }
    tag("RIFF")
    put(UInt32(36 + pcm.count))
    tag("WAVE")
    tag("fmt ")
    put(UInt32(16))
    put(UInt16(1))
    put(UInt16(1))
    put(UInt32(sampleRate))
    put(UInt32(sampleRate * bytesPerSample))
    put(UInt16(bytesPerSample))
    put(UInt16(bytesPerSample * 8))
    tag("data")
    put(UInt32(pcm.count))
    data.append(pcm)
    return data
  }
}

// MARK: - The microphone

private struct NoMicrophone: Error {}

/// Holds the audio session for one voice session, and gives it back as it was: left
/// on `.record`, the rest of the app's sound would stay silent.
private final class Microphone {
  private let engine = AVAudioEngine()
  private var previous: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?

  /// [tap] runs on the audio thread.
  func start(tap: @escaping (AVAudioPCMBuffer) -> Void) throws {
    let audio = AVAudioSession.sharedInstance()
    previous = (audio.category, audio.mode, audio.categoryOptions)
    try audio.setCategory(.record, mode: .measurement, options: .duckOthers)
    try audio.setActive(true, options: .notifyOthersOnDeactivation)
    let input = engine.inputNode
    let format = input.outputFormat(forBus: 0)
    // installTap raises on a format like this, with nothing to catch it.
    guard format.sampleRate > 0, format.channelCount > 0 else { throw NoMicrophone() }
    input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in tap(buffer) }
    engine.prepare()
    try engine.start()
  }

  func stop() {
    guard let previous else { return }
    self.previous = nil
    engine.inputNode.removeTap(onBus: 0)
    engine.stop()
    let audio = AVAudioSession.sharedInstance()
    try? audio.setActive(false, options: .notifyOthersOnDeactivation)
    try? audio.setCategory(previous.0, mode: previous.1, options: previous.2)
  }
}

/// 0 (silence) to 1, over the range speech covers at the phone's microphone.
private func inputLevel(_ buffer: AVAudioPCMBuffer) -> Double {
  guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return 0 }
  let count = Int(buffer.frameLength)
  var sum: Float = 0
  for index in 0..<count { sum += samples[index] * samples[index] }
  let rms = (sum / Float(count)).squareRoot()
  let decibels = 20 * log10(max(rms, 0.000_001))
  return Double(min(max((decibels + 50) / 40, 0), 1))
}
