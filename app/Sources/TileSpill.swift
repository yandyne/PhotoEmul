import Foundation

/// Detail tiles pushed out of memory are kept on disk until the next edit or photo, so going
/// back to a part of the photo seen before reads it back instead of rendering it again.
final class TileSpill: @unchecked Sendable {
  struct Key: Hashable {
    let x, y, w, h: Int
    let scale: Double
    init(_ region: CGRect, scale: Double) {
      x = Int(region.minX.rounded()); y = Int(region.minY.rounded())
      w = Int(region.width.rounded()); h = Int(region.height.rounded())
      self.scale = scale
    }
  }
  private struct Entry { let url: URL; let width, height, bytesPerComponent, bytes: Int; var used: Int }

  private let lock = NSLock()
  private let queue = DispatchQueue(label: "photoemul.spill", qos: .utility)
  private let dir: URL
  private var entries: [Key: Entry] = [:]
  private var total = 0
  private var clock = 0
  private var count = 0
  /// Disk kept at most (Settings › Cache); the least recently used tiles go first.
  private var budget: Int { CachePolicy.perCacheBytes }

  init() {
    let base = FileManager.default.temporaryDirectory
    // Leftovers of earlier runs that quit without cleaning up; other running copies keep theirs.
    if let old = try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil) {
      for url in old where url.lastPathComponent.hasPrefix("PhotoEmul-tiles-") {
        if let pid = Int32(url.lastPathComponent.dropFirst("PhotoEmul-tiles-".count)), kill(pid, 0) == 0 { continue }
        try? FileManager.default.removeItem(at: url)
      }
    }
    dir = base.appendingPathComponent("PhotoEmul-tiles-\(ProcessInfo.processInfo.processIdentifier)")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }

  deinit { removeAll() }

  /// Spill folders of every running copy, for the usage shown in Settings.
  static func folders() -> [URL] {
    let base = FileManager.default.temporaryDirectory
    let all = (try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []
    return all.filter { $0.lastPathComponent.hasPrefix("PhotoEmul-tiles-") }
  }

  /// Deletes the folder; also called when the app quits.
  func removeAll() {
    lock.lock(); entries = [:]; total = 0; lock.unlock()
    queue.sync { try? FileManager.default.removeItem(at: dir) }
  }

  func contains(_ key: Key) -> Bool {
    lock.lock(); defer { lock.unlock() }
    return entries[key] != nil
  }

  /// Writes the tile in the background; the buffer is kept alive until it is on disk.
  func store(_ buffer: PixelBuffer, key: Key) {
    lock.lock()
    count += 1
    clock += 1
    let bytes = buffer.width * buffer.height * 4 * buffer.bytesPerComponent
    let entry = Entry(
      url: dir.appendingPathComponent("\(count).tile"), width: buffer.width, height: buffer.height,
      bytesPerComponent: buffer.bytesPerComponent, bytes: bytes, used: clock)
    if let old = entries.updateValue(entry, forKey: key) { total -= old.bytes; remove(old.url) }
    total += bytes
    var evicted: [URL] = []
    while total > budget, let (k, e) = entries.min(by: { $0.value.used < $1.value.used }) {
      entries[k] = nil
      total -= e.bytes
      evicted.append(e.url)
    }
    lock.unlock()
    queue.async {
      FileManager.default.createFile(
        atPath: entry.url.path, contents: Data(bytesNoCopy: buffer.data, count: bytes, deallocator: .none))
      _ = buffer
    }
    evicted.forEach(remove)
  }

  /// Reads a stored tile back, or nil if there is none or it could not be read. Call off the main queue.
  func load(_ key: Key) -> PixelBuffer? {
    lock.lock()
    clock += 1
    entries[key]?.used = clock
    let entry = entries[key]
    lock.unlock()
    guard let entry else { return nil }
    // Behind any write of it still queued.
    return queue.sync {
      guard let file = fopen(entry.url.path, "rb") else { return nil }
      defer { fclose(file) }
      let buffer = PixelBuffer(width: entry.width, height: entry.height, bytesPerComponent: entry.bytesPerComponent)
      return fread(buffer.data, 1, entry.bytes, file) == entry.bytes ? buffer : nil
    }
  }

  /// Forgets every tile: the look or the photo changed.
  func clear() {
    lock.lock()
    let urls = entries.values.map(\.url)
    entries = [:]
    total = 0
    lock.unlock()
    urls.forEach(remove)
  }

  private func remove(_ url: URL) { queue.async { try? FileManager.default.removeItem(at: url) } }
}
