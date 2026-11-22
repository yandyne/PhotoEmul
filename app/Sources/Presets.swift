// PhotoEmul - native editor for spektrafilm (GPL-3.0-or-later)
// User presets and the last-used settings, stored as JSON in Application Support.

import Foundation

struct Preset: Identifiable, Hashable {
  let name: String
  let url: URL
  var id: URL { url }
}

enum Presets {
  static var directory: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    let dir = base.appendingPathComponent("PhotoEmul", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir.appendingPathComponent("Presets"), withIntermediateDirectories: true)
    return dir
  }

  private static var lastURL: URL { directory.appendingPathComponent("last.json") }

  static func loadLast() -> [String: ParamValue]? { read(lastURL) }
  static func saveLast(_ values: [String: ParamValue]) { write(values, to: lastURL) }

  static func list() -> [Preset] {
    let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.pathExtension == "json" }
      .map { Preset(name: $0.deletingPathExtension().lastPathComponent, url: $0) }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
  }

  /// Overwrites a preset of the same name; pass `uniqueName(_:)` when that is not wanted.
  static func save(_ values: [String: ParamValue], name: String) {
    write(values, to: fileURL(name))
  }

  /// `base`, or `base 2`, `base 3`… so a new preset never replaces an existing file.
  static func uniqueName(_ base: String) -> String {
    var name = base, n = 2
    while FileManager.default.fileExists(atPath: fileURL(name).path) { name = "\(base) \(n)"; n += 1 }
    return name
  }

  private static var folder: URL { directory.appendingPathComponent("Presets", isDirectory: true) }

  private static func fileURL(_ name: String) -> URL {
    folder.appendingPathComponent("\(name.replacingOccurrences(of: "/", with: "-")).json")
  }

  static func delete(_ preset: Preset) { try? FileManager.default.removeItem(at: preset.url) }

  /// Values for a preset, layered on the app defaults so older files stay valid.
  static func load(_ preset: Preset) -> [String: ParamValue]? {
    guard let stored = read(preset.url) else { return nil }
    return EditModel.appDefaults().merging(stored) { _, new in new }
  }

  private static func read(_ url: URL) -> [String: ParamValue]? {
    guard let data = try? Data(contentsOf: url),
          let stored = try? JSONDecoder().decode([String: ParamValue].self, from: data)
    else { return nil }
    return sanitized(stored)
  }

  /// Stored values layered on the app defaults, keeping only names the engine still knows.
  static func sanitized(_ stored: [String: ParamValue]) -> [String: ParamValue] {
    EditModel.appDefaults().merging(migrated(stored).filter { Catalog.byName[$0.key] != nil }) { _, new in new }
  }

  /// Renamed or re-scaled parameters from older builds, mapped before unknown names are dropped.
  static func migrated(_ stored: [String: ParamValue]) -> [String: ParamValue] {
    var v = stored
    if v["paperGradeHalf"] == nil, let old = v["paperGrade"]?.intValue {
      v["paperGradeHalf"] = .int(Darkroom.legacyGradeMap[min(max(old, 0), Darkroom.legacyGradeMap.count - 1)])
    }
    if v["devDeveloper"] == nil, let old = v["adjacencyDeveloper"]?.intValue {
      let (developer, dilution) = Developer.legacyAdjacency[min(max(old, 0), Developer.legacyAdjacency.count - 1)]
      v["devDeveloper"] = .int(developer)
      v["devDilution"] = .int(dilution)
    }
    // The hidden 0.1.88 toggle never did anything; it now turns on the bromide drag module.
    if v["bromideDragEnabled"] == nil, v["devBromideDrag"]?.boolValue == true {
      v["bromideDragEnabled"] = .bool(true)
    }
    return v
  }

  static func named(_ name: String) -> Preset? { list().first { $0.name == name } }

  /// False when the move failed, e.g. another preset already has that name.
  static func rename(_ preset: Preset, to name: String) -> Bool {
    let dest = fileURL(name)
    if dest.standardizedFileURL == preset.url.standardizedFileURL { return true }
    return (try? FileManager.default.moveItem(at: preset.url, to: dest)) != nil
  }

  /// Copies a preset file (exported from another machine) into the preset folder.
  @discardableResult
  static func importFile(_ url: URL) -> Bool {
    guard read(url) != nil else { return false }
    // A file already in the preset folder is imported as is; copying it would only duplicate it.
    if url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL { return true }
    let dest = fileURL(uniqueName(url.deletingPathExtension().lastPathComponent))
    return (try? FileManager.default.copyItem(at: url, to: dest)) != nil
  }

  private static func write(_ values: [String: ParamValue], to url: URL) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? enc.encode(values) { try? data.write(to: url, options: .atomic) }
  }
}
