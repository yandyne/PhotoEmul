import AppKit
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

/// One command layer for anything that drives the editor from outside (CLI `--set`,
/// `--list-params --json`, later the agent socket): JSON in, JSON out. Call on the main thread.
enum AgentCommands {
  typealias JSON = [String: Any]
  struct Failure: Error { let message: String }

  /// Set by the window so `view` can zoom.
  static weak var canvas: CanvasState?
  /// The window's editor, for queued commands.
  static weak var model: EditModel?

  static let exportFolderKey = "agentExportFolder"
  /// Only folder `export` may write into (Settings › AI later); default ~/Pictures/PhotoEmul.
  static var exportFolder: URL {
    UserDefaults.standard.string(forKey: exportFolderKey).map { URL(fileURLWithPath: $0) }
      ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Pictures/PhotoEmul")
  }

  /// `{"cmd": …, …}` → `{"ok": true, "result": …}` or `{"ok": false, "error": …}`.
  static func run(_ req: JSON, model: EditModel?) -> JSON {
    do { return ["ok": true, "result": try dispatch(req, model)] } catch let f as Failure {
      return ["ok": false, "error": f.message]
    } catch { return ["ok": false, "error": error.localizedDescription] }
  }

  private static func dispatch(_ req: JSON, _ model: EditModel?) throws -> Any {
    let cmd = req["cmd"] as? String ?? ""
    if cmd == "params" { return params() }
    if cmd == "presets" { return Presets.list().map(\.name) }
    guard let model else { throw Failure(message: "no editor window") }
    switch cmd {
    case "state": return state(model)
    case "begin":
      try AgentSession.shared.begin(model, request: req["request"] as? String ?? "", agent: req["agent"] as? String ?? "")
      return ["draft": true]
    case "finish": AgentSession.shared.finish(model); return ["applied": !AgentSession.shared.active]
    case "apply":
      // Optional "upTo": n applies only the first n steps.
      guard AgentSession.shared.active else { throw Failure(message: "no AI request running") }
      if let n = req["upTo"].flatMap(number) { AgentSession.shared.show(model, Int(n)) }
      return ["kept": AgentSession.shared.apply(model, ask: false, pick: req["upTo"] == nil ? .all : .upTo).sorted()]
    case "discard": AgentSession.shared.end(model); return ["draft": false]
    case "set": return try set(req, model)
    case "adjust": return try adjust(req, model)
    case "preset": return try preset(req, model)
    case "history": return try history(req, model)
    case "view": return try view(req, model)
    case "capture": return try capture(req, model)
    case "reference": return try reference(req)
    case "measure": return try measure(model)
    case "open": return try open(req, model)
    case "export": return try export(req, model)
    default:
      throw Failure(message: "unknown cmd \"\(cmd)\"; use params, presets, state, begin, set, preset, history, finish, apply, discard, view, capture, reference, measure, open, export")
    }
  }

  // MARK: Parameters

  static func choices(_ d: ParamDescriptor) -> [String] {
    switch d.kind {
    case .filmStock: return Catalog.films
    case .printPaper: return Catalog.papers
    default: return d.options
    }
  }

  static func params() -> [JSON] {
    Catalog.params.map { d in
      var p: JSON = ["name": d.name, "label": Labels.param(d.name), "group": d.group, "kind": "\(d.kind)",
                     "tier": Int(d.tier), "default": json(d.defaultParamValue)]
      if d.maximum > d.minimum { p["min"] = d.minimum; p["max"] = d.maximum }
      let c = choices(d)
      if !c.isEmpty { p["options"] = c }
      return p
    }
  }

  static func json(_ v: ParamValue) -> Any {
    switch v {
    case .bool(let b): return b
    case .int(let i): return i
    case .double(let x): return x
    case .vector(let a): return a
    }
  }

  private static func number(_ x: Any) -> Double? {
    if let n = x as? NSNumber { return n.doubleValue }
    if let s = x as? String { return Double(s.trimmingCharacters(in: .whitespaces)) }
    return nil
  }

