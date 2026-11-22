// PhotoEmul - native editor for spektrafilm (GPL-3.0-or-later)
// Per-photo edit sessions (values + snapshots) so reopening a photo resumes the edit,
// and the batch list the Lightroom plugin hands over for multi-photo edits.

import CryptoKit
import Foundation

struct EditSnapshot: Codable, Identifiable, Hashable {
  var id = UUID()
  var name: String
  var date: Date
  var values: [String: ParamValue]
}

struct EditSession: Codable {
  var values: [String: ParamValue]
  var snapshots: [EditSnapshot]
  var updated: Date
  /// Undo/redo history (Settings › 일반 › 히스토리 저장); missing in older files and when off.
  var history: StoredHistory?
}

/// History saved as differences from the session's `values`, so 200 steps stay small.
struct StoredHistory: Codable {
  struct Entry: Codable {
    var label: String
    var changed: [String: ParamValue]
    var removed: [String]?
    var group: StepGroup?
    /// Missing in older files: the user's step.
    var source: String?
    var note: String?
  }
  var undo: [Entry]
  var redo: [Entry]

  static let enabledKey = "saveHistory"
  static var enabled: Bool { UserDefaults.standard.object(forKey: enabledKey) as? Bool ?? true }
  static let limit = 200

  init(undo: [HistoryEntry], redo: [HistoryEntry], base: [String: ParamValue]) {
    func entry(_ e: HistoryEntry) -> Entry {
      let changed = e.values.filter { base[$0.key] != $0.value }
      let removed = base.keys.filter { e.values[$0] == nil }
      return Entry(label: e.label, changed: changed, removed: removed.isEmpty ? nil : removed.sorted(), group: e.group,
                   source: e.source, note: e.note)
    }
    // Keep the steps nearest the marker: the end of each stack.
    let keepUndo = min(undo.count, Self.limit)
    let keepRedo = min(redo.count, Self.limit - keepUndo)
    self.undo = undo.suffix(keepUndo).map(entry)
    self.redo = redo.suffix(keepRedo).map(entry)
  }

  func stacks(base: [String: ParamValue]) -> (undo: [HistoryEntry], redo: [HistoryEntry]) {
    func entry(_ e: Entry) -> HistoryEntry {
      var v = base
      for k in e.removed ?? [] { v[k] = nil }
      v.merge(e.changed) { $1 }
      return HistoryEntry(label: e.label, values: Presets.sanitized(v), group: e.group, source: e.source, note: e.note)
    }
    return (undo.map(entry), redo.map(entry))
  }
}

enum Sessions {
  private static var directory: URL {
    let dir = Presets.directory.appendingPathComponent("Sessions", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  /// Sessions are keyed by the Lightroom photo path (or the input path when run alone).
  static func url(for key: String) -> URL {
    let digest = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
    return directory.appendingPathComponent("\(digest.prefix(32)).json")
  }

  static func load(_ key: String) -> EditSession? {
    guard let data = try? Data(contentsOf: url(for: key)),
          var session = try? JSONDecoder.iso.decode(EditSession.self, from: data)
    else { return nil }
    session.values = Presets.sanitized(session.values)
    session.snapshots = session.snapshots.map { var s = $0; s.values = Presets.sanitized(s.values); return s }
    return session
  }

  /// A batch edit replaces a photo's values: keep its snapshots, and its history with the batch as a new step.
  static func replaceValues(_ values: [String: ParamValue], key: String, label: String) {
    let old = load(key)
    var history: StoredHistory?
    if let old, StoredHistory.enabled, old.values != values {
      let undo = old.history?.stacks(base: old.values).undo ?? []
      history = StoredHistory(undo: undo + [HistoryEntry(label: label, values: old.values)], redo: [], base: values)
    }
    save(EditSession(values: values, snapshots: old?.snapshots ?? [], updated: Date(),
                     history: StoredHistory.enabled ? history ?? old?.history : nil), key: key)
  }

  static func save(_ session: EditSession, key: String) {
    let enc = JSONEncoder.iso
    enc.outputFormatting = [.prettyPrinted, .sortedKeys]
    if let data = try? enc.encode(session) { try? data.write(to: url(for: key), options: .atomic) }
  }
}

extension JSONDecoder {
  static var iso: JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
}

extension JSONEncoder {
  static var iso: JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; return e }
}

/// One photo of a multi-photo edit: render `input` to `output`, remember the edit under `key`.
struct BatchItem: Hashable {
  let input: URL
  let output: URL
  let key: String

  /// Tab-separated lines: input, output, optional session key.
  static func readList(_ url: URL) -> [BatchItem] {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
    return text.split(whereSeparator: \.isNewline).compactMap { line in
      let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
      guard f.count >= 2, !f[0].isEmpty, !f[1].isEmpty else { return nil }
      let key = f.count > 2 && !f[2].isEmpty ? f[2] : f[0]
      return BatchItem(input: URL(fileURLWithPath: f[0]), output: URL(fileURLWithPath: f[1]), key: key)
    }
  }
}
