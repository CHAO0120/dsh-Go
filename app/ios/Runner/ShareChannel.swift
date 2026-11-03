import Flutter
import ImageIO
import UniformTypeIdentifiers

// dsh/share, after android/.../share/SharePlugin.kt: what the share extension left in
// the inbox becomes one `share` call, with its files copied into the app's cache and
// photos sized as ShareImages.kt sizes them. A share leaves the inbox only once Dart
// has answered that call: killed before then, it's delivered again next time.

final class ShareChannel {
  private static let keepSlots = 4
  private static let maxSide = 2560
  private static let quality = 0.88
  private static let abandonedAfter: TimeInterval = 24 * 60 * 60

  private let channel: FlutterMethodChannel
  private let work = DispatchQueue(label: "dsh.share")
  private var ready = false

  /// Shares on their way to Dart, by folder. Only touched on [work].
  private var delivering = Set<String>()

  init(messenger: any FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "dsh/share", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      guard call.method == "ready", let self else { return result(FlutterMethodNotImplemented) }
      self.ready = true
      self.drain()
      result(true)
    }
  }

  /// Delivers whatever is waiting, in the order it came. Until Dart is ready the
  /// shares simply stay in the inbox.
  func drain() {
    guard ready else { return }
    work.async { [weak self] in
      guard let self, let inbox = ShareInbox.folder else { return }
      for folder in Self.oldestFirst(in: inbox) {
        let name = folder.lastPathComponent
        if name.hasPrefix(ShareInbox.unfinishedPrefix) {
          Self.removeIfAbandoned(folder)
        } else if self.delivering.insert(name).inserted {
          let share = Self.read(folder)
          onMain { self.deliver(share, from: folder) }
        }
      }
    }
  }

  private func deliver(_ share: [String: Any?], from folder: URL) {
    channel.invokeMethod("share", arguments: share) { [weak self] answer in
      self?.work.async {
        self?.delivering.remove(folder.lastPathComponent)
        let refused = answer is FlutterError || (answer as? NSObject) === FlutterMethodNotImplemented
        if !refused { try? FileManager.default.removeItem(at: folder) }
      }
    }
  }

  private static func created(_ url: URL) -> Date {
    (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantPast
  }

  private static func oldestFirst(in folder: URL) -> [URL] {
    let keys: [URLResourceKey] = [.creationDateKey]
    let items = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
    return items.sorted { created($0) < created($1) }
  }

  /// The extension was killed while writing this one, and nothing will finish it.
  private static func removeIfAbandoned(_ folder: URL) {
    guard created(folder).timeIntervalSinceNow < -abandonedAfter else { return }
    try? FileManager.default.removeItem(at: folder)
  }

  private static func read(_ folder: URL) -> [String: Any?] {
    let manifestFile = folder.appendingPathComponent(ShareInbox.manifestName)
    guard let data = try? Data(contentsOf: manifestFile),
      let manifest = try? JSONDecoder().decode(ShareInbox.Manifest.self, from: data)
    else {
      return ["skipped": [["reason": "unreadable"]]]
    }
    var files: [[String: Any?]] = []
    var skipped: [[String: String?]] = manifest.skipped.map { ["name": $0.name, "reason": $0.reason] }
    let slot = manifest.files.isEmpty ? nil : newSlot()
    for file in manifest.files {
      if let slot, let copied = copy(folder.appendingPathComponent(file.name), mime: file.mime, to: slot) {
        files.append(copied)
      } else {
        skipped.append(["name": file.name, "reason": "unreadable"])
      }
    }
    return ["text": manifest.text, "subject": manifest.subject, "files": files, "skipped": skipped]
  }

  private static func newSlot() -> URL? {
    let manager = FileManager.default
    guard let caches = manager.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
    let root = caches.appendingPathComponent("share", isDirectory: true)
    prune(root)
    let slot = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
    do {
      try manager.createDirectory(at: slot, withIntermediateDirectories: true)
      return slot
    } catch {
      return nil
    }
  }

  /// The composer may still be reading the latest ones.
  private static func prune(_ root: URL) {
    oldestFirst(in: root).dropLast(keepSlots - 1).forEach { try? FileManager.default.removeItem(at: $0) }
  }

  private static func copy(_ source: URL, mime: String?, to slot: URL) -> [String: Any?]? {
    if let image = sized(source, mime: mime, in: slot) { return description(image.url, mime: image.mime) }
    let target = ShareInbox.unique(source.lastPathComponent, in: slot)
    do {
      try FileManager.default.copyItem(at: source, to: target)
      return description(target, mime: mime)
    } catch {
      return nil
    }
  }

  private static func description(_ file: URL, mime: String?) -> [String: Any?] {
    let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size]) as? Int64
    return ["path": file.path, "name": file.lastPathComponent, "mime": mime, "size": size]
  }

  /// A re-encoded copy of a photo, which also turns HEIC into JPEG, applies the
  /// rotation and leaves the metadata behind. Nil when the original goes as it is: PNG,
  /// JPEG and WebP that fit stay untouched, GIFs keep their animation, and what can't
  /// be decoded here is sent anyway.
  private static func sized(_ source: URL, mime: String?, in slot: URL) -> (url: URL, mime: String)? {
    guard let mime, mime.hasPrefix("image/"), mime != "image/gif", !mime.hasPrefix("image/svg"),
      let image = CGImageSourceCreateWithURL(source as CFURL, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    let long = max(width, height)
    if long <= maxSide, ["image/png", "image/jpeg", "image/webp"].contains(mime) { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: min(long, maxSide),
    ]
    guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(image, 0, options as CFDictionary) else { return nil }
    let opaque: [CGImageAlphaInfo] = [.none, .noneSkipFirst, .noneSkipLast]
    let keepsAlpha = !opaque.contains(thumbnail.alphaInfo)
    let type = keepsAlpha ? UTType.png : UTType.jpeg
    let stem = source.deletingPathExtension().lastPathComponent
    let target = ShareInbox.unique("\(stem).\(keepsAlpha ? "png" : "jpg")", in: slot)
    guard let output = CGImageDestinationCreateWithURL(target as CFURL, type.identifier as CFString, 1, nil) else {
      return nil
    }
    let written: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
    CGImageDestinationAddImage(output, thumbnail, written as CFDictionary)
    guard CGImageDestinationFinalize(output) else { return nil }
    return (target, keepsAlpha ? "image/png" : "image/jpeg")
  }
}