  /// Checks one incoming value against its descriptor (trust boundary: nothing unchecked reaches the engine).
  /// Accepts JSON values or the strings `--set` gives; choices by index, option label or stock name.
  static func parse(_ name: String, _ raw: Any) throws -> ParamValue {
    guard let d = Catalog.byName[name] else { throw Failure(message: "unknown parameter \"\(name)\"") }
    func ranged(_ x: Double) throws -> Double {
      guard x.isFinite else { throw Failure(message: "\(name): not a number") }
      if d.maximum > d.minimum, x < d.minimum || x > d.maximum {
        throw Failure(message: "\(name): \(x) out of range \(d.minimum)…\(d.maximum)")
      }
      return x
    }
    switch d.kind {
    case .bool:
      if let n = raw as? NSNumber { return .bool(n.boolValue) }
      switch (raw as? String)?.lowercased() {
      case "true", "1", "on": return .bool(true)
      case "false", "0", "off": return .bool(false)
      default: throw Failure(message: "\(name): expected true or false")
      }
    case .double:
      guard let x = number(raw) else { throw Failure(message: "\(name): expected a number") }
      return .double(try ranged(x))
    case .double2, .double3:
      let n = d.kind == .double2 ? 2 : 3
      let parts: [Any] = (raw as? [Any]) ?? ((raw as? String)?.split(separator: ",").map(String.init) ?? [])
      let xs = parts.compactMap(number)
      guard xs.count == n, parts.count == n else { throw Failure(message: "\(name): expected \(n) numbers") }
      return .vector(try xs.map(ranged))
    case .int:
      guard let x = number(raw), x == x.rounded() else { throw Failure(message: "\(name): expected a whole number") }
      return .int(Int(try ranged(x)))
    case .choice, .filmStock, .printPaper:
      let c = choices(d)
      if let x = number(raw) {
        guard x == x.rounded(), c.indices.contains(Int(x)) else {
          throw Failure(message: "\(name): index \(x) out of range 0…\(c.count - 1)")
        }
        return .int(Int(x))
      }
      let s = (raw as? String ?? "").lowercased()
      let names = d.kind == .choice ? c : c.map(FilmInfo.displayName)
      if let i = c.indices.first(where: { c[$0].lowercased() == s || names[$0].lowercased() == s }) { return .int(i) }
      throw Failure(message: "\(name): unknown option \"\(raw)\"; see params")
    }
  }

  // MARK: Commands

  static func state(_ model: EditModel) -> JSON {
    let film = model.value("film").intValue, paper = model.value("paper").intValue
    var view: JSON = ["compare": model.compareMode.rawValue]
    if let c = canvas { view["zoom"] = c.effectiveZoom; view["fit"] = c.zoom == nil; view["fill"] = c.fill }
    var info: JSON = [:]
    if let url = model.inputURL { info["path"] = url.path }
    if let p = model.preview { info["previewSize"] = [p.width, p.height] }
    let agent = AgentSession.shared
    return [
      "values": (agent.active ? agent.draft : model.values).mapValues(json),
      "draft": agent.active ? ["request": agent.request, "steps": agent.steps.map(\.label), "finished": agent.finished] as JSON
        : NSNull(),
      "film": Catalog.films[safe: film].map(FilmInfo.displayName) ?? "",
      "paper": Catalog.papers[safe: paper].map(FilmInfo.displayName) ?? "",
      "history": ["position": model.historyPosition, "count": model.historyCount,
                  "steps": model.historyCount == 0 ? [] : (1...model.historyCount).map { model.historyEntry($0).label }],
      "view": view, "info": info, "references": agent.references.count,
    ]
  }

  /// `{"values": {name: value, …}, "label": …, "note": …}`: all checked first, then one draft step
  /// (the user's history is untouched until apply; starts a request if none runs).
  static func set(_ req: JSON, _ model: EditModel) throws -> Any {
    guard let raw = req["values"] as? JSON, !raw.isEmpty else { throw Failure(message: "set needs \"values\": {name: value}") }
    let parsed = Dictionary(uniqueKeysWithValues: try raw.map { ($0.key, try parse($0.key, $0.value)) })
    return try AgentSession.shared.step(model, parsed, label: req["label"] as? String, note: req["note"] as? String)
  }

