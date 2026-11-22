import Foundation

/// How long and how much the disk caches keep (Settings › Cache). Thumbnails live in
/// ~/Library/Caches/PhotoEmul; zoomed-in detail tiles spill to a temporary folder that is
/// emptied on every edit, new photo and quit.
enum CachePolicy {
  static let daysKey = "cacheDays"
  static let limitKey = "cacheLimitMB"
  static let defaultDays = 7
  static let defaultLimitMB = 2048

  /// 0 keeps thumbnails until the size limit pushes them out.
  static let dayChoices = [1, 7, 30, 0]
  static let limitChoices = [512, 1024, 2048, 5120, 10240]

  static var days: Int { UserDefaults.standard.object(forKey: daysKey) as? Int ?? defaultDays }
  static var limitMB: Int { UserDefaults.standard.object(forKey: limitKey) as? Int ?? defaultLimitMB }
  /// Thumbnails and detail tiles each get half, so together they stay within the chosen limit.
  static var perCacheBytes: Int { limitMB * 1_048_576 / 2 }
  static var maxAge: TimeInterval? { days > 0 ? Double(days) * 86_400 : nil }

  static func dayTitle(_ d: Int) -> String {
    switch d {
    case 0: return tr("제한 없음", "No Limit")
    case 1: return tr("1일", "1 Day")
    default: return tr("\(d)일", "\(d) Days")
    }
  }

  static func sizeTitle(_ mb: Int) -> String {
    mb < 1024 ? "\(mb) MB" : "\(mb / 1024) GB"
  }

  struct Usage { var thumbnails = 0, tiles = 0, thumbnailFiles = 0 }

  /// Measures both caches; walks the folders, so call off the main queue.
  static func usage() -> Usage {
    var u = Usage()
    if let dir = ThumbCache.folder {
      let (bytes, files) = folderSize(dir)
      u.thumbnails = bytes
      u.thumbnailFiles = files
    }
    for dir in TileSpill.folders() { u.tiles += folderSize(dir).0 }
    return u
  }

  /// Removes every thumbnail and this run's spilled tiles, then reports the new usage.
  /// Photo edits, snapshots and presets stay.
  @MainActor static func clearAll(then done: @escaping (Usage) -> Void) {
    EditModel.current?.clearDiskTiles()
    DispatchQueue.global(qos: .userInitiated).async {
      ThumbCache.removeAll()
      let u = usage()
      DispatchQueue.main.async { done(u) }
    }
  }

  private static func folderSize(_ dir: URL) -> (Int, Int) {
    guard let files = try? FileManager.default.contentsOfDirectory(
      at: dir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
    else { return (0, 0) }
    var total = 0
    for url in files {
      let v = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
      total += v?.totalFileAllocatedSize ?? v?.fileSize ?? 0
    }
    return (total, files.count)
  }
}
