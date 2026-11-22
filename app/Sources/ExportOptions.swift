// PhotoEmul - native editor for spektrafilm (GPL-3.0-or-later)
// Export preferences (Settings › Export): JPEG quality, output folder and file name rule.

import AppKit
import Foundation

enum ExportOptions {
  static let qualityKey = "exportJpegQuality"
  static let folderKey = "exportFolder"
  static let nameKey = "exportNameRule"
  static let keys = [qualityKey, folderKey, nameKey]
  static let defaultQuality = 92
  static let defaultName = "{name}-photoemul"
  /// Default rules of earlier versions (engine name before 0.1.51, Emulsa until 0.1.121); a rule
  /// left at one of them follows the new default.
  static let legacyDefaultNames = ["{name}-spektrafilm", "{name}-emulsa"]
  static let tokens = ["{name}", "{film}", "{paper}", "{date}"]

  /// 0...1 for the JPEG encoder.
  static var jpegQuality: Double {
    let q = UserDefaults.standard.object(forKey: qualityKey) as? Int ?? defaultQuality
    return Double(min(max(q, 10), 100)) / 100
  }

  /// Fixed output folder, or nil for "next to the photo" (also when the folder is gone).
  static var folder: URL? {
    guard let path = UserDefaults.standard.string(forKey: folderKey), !path.isEmpty else { return nil }
    var isDir: ObjCBool = false
    guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
    return URL(fileURLWithPath: path, isDirectory: true)
  }

  static func directory(for source: URL) -> URL { folder ?? source.deletingLastPathComponent() }

  /// File name without extension from the rule: {name} photo name, {film}, {paper}, {date} (yyyy-MM-dd).
  static func stem(for source: URL, values: [String: ParamValue], rule: String? = nil) -> String {
    var rule = rule ?? UserDefaults.standard.string(forKey: nameKey) ?? defaultName
    if rule.trimmingCharacters(in: .whitespaces).isEmpty { rule = defaultName }
    let film = Catalog.films[safe: values["film"]?.intValue ?? -1].map(FilmInfo.displayName) ?? ""
    let paper = Catalog.papers[safe: values["paper"]?.intValue ?? -1].map(FilmInfo.displayName) ?? ""
    let date = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f.string(from: Date()) }()
    var out = rule
    for (token, value) in [("{name}", source.deletingPathExtension().lastPathComponent), ("{film}", film),
                           ("{paper}", paper), ("{date}", date)] {
      out = out.replacingOccurrences(of: token, with: value)
    }
    out = out.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
      .trimmingCharacters(in: .whitespaces)
    return out.isEmpty || out.hasPrefix(".") ? source.deletingPathExtension().lastPathComponent + out : out
  }

  /// `stem.ext` in `dir`, numbered "-2", "-3"… when taken.
  static func uniqueOutput(in dir: URL, stem: String, ext: String) -> URL {
    var candidate = dir.appendingPathComponent("\(stem).\(ext)")
    var n = 2
    while FileManager.default.fileExists(atPath: candidate.path) {
      candidate = dir.appendingPathComponent("\(stem)-\(n).\(ext)")
      n += 1
    }
    return candidate
  }
}