  /// Hardware controllers (Monogram Creator): the user's own hand, so it edits the real values, not an AI draft.
  /// `values` sets, `delta` adds (clamped; choices wrap), `toggle` flips bools. A burst of ticks becomes one history entry (0.6 s idle).
  private static var adjustCommit: Timer?
  static func adjust(_ req: JSON, _ model: EditModel) throws -> Any {
    var touched: [String] = []
    model.beginInteraction()
    for (k, v) in req["values"] as? JSON ?? [:] { model.set(k, try parse(k, v)); touched.append(k) }
    for (k, v) in req["delta"] as? JSON ?? [:] {
      guard let d = Catalog.byName[k], let x = number(v) else { throw Failure(message: "\(k): delta needs a number") }
      let cur = model.value(k)
      switch d.kind {
      case .double: model.set(k, .double(min(max(cur.doubleValue + x, d.minimum), d.maximum)))
      case .int: model.set(k, .int(Int(min(max(Double(cur.intValue) + x, d.minimum), d.maximum))))
      case .choice, .filmStock, .printPaper:
        let n = choices(d).count
        if n > 0 { model.set(k, .int(((cur.intValue + Int(x.rounded())) % n + n) % n)) }
      default: throw Failure(message: "\(k): delta only for numbers and choices")
      }
      touched.append(k)
    }
    for k in req["toggle"] as? [String] ?? [] {
      guard Catalog.byName[k]?.kind == .bool else { throw Failure(message: "\(k): not a bool") }
      model.set(k, .bool(!model.value(k).boolValue))
      touched.append(k)
    }
    adjustCommit?.invalidate()
    adjustCommit = Timer.scheduledTimer(withTimeInterval: 0.6, repeats: false) { [weak model] _ in model?.commit() }
    return ["touched": touched]
  }

  static func preset(_ req: JSON, _ model: EditModel) throws -> Any {
    let name = req["name"] as? String ?? ""
    guard let p = Presets.named(name), let v = Presets.load(p) else { throw Failure(message: "no preset \"\(name)\"") }
    return try AgentSession.shared.step(model, v, label: tr("프리셋: ", "Preset: ") + p.name, note: req["note"] as? String)
  }

  static func history(_ req: JSON, _ model: EditModel) throws -> Any {
    let agent = AgentSession.shared
    switch req["action"] as? String {
    // The agent never moves the user's own history.
    case "undo":
      guard agent.active, !agent.steps.isEmpty else { throw Failure(message: "no AI draft step to undo") }
      agent.undo(model)
      return ["steps": agent.steps.count]
    case "redo": throw Failure(message: "redo is not kept in the AI draft; set again")
    case "snapshot": model.addSnapshot(name: req["name"] as? String)
    default: throw Failure(message: "history action: undo, redo or snapshot")
    }
    return ["position": model.historyPosition, "count": model.historyCount]
  }

  static func view(_ req: JSON, _ model: EditModel) throws -> Any {
    if let m = req["compare"] as? String {
      guard let mode = CompareMode(rawValue: m) else {
        throw Failure(message: "compare: " + CompareMode.allCases.map(\.rawValue).joined(separator: ", "))
      }
      model.compareMode = mode
    }
    if let z = req["zoom"] {
      guard let canvas else { throw Failure(message: "no canvas") }
      switch z as? String {
      case "fit": canvas.choose(nil)
      case "fill": canvas.chooseFill()
      default:
        guard let x = number(z), x > 0 else { throw Failure(message: "zoom: fit, fill or a factor (1 = 100%)") }
        canvas.choose(x)
      }
    }
    return state(model)["view"] ?? [:]
  }

  /// The current preview as PNG (base64), at most `width` pixels wide (default 1024). During a
  /// session it is the draft, which renders on the compare side.
  static func capture(_ req: JSON, _ model: EditModel) throws -> Any {
    try png(shown(model), width: Int(number(req["width"] ?? 1024) ?? 1024))
  }

  /// What capture and measure look at: during a session the draft, which renders on the compare side.
  /// Look numbers of what the canvas shows (the draft during a request), for the AI tab's before → after.
  static func look(_ model: EditModel) -> Look? { (try? shown(model)).flatMap(Look.init) }

  private static func shown(_ model: EditModel) throws -> CGImage {
    // shortcut: if the user turns compare off mid-session this shows their own image, not the draft.
    let shown = AgentSession.shared.active && model.compareMode != .off ? model.compareImage : model.preview
    guard let p = shown, let image = PixelImage.cgImage(halfP3: p) else { throw Failure(message: "no preview yet") }
    return image
  }

