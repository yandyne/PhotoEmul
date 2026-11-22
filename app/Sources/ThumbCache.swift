import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Film and paper browser thumbnails kept on disk, so reopening a photo (or going back to a look
/// tried before) shows them without rendering again. Keyed by the photo file, the look, and the
/// app build.
enum ThumbCache {
  private static let directory: URL? = {
    guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
    let dir = caches.appendingPathComponent("PhotoEmul/Thumbnails", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }()

  static var folder: URL? { directory }

  /// Changes whenever the app is rebuilt, since the engine may render differently.
  private static let build: String = {
    let exe = Bundle.main.executableURL.flatMap { try? FileManager.default.attributesOfItem(atPath: $0.path) }
    let date = (exe?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    return "\(Bundle.main.infoDictionary?["CFBundleVersion"] ?? "")-\(date)"
  }()

  /// Key for the photo at `url` rendered with `values`; nil when the file cannot be read.
  static func key(for url: URL, values: [String: ParamValue], edge: Int) -> String? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path) else { return nil }
    let date = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
    let size = attrs[.size] as? Int ?? 0
    var text = "\(build)|\(url.path)|\(date)|\(size)|\(edge)"
    for (k, v) in values.sorted(by: { $0.key < $1.key }) { text += "|\(k)=\(v)" }
    return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  private static func file(_ key: String, kind: Int, index: Int) -> URL? {
    directory?.appendingPathComponent("\(key)-\(kind)-\(index).png")
  }

  static func load(_ key: String, kind: Int, index: Int) -> CGImage? {
    guard let url = file(key, kind: kind, index: index),
          let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, nil)
    else { return nil }
    // Read counts as use: the size limit drops what has gone unused longest.
    try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    return image
  }

  static func store(_ image: CGImage, key: String, kind: Int, index: Int) {
    guard let url = file(key, kind: kind, index: index),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return }
    CGImageDestinationAddImage(dest, image, nil)
    CGImageDestinationFinalize(dest)
  }

  /// Drops thumbnails older than the retention period, then the least recently used ones over
  /// the size limit (Settings › Cache). Runs at launch and after each batch of renders.
  static func trim() {
    guard let dir = directory,
          let files = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey])
    else { return }
    let items = files.compactMap { url -> (URL, Date, Int)? in
      guard let v = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey]) else { return nil }
      return (url, v.contentModificationDate ?? .distantPast, v.fileSize ?? 0)
    }.sorted { $0.1 > $1.1 }
    let oldest = CachePolicy.maxAge.map { Date().addingTimeInterval(-$0) } ?? .distantPast
    let budget = CachePolicy.perCacheBytes
    var total = 0
    for (url, date, size) in items {
      total += size
      if total > budget || date < oldest { try? FileManager.default.removeItem(at: url) }
    }
  }

  static func removeAll() {
    guard let dir = directory,
          let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
    else { return }
    for url in files { try? FileManager.default.removeItem(at: url) }
  }
}

/// When the last edit happened, readable from the render queues.
final class EditClock: @unchecked Sendable {
  private let lock = NSLock()
  private var last: CFAbsoluteTime = 0
  func touch() { lock.lock(); last = CFAbsoluteTimeGetCurrent(); lock.unlock() }
  var idle: Double { lock.lock(); defer { lock.unlock() }; return CFAbsoluteTimeGetCurrent() - last }
}
