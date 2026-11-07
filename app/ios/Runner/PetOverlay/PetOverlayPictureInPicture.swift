import AVFoundation
import AVKit
import CoreMedia
import CoreVideo
import UIKit

final class PetOverlayVideoView: UIView {
  override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
  var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
}

/// Public AVKit sample-buffer PiP only. There is no private controlsStyle,
/// transparent/offscreen player, silent-audio loop, or location keepalive.
@MainActor
final class PetOverlayPictureInPicture: NSObject,
  AVPictureInPictureControllerDelegate, AVPictureInPictureSampleBufferPlaybackDelegate {
  let sourceView = PetOverlayVideoView()
  var onChange: (() -> Void)?
  var onRecoveryPossible: (() -> Void)?
  var onFailure: ((String) -> Void)?
  var onUnexpectedStop: (() -> Void)?
  var onSetPlaying: ((Bool) -> Bool)?
  var onRestore: ((@escaping (Bool) -> Void) -> Void)?
  var onRenderSize: ((CGSize) -> Void)?

  private var picture: AVPictureInPictureController?
  private var observations: [NSKeyValueObservation] = []
  private var notifications: [NSObjectProtocol] = []
  private var previousAudio: (AVAudioSession.Category, AVAudioSession.Mode, AVAudioSession.CategoryOptions)?
  private var ownsAudio = false
  private var audioActivated = false
  private var audioRecovery = PetOverlayAudioRecoveryState()
  private var lastAudioMayPrepare = true
  private var requested = false
  private var expectedStop = false
  private var restoring = false
  private var starting = false
  private var playbackPaused = false
  private var timebase: CMTimebase?

  var supported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }
  var possible: Bool { picture?.isPictureInPicturePossible == true }
  var active: Bool { picture?.isPictureInPictureActive == true }
  var suspended: Bool { picture?.isPictureInPictureSuspended == true }
  // AVAudioSession has no public synchronous "is active now" query. This
  // records our successful activation and an unchanged owned configuration.
  var audioConfigured: Bool { ownsAudio && audioActivated && audioRecovery.blocker == nil && audioMatches() }
  // Eligibility for a new attempt, not an observation that the OS session is
  // active. A demanded preparation still has to succeed in setActive(true).
  var audioMayPrepare: Bool { audioPreparationBlocker == nil }
  var audioPreparationBlocker: String? {
    if let blocker = audioRecovery.blocker { return blocker }
    let audio = AVAudioSession.sharedInstance()
    if audio.category == .record || audio.category == .playAndRecord ||
      (audio.category == .playback && audio.mode == .spokenAudio) { return "overlay_audio_busy" }
    return nil
  }
  var keepingAlive: Bool { requested && active && !suspended && audioConfigured }
  var inlineVisible: Bool {
    guard let window = sourceView.window, !window.isHidden,
      sourceView.bounds.width >= 80, sourceView.bounds.height >= 50,
      sourceView.convert(sourceView.bounds, to: window).intersects(window.bounds) else { return false }
    var current: UIView? = sourceView
    while let view = current {
      if view.isHidden || view.alpha < 0.99 { return false }
      current = view.superview
    }
    return true
  }

  override init() {
    super.init()
    lastAudioMayPrepare = audioMayPrepare
    sourceView.isUserInteractionEnabled = false
    sourceView.accessibilityElementsHidden = true
    sourceView.backgroundColor = .black
    sourceView.clipsToBounds = true
    sourceView.layer.cornerRadius = 10
    sourceView.displayLayer.videoGravity = .resizeAspect
    var base: CMTimebase?
    if CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault,
      sourceClock: CMClockGetHostTimeClock(), timebaseOut: &base) == noErr, let base {
      timebase = base
      CMTimebaseSetTime(base, time: CMClockGetTime(CMClockGetHostTimeClock()))
      CMTimebaseSetRate(base, rate: 1)
      sourceView.displayLayer.controlTimebase = base
    }
    guard supported else { return }
    let source = AVPictureInPictureController.ContentSource(
      sampleBufferDisplayLayer: sourceView.displayLayer, playbackDelegate: self)
    let controller = AVPictureInPictureController(contentSource: source)
    controller.delegate = self
    controller.requiresLinearPlayback = true
    controller.canStartPictureInPictureAutomaticallyFromInline = false
    picture = controller
    observations = [
      controller.observe(\.isPictureInPicturePossible, options: [.new]) { [weak self] _, _ in
        DispatchQueue.main.async { self?.onChange?() }
      },
      controller.observe(\.isPictureInPictureSuspended, options: [.new]) { [weak self] _, _ in
        DispatchQueue.main.async { self?.onChange?() }
      },
    ]
    let center = NotificationCenter.default
    notifications.append(center.addObserver(forName: AVAudioSession.interruptionNotification,
      object: nil, queue: .main) { [weak self] note in
      guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
        let kind = AVAudioSession.InterruptionType(rawValue: raw) else { return }
      Task { @MainActor in
        guard let self else { return }
        switch kind {
        case .began:
          self.audioRecovery.interrupted = true
          self.audioActivated = false
          self.lastAudioMayPrepare = false
          if self.ownsAudio || self.requested || self.active { self.fail("overlay_audio_interrupted") }
          else { self.onChange?() }
        case .ended:
          self.audioRecovery.interrupted = false
          self.lastAudioMayPrepare = self.audioMayPrepare
          if self.audioMayPrepare { self.onRecoveryPossible?() }
          else { self.onChange?() }
        @unknown default: break
        }
      }
    })
    notifications.append(center.addObserver(forName: AVAudioSession.routeChangeNotification,
      object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        let mayPrepare = self.audioMayPrepare
        let recovered = mayPrepare && !self.lastAudioMayPrepare
        self.lastAudioMayPrepare = mayPrepare
        if self.ownsAudio, !self.audioMatches() {
          // Voice/Media has taken over. Never restore over its newer configuration.
          self.fail("overlay_audio_replaced")
        }
        // Only a blocked -> eligible change triggers a retry. Our own category
        // notifications, or an unrelated route change, cannot spin failed setup.
        if recovered { self.onRecoveryPossible?() }
        else { self.onChange?() }
      }
    })
    notifications.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification,
      object: nil, queue: .main) { [weak self] _ in
      Task { @MainActor in
        guard let self else { return }
        self.audioRecovery.mediaServicesReset()
        self.audioActivated = false
        self.lastAudioMayPrepare = false
        if self.ownsAudio || self.requested || self.active { self.fail("overlay_media_reset") }
        else { self.onChange?() }
      }
    })
  }

  /// Apple does not guarantee a matching interruption-ended notification.
  /// Foreground return permits a new interruption recovery attempt; a media
  /// reset still needs retryFromUser. Category guards/setActive remain decisive.
  func retryAfterForeground() {
    guard UIApplication.shared.applicationState == .active,
      UIApplication.shared.isProtectedDataAvailable else { return }
    audioRecovery.retry(userInitiated: false)
    lastAudioMayPrepare = audioMayPrepare
  }

  /// Only native enable/resume confirmation or the foreground Recover button
  /// calls this. Returning to the app is not a user request to reactivate audio.
  func retryFromUser() {
    guard UIApplication.shared.applicationState == .active,
      UIApplication.shared.isProtectedDataAvailable else { return }
    audioRecovery.retry(userInitiated: true)
    lastAudioMayPrepare = audioMayPrepare
  }

  func prepareInline() throws {
    guard supported, picture != nil, timebase != nil else {
      throw PetOverlayPackFailure("overlay_unsupported")
    }
    guard inlineVisible else {
      throw PetOverlayPackFailure("overlay_source_missing")
    }
    // A recovery event may arrive before the old controller finishes stopping.
    // Its didStop callback retries preparation after releasing that old lease.
    guard !(expectedStop && (active || starting)) else { return }
    try acquireAudio()
    requested = true
    picture?.canStartPictureInPictureAutomaticallyFromInline = true
  }

  /// Called after an explicit foreground PiP button, never from a model/tool.
  /// The normal phone path uses automatic PiP from its genuinely visible source.
  func startFromUser() -> Bool {
    guard UIApplication.shared.applicationState == .active, requested, possible else { return false }
    picture?.startPictureInPicture()
    return true
  }

  func setPaused(_ paused: Bool) {
    playbackPaused = paused
    picture?.invalidatePlaybackState()
  }

  func stop(keepInline: Bool = false) {
    requested = keepInline
    picture?.canStartPictureInPictureAutomaticallyFromInline = keepInline
    expectedStop = true
    if active || starting {
      picture?.stopPictureInPicture()
    } else if !keepInline {
      releaseAudio()
      sourceView.displayLayer.flushAndRemoveImage()
    }
    onChange?()
  }

  /// Returns false for ordinary display-layer backpressure, keeping the last
  /// picture. Failure to allocate/describe a frame is a reported hard failure.
  func enqueue(_ image: CGImage) throws -> Bool {
    let layer = sourceView.displayLayer
    if layer.status == .failed { layer.flushAndRemoveImage() }
    guard layer.isReadyForMoreMediaData else { return false }
    layer.enqueue(try Self.sampleBuffer(from: image))
    return true
  }

  /// Shared by playback and the Apple-SDK capture fixture so that the real
  /// BGRA sample-buffer path, including row orientation, is testable.
  static func sampleBuffer(from image: CGImage) throws -> CMSampleBuffer {
    var optionalBuffer: CVPixelBuffer?
    let attributes: [CFString: Any] = [
      kCVPixelBufferCGImageCompatibilityKey: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey: true,
      kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
    ]
    guard CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height,
      kCVPixelFormatType_32BGRA, attributes as CFDictionary, &optionalBuffer) == kCVReturnSuccess,
      let buffer = optionalBuffer else { throw PetOverlayPackFailure("overlay_buffer_failed") }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer),
      width: image.width, height: image.height, bitsPerComponent: 8,
      bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
      bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
      else { throw PetOverlayPackFailure("overlay_buffer_failed") }
    context.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(image.width), height: CGFloat(image.height)))
    var format: CMVideoFormatDescription?
    guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
      imageBuffer: buffer, formatDescriptionOut: &format) == noErr, let format else {
      throw PetOverlayPackFailure("overlay_buffer_failed")
    }
    var timing = CMSampleTimingInfo(duration: .invalid,
      presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()), decodeTimeStamp: .invalid)
    var optionalSample: CMSampleBuffer?
    guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
      imageBuffer: buffer, formatDescription: format, sampleTiming: &timing,
      sampleBufferOut: &optionalSample) == noErr, let sample = optionalSample else {
      throw PetOverlayPackFailure("overlay_buffer_failed")
    }
    if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
      let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
      CFDictionarySetValue(dictionary,
        Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }
    return sample
  }

  private func acquireAudio() throws {
    if let blocker = audioPreparationBlocker { throw PetOverlayPackFailure(blocker) }
    let audio = AVAudioSession.sharedInstance()
    if ownsAudio {
      guard audioMatches() else { throw PetOverlayPackFailure("overlay_audio_replaced") }
      if audioActivated { return }
    }
    do {
      if !ownsAudio {
        previousAudio = (audio.category, audio.mode, audio.categoryOptions)
        try audio.setCategory(.playback, mode: .moviePlayback, options: .mixWithOthers)
        ownsAudio = true
      }
      try audio.setActive(true)
      audioActivated = true
    } catch {
      releaseAudio()
      throw PetOverlayPackFailure("overlay_audio_failed")
    }
  }

  private func audioMatches() -> Bool {
    let audio = AVAudioSession.sharedInstance()
    return audio.category == .playback && audio.mode == .moviePlayback && audio.categoryOptions == .mixWithOthers
  }

  private func releaseAudio() {
    let restore = ownsAudio && audioMatches(), prior = previousAudio
    ownsAudio = false
    audioActivated = false
    previousAudio = nil
    guard restore, let prior else { return }
    let audio = AVAudioSession.sharedInstance()
    try? audio.setActive(false, options: .notifyOthersOnDeactivation)
    try? audio.setCategory(prior.0, mode: prior.1, options: prior.2)
  }

  private func fail(_ code: String) {
    stop()
    onFailure?(code)
  }

  func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
    starting = true
    expectedStop = false
    restoring = false
    onChange?()
  }

  func pictureInPictureControllerDidStartPictureInPicture(_ controller: AVPictureInPictureController) {
    starting = false
    if !requested { stop(); return }
    onChange?()
  }

  func pictureInPictureController(_ controller: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error) {
    starting = false
    // Error descriptions may contain unrelated media/user content. Export only
    // this stable code and keep the original exception out of logs/diagnostics.
    fail("overlay_pip_start_failed")
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
    starting = false
    let stoppedAsRequested = expectedStop
    let userClosed = !expectedStop && !restoring
    expectedStop = false
    restoring = false
    if !requested || userClosed { requested = false; releaseAudio() }
    if userClosed { onUnexpectedStop?() }
    onChange?()
    if stoppedAsRequested && audioMayPrepare { onRecoveryPossible?() }
  }

  func pictureInPictureController(_ controller: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
    restoring = true
    if let onRestore { onRestore(completionHandler) } else { completionHandler(false) }
  }

  func pictureInPictureController(_ controller: AVPictureInPictureController, setPlaying playing: Bool) {
    playbackPaused = !(onSetPlaying?(playing) ?? playing)
    controller.invalidatePlaybackState()
    onChange?()
  }

  func pictureInPictureControllerTimeRangeForPlayback(_ controller: AVPictureInPictureController) -> CMTimeRange {
    CMTimeRange(start: .zero, duration: .positiveInfinity)
  }

  func pictureInPictureControllerIsPlaybackPaused(_ controller: AVPictureInPictureController) -> Bool {
    playbackPaused
  }

  func pictureInPictureController(_ controller: AVPictureInPictureController,
    didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
    guard newRenderSize.width > 0, newRenderSize.height > 0 else { return }
    onRenderSize?(CGSize(width: CGFloat(newRenderSize.width), height: CGFloat(newRenderSize.height)))
  }

  func pictureInPictureController(_ controller: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime, completion completionHandler: @escaping () -> Void) {
    // A live task has no seekable timeline; linear playback disables skipping.
    completionHandler()
  }
}