  private static func png(_ image: CGImage, width w: Int) throws -> JSON {
    let width = min(max(w, 64), image.width)
    let height = max(1, image.height * width / image.width)
    guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw Failure(message: "capture failed") }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    let data = NSMutableData()
    guard let small = ctx.makeImage(),
          let dest = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
      throw Failure(message: "capture failed")
    }
    CGImageDestinationAddImage(dest, small, nil)
    guard CGImageDestinationFinalize(dest) else { throw Failure(message: "capture failed") }
    return ["png": (data as Data).base64EncodedString(), "width": width, "height": height]
  }

  /// `paths` replaces the reference photos (`[]` clears); without it, reports the current ones.
  /// Each photo's look numbers, their mean (and range), and a PNG of them side by side.
  static func reference(_ req: JSON) throws -> Any {
    let session = AgentSession.shared
    if let raw = req["paths"] {
      guard let paths = raw as? [String] else { throw Failure(message: "paths: a list of file paths") }
      session.setReferences(try paths.map { p in
        let url = URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
        guard let image = Look.load(url), let look = Look(image) else { throw Failure(message: "cannot read \(url.path)") }
        return AgentSession.Reference(url: url, image: image, look: look)
      })
    }
    let refs = session.references
    guard !refs.isEmpty else { return ["count": 0] }
    let looks = refs.map(\.look.json)
    var out: JSON = ["count": refs.count, "paths": refs.map(\.url.path), "looks": looks, "mean": Look.mean(refs.map(\.look)).json]
    if refs.count > 1 {
      out["range"] = looks[0].keys.reduce(into: [String: Double]()) { r, k in
        let xs = looks.compactMap { $0[k] }
        r[k] = ((xs.max()! - xs.min()!) * 1000).rounded() / 1000
      }
    }
    // Side by side at 256 px high.
    let h = 256
    let widths = refs.map { max(1, $0.image.width * h / max($0.image.height, 1)) }
    if let ctx = CGContext(data: nil, width: widths.reduce(0, +), height: h, bitsPerComponent: 8, bytesPerRow: 0,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
      var x = 0
      for (r, w) in zip(refs, widths) { ctx.draw(r.image, in: CGRect(x: x, y: 0, width: w, height: h)); x += w }
      if let sheet = ctx.makeImage() { out.merge(try png(sheet, width: 1024).filter { $0.key == "png" }) { $1 } }
    }
    return out
  }

  /// Look numbers of the shown preview; with references also the target, the difference per
  /// number (preview − target) and the distance, which the AI tab shows as progress.
  static func measure(_ model: EditModel) throws -> Any {
    guard let look = Look(try shown(model)) else { throw Failure(message: "measure failed") }
    var out: JSON = ["look": look.json]
    let refs = AgentSession.shared.references
    if !refs.isEmpty {
      let target = Look.mean(refs.map(\.look))
      let d = look.distance(target)
      let mine = look.json, theirs = target.json
      out["target"] = theirs
      out["difference"] = mine.reduce(into: [String: Double]()) { $0[$1.key] = (($1.value - (theirs[$1.key] ?? 0)) * 1000).rounded() / 1000 }
      out["distance"] = (d * 1000).rounded() / 1000
      AgentSession.shared.noteDistance(d)
    }
    return out
  }

  /// Opens only the path the caller names; nothing is listed or searched.
  static func open(_ req: JSON, _ model: EditModel) throws -> Any {
    let path = (req["path"] as? String ?? "") as NSString
    let url = URL(fileURLWithPath: path.expandingTildeInPath)
    guard FileManager.default.isReadableFile(atPath: url.path) else { throw Failure(message: "cannot read \(url.path)") }
    guard model.standalone, !model.saving else { throw Failure(message: "editor is busy or in batch mode") }
    model.open(url)
    return ["path": url.path]
  }

  /// Writes a new file inside the allowed folder only; never replaces an existing file.
  static func export(_ req: JSON, _ model: EditModel) throws -> Any {
    let folder = exportFolder.standardizedFileURL.resolvingSymlinksInPath()
    let name = req["path"] as? String ?? ""
    let url = (name.hasPrefix("/") || name.hasPrefix("~")
      ? URL(fileURLWithPath: (name as NSString).expandingTildeInPath) : folder.appendingPathComponent(name))
      .standardizedFileURL
    let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
    guard !name.isEmpty, parent == folder.path || parent.hasPrefix(folder.path + "/") else {
      throw Failure(message: "export only inside \(folder.path)")
    }
    guard !FileManager.default.fileExists(atPath: url.path) else { throw Failure(message: "\(url.lastPathComponent) already exists") }
    let format: ExportFormat = ["jpg", "jpeg"].contains(url.pathExtension.lowercased()) ? .jpeg : .tiff16
    guard model.source != nil, !model.saving else { throw Failure(message: "no photo open, or already saving") }
    try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
    model.export(to: url, format: format)
    return ["path": url.path, "format": format.rawValue, "status": "started"]
  }
}


/// One AI request at a time works on a draft copy of the values: the user keeps editing their own
/// history, the canvas shows the draft beside it, and only Apply (or Discard) touches the history.
@Observable final class AgentSession {
  struct Step { let label: String; let changes: [String: ParamValue]; let note: String? }
  static let shared = AgentSession()

  private(set) var active = false
  /// The agent said it is done; waiting for Apply or Discard.
  private(set) var finished = false
  private(set) var request = ""
  private(set) var agent = ""
  private(set) var base: [String: ParamValue] = [:]
  private(set) var draft: [String: ParamValue] = [:]
  private(set) var steps: [Step] = []
  /// Names the latest step changed (orange card border).
  private(set) var touching: Set<String> = []
  /// Review: steps shown on the canvas (0…steps.count), and steps unticked for "picked only".
  private(set) var at = 0
  private(set) var skipped: Set<Int> = []
  enum Pick { case upTo, picked, all }
  /// Reference photos to match; they outlive a request (the user drops them before asking).
  struct Reference { let url: URL; let image: CGImage; let look: Look }
  private(set) var references: [Reference] = []
  /// Each `measure` distance this request, for the AI tab's progress line.
  private(set) var distances: [Double] = []
  @ObservationIgnored private var previous: (CompareMode, CompareBase)?

  var source: String { "ai:" + (agent.isEmpty ? "agent" : agent) }
  static let draftLabel = tr("✦ AI 작업 중", "✦ AI working")

  func begin(_ model: EditModel, request: String, agent: String) throws {
    guard !active else { throw AgentCommands.Failure(message: "an AI request is already running") }
    model.commit()
    self.request = request.isEmpty ? tr("요청", "Request") : String(request.prefix(60))
    self.agent = agent
    base = model.values
    draft = base
    steps = []
    touching = []
    at = 0
    skipped = []
    distances = []
    finished = false
    active = true
    previous = (model.compareMode, model.compareBase)
    if model.compareMode == .off { model.compareMode = .sideBySide }
    model.compareBase = .history(Self.draftLabel, draft)
  }

  /// One draft step; starts a request when none runs.
  func step(_ model: EditModel, _ changes: [String: ParamValue], label: String?, note: String?) throws -> Any {
    if !active { try begin(model, request: label ?? "", agent: "") }
    guard !finished else { throw AgentCommands.Failure(message: "request finished; apply or discard first") }
    let delta = changes.filter { draft[$0.key] != $0.value }
    if !delta.isEmpty {
      let next = draft.merging(delta) { $1 }
      steps.append(Step(label: label ?? model.changeLabel(from: draft, to: next), changes: delta, note: note))
      draft = next
      at = steps.count
      touching = Set(delta.keys)
      model.compareBase = .history(Self.draftLabel, draft)
    }
    return ["steps": steps.count]
  }

  func undo(_ model: EditModel) {
    guard steps.popLast() != nil else { return }
    draft = state(steps.count)
    at = steps.count
    skipped.remove(steps.count)
    touching = Set(steps.last?.changes.keys.map { $0 } ?? [])
    model.compareBase = .history(Self.draftLabel, draft)
  }

  /// Expert level applies at once; otherwise the canvas asks.
  func finish(_ model: EditModel) {
    guard active else { return }
    finished = true
    touching = []
    if UserDefaults.standard.string(forKey: ToolLevel.key) == ToolLevel.expert.rawValue { apply(model, ask: true) }
  }

  /// Draft values after the first `k` steps.
  func state(_ k: Int) -> [String: ParamValue] {
    steps.prefix(k).reduce(base) { $0.merging($1.changes) { $1 } }
  }

  /// Review scrub: the canvas shows the draft after `k` steps.
  func show(_ model: EditModel, _ k: Int) {
    at = min(max(k, 0), steps.count)
    model.compareBase = .history(at == steps.count ? Self.draftLabel : Self.draftLabel + " · #\(at)", state(at))
  }

  func setReferences(_ r: [Reference]) {
    references = r
    distances = []
  }

  func noteDistance(_ d: Double) { distances.append(d) }

  func setSkipped(_ i: Int, _ skip: Bool) {
    if skip { skipped.insert(i) } else { skipped.remove(i) }
  }

  /// Ticked step → the earlier unticked step it may lean on: one that touched the same module,
  /// or changed film or paper (later steps were tuned on top of it).
  func leaning() -> [Int: Int] {
    func groups(_ i: Int) -> Set<String> { Set(steps[i].changes.keys.compactMap { Catalog.byName[$0]?.group }) }
    var out: [Int: Int] = [:]
    for j in steps.indices where !skipped.contains(j) {
      out[j] = skipped.sorted().last {
        $0 < j && (!groups($0).isDisjoint(with: groups(j)) || steps[$0].changes.keys.contains { $0 == "film" || $0 == "paper" })
      }
    }
    return out
  }

  /// Returns the names kept at the user's value (items both the user, since the request
  /// started, and the agent changed, to different values).
  @discardableResult func apply(_ model: EditModel, ask: Bool, pick: Pick = .all) -> Set<String> {
    if ask, pick == .picked, !leaning().isEmpty, !Self.confirm(
      tr("건너뛴 단계에 기대는 단계가 있습니다", "Some ticked steps lean on skipped ones"),
      leaning().sorted { $0.key < $1.key }.map { tr("#\($0.key + 1)은 #\($0.value + 1) 뒤에 맞춘 것입니다", "#\($0.key + 1) was tuned after #\($0.value + 1)") }
        .joined(separator: "\n") + tr("\n\n그래도 고른 단계만 적용할까요?", "\n\nApply the ticked steps anyway?")) { return [] }
    model.commit()
    let chosen = steps.indices.filter { pick == .all || (pick == .upTo ? $0 < at : !skipped.contains($0)) }.map { steps[$0] }
    let final = chosen.reduce(base) { $0.merging($1.changes) { $1 } }
    var keep = Set(chosen.flatMap(\.changes.keys)).filter { model.values[$0] != base[$0] && model.values[$0] != final[$0] }
    if ask, !keep.isEmpty, !Self.keepMine(keep) { keep = [] }
    let skip = steps.count - chosen.count
    model.applyAgentSteps(chosen, request: request + (skip > 0 ? tr(" · 건너뜀 \(skip)단계", " · skipped \(skip)") : ""),
                          source: source, keep: keep)
    end(model)
    return keep
  }

  /// Keeps the shown draft as a snapshot instead of history, and ends the request.
  func keepAsSnapshot(_ model: EditModel) {
    model.addSnapshot(name: "AI · " + request, values: state(at))
    end(model)
  }

  func saveAsPreset() {
    Presets.save(state(at), name: Presets.uniqueName("AI · " + request))
  }

  /// The request's steps as Markdown, to learn from.
  func lesson() -> String {
    var md = "# ✦ AI · \(request)\n\n" + tr("에이전트", "Agent") + ": \(agent.isEmpty ? "agent" : agent) · "
      + tr("\(steps.count)단계", "\(steps.count) steps") + "\n"
    for (i, s) in steps.enumerated() {
      md += "\n## \(i + 1). \(s.label)\n\n"
      md += StepChanges.lines(from: state(i), to: state(i + 1)).map { "- " + $0 }.joined(separator: "\n") + "\n"
      if let n = s.note { md += "\n> " + tr("왜: ", "Why: ") + n + "\n" }
    }
    return md
  }

  func saveLesson() {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = "AI " + tr("레슨", "Lesson") + " - " + request.replacingOccurrences(of: "/", with: "-") + ".md"
    panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
    guard panel.runModal() == .OK, let url = panel.url else { return }
    try? lesson().write(to: url, atomically: true, encoding: .utf8)
  }

  /// Discard (and stop): nothing is left behind.
  func end(_ model: EditModel) {
    guard active else { return }
    if let (mode, base) = previous { model.compareBase = base; model.compareMode = mode }
    active = false
    finished = false
    steps = []
    touching = []
    previous = nil
  }

  private static func confirm(_ title: String, _ text: String) -> Bool {
    let alert = NSAlert()
    alert.messageText = title
    alert.informativeText = text
    alert.addButton(withTitle: tr("적용", "Apply"))
    alert.addButton(withTitle: tr("취소", "Cancel"))
    return alert.runModal() == .alertFirstButtonReturn
  }

  private static func keepMine(_ names: Set<String>) -> Bool {
    let alert = NSAlert()
    alert.messageText = tr("나와 AI가 같은 항목을 바꿨습니다", "You and the AI changed the same items")
    alert.informativeText = names.map { Labels.param($0) }.sorted().joined(separator: "\n")
    alert.addButton(withTitle: tr("내 값 유지", "Keep Mine"))
    alert.addButton(withTitle: tr("AI 값", "Use AI's"))
    return alert.runModal() != .alertSecondButtonReturn
  }
}

/// Runs commands one at a time on the main thread; changes are spaced (default 0.3 s) so the
/// user can follow them on the canvas.
@MainActor enum AgentQueue {
  static let delayKey = "agentStepDelay"
  private static var tail: Task<Void, Never>?
  private static var last = Date.distantPast

  static func submit(_ req: AgentCommands.JSON, reply: @escaping (AgentCommands.JSON) -> Void) {
    let previous = tail
    tail = Task { @MainActor in
      await previous?.value
      if ["set", "preset", "history"].contains(req["cmd"] as? String ?? "") {
        let delay = UserDefaults.standard.object(forKey: delayKey) as? Double ?? 0.3
        let wait = delay - Date().timeIntervalSince(last)
        if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1e9)) }
        last = Date()
      }
      if ["capture", "measure"].contains(req["cmd"] as? String ?? ""), let m = AgentCommands.model { await settle(m) }
      reply(AgentCommands.run(req, model: AgentCommands.model))
    }
  }

  /// Waits (at most 10 s) until the last change has rendered, so a capture shows it; with no photo open it returns at once.
  static func settle(_ model: EditModel) async {
    let end = Date().addingTimeInterval(10)
    while model.inputURL != nil, model.preview == nil || !model.renderSettled, Date() < end { try? await Task.sleep(nanoseconds: 50_000_000) }
  }

  /// `--agent-script file`: one JSON command per line, replies printed to stdout (demo / tests).
  static func runScript(_ url: URL) {
    guard let text = try? String(contentsOf: url, encoding: .utf8) else {
      print(#"{"ok":false,"error":"cannot read agent script"}"#)
      return
    }
    for line in text.split(separator: "\n") where !line.trimmingCharacters(in: .whitespaces).isEmpty {
      guard let req = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? AgentCommands.JSON else {
        print(#"{"ok":false,"error":"not a JSON object"}"#)
        continue
      }
      submit(req) { reply in
        if let data = try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys]) {
          print(String(decoding: data, as: UTF8.self))
          fflush(stdout)
        }
      }
    }
  }
}

/// Settings › AI: a local socket other programs (photoemul-mcp) talk to, one JSON object per line.
/// A connection's first line must be `{"cmd":"hello","token":…}`. Off by default; the socket is 0600.
@Observable final class AgentServer {
  static let shared = AgentServer()
  static let enabledKey = "agentServer", tokenKey = "agentToken", snapshotKey = "agentSnapshot"
  static var socketURL: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("\(Rename.folder)/agent.sock")
  }
  static var token: String {
    if let t = UserDefaults.standard.string(forKey: tokenKey), !t.isEmpty { return t }
    return newToken()
  }
  @discardableResult static func newToken() -> String {
    let t = (0..<4).map { _ in String(UInt64.random(in: 0...UInt64.max), radix: 36) }.joined()
    UserDefaults.standard.set(t, forKey: tokenKey)
    return t
  }

  /// Client side, for photoemul-mcp and the self-test.
  static func connect(_ url: URL = AgentServer.socketURL) -> FileHandle? {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let path = Array(url.path.utf8CString)
    guard path.count <= MemoryLayout.size(ofValue: addr.sun_path) else { return nil }
    withUnsafeMutableBytes(of: &addr.sun_path) { dst in path.withUnsafeBytes { dst.copyMemory(from: $0) } }
    let s = socket(AF_UNIX, SOCK_STREAM, 0)
    let ok = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard s >= 0, ok == 0 else { if s >= 0 { close(s) }; return nil }
    return FileHandle(fileDescriptor: s, closeOnDealloc: true)
  }

  /// Fixed token for the self-test; the app uses the stored one.
  @ObservationIgnored private let fixedToken: String?
  init(token: String? = nil) { fixedToken = token }

  private(set) var listening: String?
  private(set) var clients = 0
  private(set) var failure: String?
  @ObservationIgnored private var fd: Int32 = -1
  @ObservationIgnored private var nextID = 0
  /// Connection that started the running request; others may read but not edit until it ends.
  @ObservationIgnored private var owner: Int?

  func start(at url: URL = AgentServer.socketURL) {
    guard fd < 0 else { return }
    try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    unlink(url.path)
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let path = Array(url.path.utf8CString)
    guard path.count <= MemoryLayout.size(ofValue: addr.sun_path) else { failure = "socket path too long"; return }
    withUnsafeMutableBytes(of: &addr.sun_path) { dst in path.withUnsafeBytes { dst.copyMemory(from: $0) } }
    let s = socket(AF_UNIX, SOCK_STREAM, 0)
    let bound = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard s >= 0, bound == 0, chmod(url.path, 0o600) == 0, listen(s, 8) == 0 else {
      failure = String(cString: strerror(errno))
      if s >= 0 { close(s) }
      return
    }
    fd = s
    failure = nil
    listening = url.path
    Thread.detachNewThread { [self] in
      while true {
        let c = accept(s, nil, nil)
        if c < 0 { break }  // closed by stop()
        DispatchQueue.main.async { [self] in
          nextID += 1
          clients += 1
          let id = nextID
          Thread.detachNewThread { [self] in serve(c, id: id) }
        }
      }
    }
  }

  func stop() {
    guard fd >= 0, let path = listening else { return }
    shutdown(fd, SHUT_RDWR)
    close(fd)
    fd = -1
    unlink(path)
    listening = nil
  }

  private func serve(_ c: Int32, id: Int) {
    let handle = FileHandle(fileDescriptor: c, closeOnDealloc: true)
    var buffer = Data(), authed = false
    // A dropped client gives up its request so the next one can take over or discard the draft.
    defer { DispatchQueue.main.async { [self] in clients -= 1; if owner == id { owner = nil } } }
    while true {
      let chunk = handle.availableData
      if chunk.isEmpty { return }
      buffer.append(chunk)
      while let nl = buffer.firstIndex(of: 0x0A) {
        let line = buffer[buffer.startIndex..<nl]
        buffer.removeSubrange(buffer.startIndex...nl)
        guard !line.allSatisfy({ $0 == 0x20 || $0 == 0x0D }) else { continue }
        let req = try? JSONSerialization.jsonObject(with: line) as? AgentCommands.JSON
        var reply: AgentCommands.JSON
        if let req, !authed {
          authed = req["cmd"] as? String == "hello" && req["token"] as? String == (fixedToken ?? Self.token)
          reply = authed ? ["ok": true, "result": ["app": "PhotoEmul"]]
            : ["ok": false, "error": "send {\"cmd\":\"hello\",\"token\":…} first; the token is in PhotoEmul › Settings › AI"]
        } else if let req {
          reply = run(req, id: id)
        } else {
          reply = ["ok": false, "error": "not a JSON object"]
        }
        if let rid = req?["id"] { reply["id"] = rid }
        var out = (try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])) ?? Data()
        out.append(0x0A)
        guard (try? handle.write(contentsOf: out)) != nil else { return }
        if !authed { return }
      }
    }
  }

  /// Runs one command on the main queue (through AgentQueue's pacing) and waits for its reply.
  private func run(_ req: AgentCommands.JSON, id: Int) -> AgentCommands.JSON {
    var reply: AgentCommands.JSON = [:]
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.main.async { [self] in
      let reads: Set<String> = ["params", "presets", "state", "view", "capture", "measure", "adjust"]  // adjust = the user's own controller, never part of an AI request
      // shortcut: another client's edit is refused while a request is owned, not queued; queue if two agents ever share a window.
      if let o = owner, o != id, AgentSession.shared.active, !reads.contains(req["cmd"] as? String ?? "") {
        reply = ["ok": false, "error": "busy: another AI client's request is running"]
        done.signal()
        return
      }
      AgentQueue.submit(req) { [self] r in
        reply = r
        owner = AgentSession.shared.active ? (owner ?? id) : nil
        done.signal()
      }
    }
    done.wait()
    return reply
  }
}
