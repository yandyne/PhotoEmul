// PhotoEmul - native editor for spektrafilm (GPL-3.0-or-later)
//
//   PhotoEmul [photo]                             standalone: open/drop photos, ⌘S exports (TIFF/JPEG)
//   PhotoEmul --input in.tif --output out.tif     edit, ⌘S writes out.tif and quits
//   PhotoEmul --input in.tif --render-test out.tif [--film N]   headless render
//   PhotoEmul --list-params [--json]                              dump engine descriptors (JSON: agent command view)
//   PhotoEmul --batch-list list.tsv [--key K]                     edit once, ⌘S renders every photo
//   PhotoEmul --batch-list list.tsv --headless [--preset P] [--set n=v]   render without UI
//   PhotoEmul --export-lut out.cube [--preset P] [--set n=v] [--input img]   colour-only 3D LUT (+ accuracy check)

import AppKit
import SwiftUI

struct LaunchOptions {
  var input: URL?
  var output: URL?
  var renderTest: URL?
  var film: Int?
  var snapshot: URL?
  /// Session key (the Lightroom original's path) so reopening resumes the edit.
  var key: String?
  var batch: [BatchItem] = []
  var headless = false
  var preset: String?
  var exportLut: URL?
  /// `--agent-script file`: JSON commands run once the window is up (AI demo).
  var agentScript: URL?
  /// `--set name=value` overrides for headless renders (bool: true/false, vector: a,b,c).
  var overrides: [(String, String)] = []

  static func parse(_ args: [String]) -> LaunchOptions {
    var o = LaunchOptions()
    var it = args.dropFirst().makeIterator()
    while let a = it.next() {
      switch a {
      case "--input": o.input = it.next().map { URL(fileURLWithPath: $0) }
      case "--output": o.output = it.next().map { URL(fileURLWithPath: $0) }
      case "--render-test": o.renderTest = it.next().map { URL(fileURLWithPath: $0) }
      case "--film": o.film = it.next().flatMap { Int($0) }
      case "--snapshot": o.snapshot = it.next().map { URL(fileURLWithPath: $0, isDirectory: true) }
      case "--key": o.key = it.next()
      case "--batch-list": o.batch = it.next().map { BatchItem.readList(URL(fileURLWithPath: $0)) } ?? []
      case "--headless": o.headless = true
      case "--preset": o.preset = it.next()
      case "--export-lut": o.exportLut = it.next().map { URL(fileURLWithPath: $0) }
      case "--agent-script": o.agentScript = it.next().map { URL(fileURLWithPath: $0) }
      case "--set":
        if let kv = it.next(), let eq = kv.firstIndex(of: "=") {
          o.overrides.append((String(kv[..<eq]), String(kv[kv.index(after: eq)...])))
        }
      default:
        // `open file.tif` style launch or a bare path argument
        if !a.hasPrefix("-"), o.input == nil, FileManager.default.fileExists(atPath: a) {
          o.input = URL(fileURLWithPath: a)
        }
      }
    }
    if let first = o.batch.first {
      o.input = first.input
      o.output = first.output
      if o.key == nil { o.key = first.key }
    }
    return o
  }
}

let launch = LaunchOptions.parse(CommandLine.arguments)

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
  }

  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    EditModel.current?.confirmQuit() ?? true ? .terminateNow : .terminateCancel
  }

  /// Finder "Open With", dropping on the Dock icon, `open -a PhotoEmul photo.raf`.
  func application(_ application: NSApplication, open urls: [URL]) {
    guard let url = urls.first(where: \.isFileURL) else { return }
    if let model = EditModel.current { model.open(url) } else { EditModel.pendingOpen = url }
  }
}

/// The app was called SpektraLab until 0.1.41 and Emulsa until 0.1.121. The first launch under a
/// new name carries over the previous settings and presets; the old copies are left for an old
/// build that may still be around.
enum Rename {
  typealias Predecessor = (domain: String, folder: String, doneKey: String)
  /// (defaults domain, Application Support / Caches folder, defaults flag) of every earlier name, oldest first.
  static let predecessors: [Predecessor] = [
    ("org.spektrafilm.SpektraLab", "SpektraLab", "renamedFromSpektraLab"),
    ("org.spektrafilm.Emulsa", "Emulsa", "renamedFromEmulsa"),
  ]
  static let oldDomain = predecessors.last!.domain
  static let folder = "PhotoEmul"

  static func migrate() {
    guard launch.snapshot == nil else { return }
    let files = FileManager.default
    migrate(from: predecessors, into: .standard,
            support: files.urls(for: .applicationSupportDirectory, in: .userDomainMask).first,
            caches: files.urls(for: .cachesDirectory, in: .userDomainMask).first)
  }

  /// The copy itself; stores and folders are passed in so --self-test can run it on scratch copies.
  static func migrate(from olds: [Predecessor], into store: UserDefaults, support: URL?, caches: URL?) {
    // Runs after the settings copy below, which may bring an old default back with it.
    defer {
      if let rule = store.string(forKey: ExportOptions.nameKey), ExportOptions.legacyDefaultNames.contains(rule) {
        store.removeObject(forKey: ExportOptions.nameKey)
      }
    }
    let files = FileManager.default
    // Newest name first: it holds the latest settings, and older names only fill in what is missing.
    for old in olds.reversed() where !store.bool(forKey: old.doneKey) {
      store.set(true, forKey: old.doneKey)
      for (key, value) in store.persistentDomain(forName: old.domain) ?? [:] where store.object(forKey: key) == nil {
        store.set(value, forKey: key)
      }
      if let support {
        let from = support.appendingPathComponent(old.folder), to = support.appendingPathComponent(folder)
        if files.fileExists(atPath: from.path), !files.fileExists(atPath: to.path) { try? files.copyItem(at: from, to: to) }
      }
      // Thumbnails are rebuilt on demand, so the old cache only takes up space.
      if let caches {
        try? files.removeItem(at: caches.appendingPathComponent(old.folder))
      }
    }
  }
}

@main
struct PhotoEmulApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @State private var model: EditModel
  @State private var canvas = CanvasState()
  @AppStorage(L10n.key) private var language = L10n.Choice.system.rawValue
  @AppStorage(Appearance.key) private var appearance = Appearance.system.rawValue
  // Read so the panel items in the View menu keep their ticks current.
  @AppStorage(Panels.recipeBarKey) private var recipeBarOpen = true
  @AppStorage(Panels.inspectorKey) private var inspectorOpen = true
  @AppStorage(HistoryTimeline.shownKey) private var timelineShown = true

  init() {
    // Before the migration below, so the check never touches the real settings.
    if CommandLine.arguments.contains("--self-test") { exit(SelfTest.run()) }
    if CommandLine.arguments.contains("--mcp") { MCP.run() }
    Rename.migrate()
    ToolLevel.setDefault()
    if CommandLine.arguments.contains("--list-params") {
      if CommandLine.arguments.contains("--json"),
         let data = try? JSONSerialization.data(withJSONObject: AgentCommands.params(), options: [.prettyPrinted, .sortedKeys]) {
        print(String(decoding: data, as: UTF8.self))
        exit(0)
      }
      for d in Catalog.params {
        print("\(d.group)\t\(d.name)\t\(d.label)\t\(d.kind)\ttier\(d.tier)\t\(d.defaultValue)\t\(d.minimum)...\(d.maximum)\t\(d.options.joined(separator: "|"))")
      }
      exit(0)
    }
    if let out = launch.renderTest {
      exit(HeadlessRender.run(input: launch.input, output: out, film: launch.film))
    }
    if let out = launch.exportLut { exit(HeadlessRender.exportLut(to: out)) }
    if launch.headless, !launch.batch.isEmpty { exit(HeadlessRender.batch(launch.batch)) }
    Snapshotter.shared.directory = launch.snapshot
    Layout.prepareForLaunch()
    FilmPanel.prepareForLaunch()
    // The splash (if this Mac is slow to start) lights one layer per real stage below.
    Splash.begin()
    let engine = SpektraEngine()
    Splash.advance(.films)
    _ = (Catalog.params, Catalog.films)
    Splash.advance(.papers)
    _ = Catalog.papers
    _model = State(initialValue: EditModel(
      input: launch.input, output: launch.output, sessionKey: launch.key, batch: launch.batch, engine: engine))
    Splash.advance(.session)
  }

  var body: some Scene {
    // One window: a WindowGroup opens a second one for every Finder "Open With" or Dock drop.
    Window("PhotoEmul", id: "main") {
      ContentView(model: model, canvas: canvas)
        .id(language)  // rebuild every view so all text follows the new language
        .frame(minWidth: 1100, minHeight: 700)
        .background(WindowFrameSaver())
        .onAppear {
          model.load()
          AgentCommands.canvas = canvas
        AgentCommands.model = model
        // A scripted run (tests, demo) leaves the socket to the app the user is running.
        if launch.agentScript == nil, UserDefaults.standard.bool(forKey: AgentServer.enabledKey) { AgentServer.shared.start() }
        if let script = launch.agentScript { AgentQueue.runScript(script) }
          Appearance.apply(appearance)
          if model.inputURL == nil { Splash.finish() }  // empty window: nothing more to wait for
        }
        .onChange(of: appearance) { _, v in Appearance.apply(v) }
    }
    .defaultSize(Layout.defaultSize)
    .windowToolbarStyle(.unified(showsTitle: false))
    .commands {
      CommandGroup(replacing: .appInfo) { AboutCommand() }
      CommandGroup(replacing: .newItem) {
        if model.standalone {
          Button(tr("열기…", "Open…")) { model.showOpenPanel() }.keyboardShortcut("o")
        }
      }
      CommandGroup(replacing: .saveItem) {
        // Replacing .saveItem also drops the system Close item, so both closes live here.
        if model.standalone {
          Button(tr("사진 닫기", "Close Photo")) { model.closePhoto() }
            .keyboardShortcut("w").disabled(model.inputURL == nil || model.saving)
        }
        // A click, not performClose, so the main window goes through CloseGuard.
        Button(tr("창 닫기", "Close Window")) { NSApp.keyWindow?.standardWindowButton(.closeButton)?.performClick(nil) }
          .keyboardShortcut("w", modifiers: model.standalone ? [.command, .shift] : .command)
        Divider()
        Button(model.standalone ? tr("내보내기…", "Export…") : tr("Lightroom에 저장", "Save to Lightroom")) { model.save() }
          .keyboardShortcut("s").disabled(model.source == nil || model.saving)
        if model.standalone {
          Button(tr("이 편집을 여러 사진에 적용…", "Apply This Edit to Photos…")) { model.applyToOtherPhotos() }
            .keyboardShortcut("e", modifiers: [.command, .shift]).disabled(model.saving)
        }
        Divider()
        Button(tr("LUT로 내보내기 (.cube)…", "Export as LUT (.cube)…")) { LutPanel.run(values: model.values, name: nil) }
      }
      CommandMenu(tr("보기", "View")) {
        Picker(tr("비교", "Compare"), selection: $model.compareMode) {
          ForEach(CompareMode.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.inline)
        Divider()
        // Like Lightroom: F5 top, F6 bottom, F7 left, F8 right, Tab both sides, ⇧Tab all (KeyHandler).
        Toggle(tr("레시피 바 (F5)", "Recipe Bar (F5)"), isOn: $recipeBarOpen)
        Toggle(tr("히스토리 타임라인 (F6)", "History Timeline (F6)"), isOn: $timelineShown)
          .keyboardShortcut("h", modifiers: [.command, .option])
        Toggle(tr("재료 패널 (F7)", "Stock Panel (F7)"), isOn: $model.pickerOpen).keyboardShortcut("1")
        Toggle(tr("도구 패널 (F8)", "Tool Panel (F8)"), isOn: $inspectorOpen)
        Button(tr("양옆 패널 접기·펴기 (Tab)", "Toggle Side Panels (Tab)")) { Panels.sides(model) }
        Button(tr("모든 패널 접기·펴기 (⇧Tab)", "Toggle All Panels (⇧Tab)")) { Panels.all(model) }
        Divider()
        Button(tr("확대", "Zoom In")) { canvas.step(1) }.keyboardShortcut("=")
        Button(tr("축소", "Zoom Out")) { canvas.step(-1) }.keyboardShortcut("-")
        Button(tr("맞춤", "Fit")) { canvas.setZoom(nil) }.keyboardShortcut("0")
        Button(tr("맞춤·채움 ↔ 확대 (Z)", "Fit · Fill ↔ Zoom (Z)")) { canvas.toggle() }
        Button(tr("사진 정보 표시 (I)", "Show Photo Info (I)")) {
          UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: OSD.infoOnKey), forKey: OSD.infoOnKey)
        }
        Button(model.testStripShown ? tr("테스트 스트립 숨기기 (T)", "Hide Test Strip (T)") : tr("테스트 스트립 보기 (T)", "Show Test Strip (T)")) {
          model.toggleTestStrip()
        }
        .keyboardShortcut("t", modifiers: []).disabled(!model.testStripAvailable)
        Divider()
        PanelLayoutCommands()
        Divider()
        Button(tr("스냅샷", "Snapshots")) { model.showHistory.toggle() }.keyboardShortcut("s", modifiers: [.command, .option])
        Button(tr("스냅샷 추가", "Add Snapshot")) { model.addSnapshot() }.keyboardShortcut("n", modifiers: [.command, .shift])
      }
      CommandGroup(replacing: .undoRedo) {
        Button(tr("실행 취소", "Undo")) { model.undo() }.keyboardShortcut("z").disabled(model.undoStack.isEmpty)
        Button(tr("다시 실행", "Redo")) { model.redo() }.keyboardShortcut("z", modifiers: [.command, .shift])
          .disabled(model.redoStack.isEmpty)
      }
    }
    // ⌘, : language, appearance and performance moved here from the menus.
    Window(tr("PhotoEmul 정보", "About PhotoEmul"), id: "about") {
      AboutView()
    }
    .windowResizability(.contentSize)
    Settings {
      SettingsView(model: model).id(language)
    }
  }
}

enum HeadlessRender {
  static func run(input: URL?, output: URL, film: Int?) -> Int32 {
    guard let input, let src = try? SourceImage.load(input), let pixels = src.linearPixels() else {
      FileHandle.standardError.write("cannot read input\n".data(using: .utf8)!)
      return 2
    }
    var values = EditModel.appDefaults()
    if let film { values["film"] = .int(film) }
    applyOverrides(&values)
    // SPEKTRALAB_DIAG=1: time the editor's open path, the old four separate decodes against
    // one proxy decode plus derived copies, and how far the derived copies drift.
    if ProcessInfo.processInfo.environment["SPEKTRALAB_DIAG"] != nil {
      let p = EditModel.proxyEdge, d = EditModel.draftEdge, th = EditModel.thumbEdge
      var t = CFAbsoluteTimeGetCurrent()
      let oldProxy = src.linearPixels(maxEdge: p), oldBefore = src.displayPixels(maxEdge: p)
      let oldThumb = src.linearPixels(maxEdge: th), oldDraft = src.linearPixels(maxEdge: d)
      let oldMs = (CFAbsoluteTimeGetCurrent() - t) * 1000
      t = CFAbsoluteTimeGetCurrent()
      let pv = src.previews(proxyEdge: p, draftEdge: d, thumbEdge: th)
      let newMs = (CFAbsoluteTimeGetCurrent() - t) * 1000
      func drift(_ a: PixelBuffer?, _ b: PixelBuffer?) -> String {
        guard let a, let b, a.width == b.width, a.height == b.height, a.bytesPerComponent == b.bytesPerComponent else { return "size mismatch" }
        var maxD: Float = 0, sum: Double = 0
        let n = a.width * a.height * 4
        for i in 0..<n where i % 4 != 3 {
          let x: Float, y: Float
          if a.bytesPerComponent == 4 { x = a.floats[i]; y = b.floats[i] } else {
            x = halfToFloat(a.data.assumingMemoryBound(to: UInt16.self)[i]); y = halfToFloat(b.data.assumingMemoryBound(to: UInt16.self)[i])
          }
          let e = abs(min(x, 1) - min(y, 1)); maxD = max(maxD, e); sum += Double(e)
        }
        return String(format: "max %.4f mean %.5f", maxD, sum / Double(n * 3 / 4))
      }
      print(String(format: "open path: 4 decodes %.0f ms -> 1 decode + derived %.0f ms", oldMs, newMs))
      print("  proxy \(drift(oldProxy, pv?.proxy)) | before \(drift(oldBefore, pv?.before)) | draft \(drift(oldDraft, pv?.draft)) | thumb \(drift(oldThumb, pv?.thumb))")
    }
    if ProcessInfo.processInfo.environment["SPEKTRALAB_DIAG"] != nil {
      let t = CFAbsoluteTimeGetCurrent()
      _ = EffectsProcessor.shared
      print(String(format: "effects shaders %.0f ms (%@)", (CFAbsoluteTimeGetCurrent() - t) * 1000,
                   Bundle.main.url(forResource: "Effects", withExtension: "metallib") != nil ? "precompiled" : "from source"))
    }
    let tInit = CFAbsoluteTimeGetCurrent()
    let engine = SpektraEngine()
    let initMs = (CFAbsoluteTimeGetCurrent() - tInit) * 1000
    let t0 = CFAbsoluteTimeGetCurrent()
    guard let out = RenderPipeline.render(
      engine, source: pixels, values: values, output: ColorSpaceIndex.proPhoto, bytesPerComponent: 4)
    else {
      FileHandle.standardError.write("render failed: \(engine.lastError)\n".data(using: .utf8)!)
      return 1
    }
    let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
    // SPEKTRALAB_DIAG=1: engine init time and the renderer's own breakdown of the first
    // (cold) call, a repeat with the same values (warm), a repeat with another film and one
    // back on the first film (its profile tables should come from the engine's cache).
    if ProcessInfo.processInfo.environment["SPEKTRALAB_DIAG"] != nil {
      func report(_ tag: String, _ ms: Double) {
        let d = engine.diagnostics
        print(String(
          format: "%@: %.0f ms | cpu setup %.1f, gpu %.1f, output copy %.1f ms | %u passes, scratch %.0f MB",
          tag, ms, d.cpuSetupMs, d.commandBufferMs, d.outputCopyMs, d.passCount, Double(d.scratchAllocationBytes) / 1e6))
      }
      print(String(format: "engine init %.0f ms", initMs))
      report("cold", ms)
      for (tag, v) in [("warm same values", values), ("other film", values.merging(["film": .int((values["film"]?.intValue ?? 0) + 1)]) { $1 }), ("first film again", values)] {
        let t = CFAbsoluteTimeGetCurrent()
        _ = RenderPipeline.render(engine, source: pixels, values: v, output: ColorSpaceIndex.proPhoto, bytesPerComponent: 4)
        report(tag, (CFAbsoluteTimeGetCurrent() - t) * 1000)
      }
      // Zoomed-in detail: a viewport-sized region must equal the same crop of the full render.
      let rw = min(1600, pixels.width), rh = min(1200, pixels.height)
      for (tag, x, y) in [("centre", (pixels.width - rw) / 2, (pixels.height - rh) / 2), ("odd offset", min(37, pixels.width - rw), min(53, pixels.height - rh)),
                          ("bottom right", pixels.width - rw, pixels.height - rh)] {
        let t = CFAbsoluteTimeGetCurrent()
        guard let r = RenderPipeline.render(
          engine, source: pixels, region: CGRect(x: x, y: y, width: rw, height: rh), values: values,
          output: ColorSpaceIndex.proPhoto, bytesPerComponent: 4)
        else { print("region \(tag): failed \(engine.lastError)"); continue }
        let ms = (CFAbsoluteTimeGetCurrent() - t) * 1000
        var maxDiff: Float = 0
        for row in 0..<rh {
          for i in 0..<(rw * 4) {
            maxDiff = max(maxDiff, abs(r.floats[row * rw * 4 + i] - out.floats[((y + row) * pixels.width + x) * 4 + i]))
          }
        }
        report(String(format: "region %@ %dx%d at %d,%d (max diff %.2g)", tag, rw, rh, x, y, maxDiff), ms)
      }
      // SPEKTRALAB_STALE=1: change one value, render a tile, change it back and render the tile
      // again on the same engine; it must equal the crop of the full render (no stale caches).
      if ProcessInfo.processInfo.environment["SPEKTRALAB_STALE"] != nil {
        let tw = min(2048, pixels.width), th = min(2048, pixels.height)
        let tile = CGRect(x: 0, y: 0, width: tw, height: th)
        for key in values.keys.sorted() {
          var v2 = values
          switch values[key] {
          case .double(let d)?: v2[key] = .double(d == 0 ? 0.5 : d * 1.7)
          case .bool(let b)?: v2[key] = .bool(!b)
          case .int(let i)?: if key == "film" || key == "paper" { continue }; v2[key] = .int(i + 1)
          default: continue
          }
          _ = RenderPipeline.render(engine, source: pixels, region: tile, values: v2, output: ColorSpaceIndex.proPhoto, bytesPerComponent: 4)
          guard let r = RenderPipeline.render(engine, source: pixels, region: tile, values: values, output: ColorSpaceIndex.proPhoto, bytesPerComponent: 4)
          else { print("stale \(key): failed"); continue }
          var maxDiff: Float = 0
          for row in 0..<th { for i in 0..<(tw * 4) { maxDiff = max(maxDiff, abs(r.floats[row * tw * 4 + i] - out.floats[(row * pixels.width) * 4 + i])) } }
          print(String(format: "stale %@: max diff %.2g", key, maxDiff))
        }
      }
      // SPEKTRALAB_TILES=1: the app's 2048 grid, cells of mixed sizes rendered in a row on one
      // engine with the shared pre effects, each against its crop of the full render.
      if ProcessInfo.processInfo.environment["SPEKTRALAB_TILES"] != nil {
        let pre = RenderPipeline.preEffects(pixels, values: values)
        for y in stride(from: 0, to: pixels.height, by: 2048) {
          for x in stride(from: 0, to: pixels.width, by: 2048) {
            let tw = min(2048, pixels.width - x), th = min(2048, pixels.height - y)
            guard let r = RenderPipeline.render(
              engine, source: pixels, region: CGRect(x: x, y: y, width: tw, height: th), values: values,
              output: ColorSpaceIndex.proPhoto, bytesPerComponent: 4, preApplied: pre)
            else { print("tile \(x),\(y): failed \(engine.lastError)"); continue }
            var maxDiff: Float = 0, sum: Double = 0
            for row in 0..<th {
              for i in 0..<(tw * 4) {
                let d = abs(r.floats[row * tw * 4 + i] - out.floats[((y + row) * pixels.width + x) * 4 + i])
                maxDiff = max(maxDiff, d); sum += Double(d)
              }
            }
            print(String(format: "tile %d,%d %dx%d: max diff %.2g mean %.2g", x, y, tw, th, maxDiff, sum / Double(tw * th * 4)))
          }
        }
      }
      // SPEKTRALAB_LEVELS=1: the same central patch at each detail scale and the proxy; grain
      // strength as the std of luma minus its 3×3 mean, and the mean level, per scale.
      if ProcessInfo.processInfo.environment["SPEKTRALAB_LEVELS"] != nil {
        let proxyScale = Double(EditModel.proxyEdge) / Double(max(pixels.width, pixels.height))
        for scale in [1.0, 0.5, 0.25, proxyScale] {
          let w = Int((Double(pixels.width) * scale).rounded()), h = Int((Double(pixels.height) * scale).rounded())
          guard let level = scale == 1 ? pixels : SourceImage.scaled(pixels, width: w, height: h) else { continue }
          let pw = Int(1600 * scale), ph = Int(1200 * scale)
          let region = CGRect(x: (w - pw) / 2, y: (h - ph) / 2, width: pw, height: ph)
          guard let r = RenderPipeline.render(
            engine, source: level, region: region, values: values, output: ColorSpaceIndex.proPhoto, bytesPerComponent: 4)
          else { print("level \(scale): failed \(engine.lastError)"); continue }
          var y = [Float](repeating: 0, count: pw * ph)
          for i in 0..<(pw * ph) { y[i] = 0.3 * r.floats[i * 4] + 0.6 * r.floats[i * 4 + 1] + 0.1 * r.floats[i * 4 + 2] }
          // Grain alone: the difference from the same patch without grain, at the level and box-averaged to 1/4.
          var plain = values
          plain["grainEnabled"] = .bool(false)
          if let r0 = RenderPipeline.render(engine, source: level, region: region, values: plain, output: ColorSpaceIndex.proPhoto, bytesPerComponent: 4) {
            var g = [Float](repeating: 0, count: pw * ph)
            for i in 0..<(pw * ph) { g[i] = y[i] - (0.3 * r0.floats[i * 4] + 0.6 * r0.floats[i * 4 + 1] + 0.1 * r0.floats[i * 4 + 2]) }
            func stats(_ a: [Float]) -> (Double, Double) {
              let m = a.reduce(0.0) { $0 + Double($1) } / Double(a.count)
              return (m, (a.reduce(0.0) { $0 + (Double($1) - m) * (Double($1) - m) } / Double(a.count)).squareRoot())
            }
            let (gm, gs) = stats(g)
            let f = max(1, Int((scale / 0.25).rounded()))
            let qw = pw / f, qh = ph / f
            var q = [Float](repeating: 0, count: qw * qh)
            for yy in 0..<(qh * f) { for xx in 0..<(qw * f) { q[(yy / f) * qw + xx / f] += g[yy * pw + xx] / Float(f * f) } }
            let (_, qs) = stats(q)
            print(String(format: "  grain: mean %+.4f std %.4f, at 1/4 std %.4f", gm, gs, qs))
          }
          var s: Double = 0, s2: Double = 0, m: Double = 0, n = 0
          for yy in 1..<(ph - 1) {
            for xx in 1..<(pw - 1) {
              var b: Float = 0
              for dy in -1...1 { for dx in -1...1 { b += y[(yy + dy) * pw + xx + dx] } }
              let d = Double(y[yy * pw + xx] - b / 9)
              s += d; s2 += d * d; m += Double(y[yy * pw + xx]); n += 1
            }
          }
          let mean = s / Double(n)
          print(String(format: "level %.3f %dx%d: hp std %.5f mean %.4f", scale, pw, ph, (s2 / Double(n) - mean * mean).squareRoot(), m / Double(n)))
          // The same patch box-averaged to 1/4 size, as the screen shows it when levels sit side by side.
          let f = Int((scale / 0.25).rounded())
          if f >= 1, abs(Double(f) * 0.25 - scale) < 1e-6 {
            let qw = pw / f, qh = ph / f
            var q = [Float](repeating: 0, count: qw * qh)
            for yy in 0..<(qh * f) { for xx in 0..<(qw * f) { q[(yy / f) * qw + xx / f] += y[yy * pw + xx] / Float(f * f) } }
            var qs: Double = 0, qs2: Double = 0, qm: Double = 0, qn = 0
            for yy in 1..<(qh - 1) {
              for xx in 1..<(qw - 1) {
                var b: Float = 0
                for dy in -1...1 { for dx in -1...1 { b += q[(yy + dy) * qw + xx + dx] } }
                let d = Double(q[yy * qw + xx] - b / 9)
                qs += d; qs2 += d * d; qm += Double(q[yy * qw + xx]); qn += 1
              }
            }
            let qmean = qs / Double(qn)
            print(String(format: "  at 1/4: hp std %.5f mean %.4f", (qs2 / Double(qn) - qmean * qmean).squareRoot(), qm / Double(qn)))
          }
        }
      }
      // Film browser sweep at thumbnail size, with and without the fine-detail stages.
      if let thumb = src.linearPixels(maxEdge: EditModel.thumbEdge) {
        let light: [String: ParamValue] = ["grainEnabled": .bool(false), "halationEnabled": .bool(false),
                                           "cameraDiffusionEnabled": .bool(false), "printDiffusionEnabled": .bool(false)]
        for (tag, extra) in [("thumbs full", [String: ParamValue]()), ("thumbs light", light)] {
          let t = CFAbsoluteTimeGetCurrent()
          for i in Catalog.films.indices {
            let o = PixelBuffer(width: thumb.width, height: thumb.height, bytesPerComponent: 2)
            var v = values.merging(extra) { $1 }
            v["film"] = .int(i)
            _ = engine.render(thumb, into: o, params: Catalog.renderParams(v, output: ColorSpaceIndex.displayP3))
          }
          print(String(format: "%@: %d films in %.0f ms", tag, Catalog.films.count, (CFAbsoluteTimeGetCurrent() - t) * 1000))
        }
      }
      // Preview while dragging: proxy vs draft size (warm, same film).
      for (tag, edge, grain) in [("preview proxy", EditModel.proxyEdge, true), ("preview draft", EditModel.draftEdge, false)] {
        guard let px = src.linearPixels(maxEdge: edge) else { continue }
        var v = values
        if !grain { v["grainEnabled"] = .bool(false) }
        _ = RenderPipeline.render(engine, source: px, values: v, output: ColorSpaceIndex.displayP3, bytesPerComponent: 2)
        let t = CFAbsoluteTimeGetCurrent()
        for _ in 0..<5 { _ = RenderPipeline.render(engine, source: px, values: v, output: ColorSpaceIndex.displayP3, bytesPerComponent: 2) }
        print(String(format: "%@ %dx%d: %.0f ms/frame", tag, px.width, px.height, (CFAbsoluteTimeGetCurrent() - t) * 1000 / 5))
      }
    }
    do { try TiffWriter.writeProPhoto16(out, to: output, properties: src.properties) } catch {
      FileHandle.standardError.write("\(error.localizedDescription)\n".data(using: .utf8)!)
      return 1
    }
    print(String(format: "rendered %dx%d in %.0f ms -> %@", pixels.width, pixels.height, ms, output.path))
    return 0
  }

  /// Values for batch/LUT runs: `--preset` name, else the last edit, else defaults, then `--set`.
  static func startValues() -> [String: ParamValue] {
    var values = launch.preset.flatMap(Presets.named).flatMap(Presets.load)
      ?? Presets.loadLast() ?? EditModel.appDefaults()
    if let film = launch.film { values["film"] = .int(film) }
    applyOverrides(&values)
    return values
  }

  static func batch(_ items: [BatchItem]) -> Int32 {
    let values = startValues()
    let engine = SpektraEngine()
    var failed: Int32 = 0
    for (i, item) in items.enumerated() {
      let t0 = CFAbsoluteTimeGetCurrent()
      do {
        try EditModel.renderFile(item, values: values, engine: engine)
        // Keep that photo's own snapshots and history; its current edit becomes the batch edit.
        Sessions.replaceValues(values, key: item.key, label: tr("여러 사진에 적용", "Batch Apply"))
        print(String(format: "[%d/%d] %.0f ms -> %@", i + 1, items.count, (CFAbsoluteTimeGetCurrent() - t0) * 1000, item.output.path))
      } catch {
        failed = 1
        FileHandle.standardError.write("[\(i + 1)/\(items.count)] \(item.input.path): \(error.localizedDescription)\n".data(using: .utf8)!)
      }
    }
    return failed
  }

  static func exportLut(to url: URL) -> Int32 {
    do {
      try LutExport.export(values: startValues(), to: url, title: launch.preset ?? url.deletingPathExtension().lastPathComponent)
      print("wrote \(url.path)")
      // With --input, also report how closely the LUT matches the engine on that photo.
      if let input = launch.input { print(try LutExport.verify(values: startValues(), image: input)) }
      return 0
    } catch {
      FileHandle.standardError.write("\(error.localizedDescription)\n".data(using: .utf8)!)
      return 1
    }
  }

  static func applyOverrides(_ values: inout [String: ParamValue]) {
    for (name, text) in launch.overrides {
      do { values[name] = try AgentCommands.parse(name, text) } catch let f as AgentCommands.Failure {
        FileHandle.standardError.write("--set ignored: \(f.message)\n".data(using: .utf8)!)
      } catch {}
    }
  }
}

/// Save panel + background bake for the LUT export.
enum LutPanel {
  static func run(values: [String: ParamValue], name: String?) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.init(filenameExtension: "cube") ?? .data]
    let title = name ?? FilmInfo.displayName(Catalog.films[safe: values["film"]?.intValue ?? 0] ?? "PhotoEmul")
    panel.nameFieldStringValue = title.replacingOccurrences(of: "/", with: "-") + ".cube"
    panel.message = tr("색 변환만 담깁니다 (그레인·할레이션·확산·샤픈·자동 노출 제외). ACR 프로파일 만들기에 쓸 수 있습니다.",
                       "Colour only (no grain, halation, diffusion, sharpening or auto exposure). Usable for an ACR/Lightroom profile.")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    DispatchQueue.global(qos: .userInitiated).async {
      do { try LutExport.export(values: values, to: url, title: title) } catch {
        DispatchQueue.main.async {
          let alert = NSAlert(error: error)
          alert.runModal()
        }
      }
    }
  }
}

struct ContentView: View {
  @Bindable var model: EditModel
  let canvas: CanvasState
  @AppStorage("pickerWidth") private var pickerWidth = 300.0
  @AppStorage("inspectorWidth") private var inspectorWidth = 320.0
  @AppStorage(HistoryTimeline.shownKey) private var timelineShown = true
  @AppStorage(Panels.recipeBarKey) private var recipeBarOpen = true
  @AppStorage(Panels.inspectorKey) private var inspectorOpen = true

  /// Widest each panel may be so the canvas keeps its 400 points: a narrower window takes the
  /// room from the picker first, then from the inspector, down to their minimum widths.
  private func panelWidths(_ total: Double) -> (picker: Double, inspector: Double) {
    let picker = model.pickerOpen ? min(max(pickerWidth, PickerPanel.widthRange.lowerBound), PickerPanel.widthRange.upperBound) : 0
    let inspector = inspectorOpen ? min(max(inspectorWidth, InspectorPane.widthRange.lowerBound), InspectorPane.widthRange.upperBound) : 0
    // Canvas minimum plus the two panel edges.
    var over = picker + inspector - (total - 400 - 2 * PanelEdge.panelSide)
    guard over > 0 else { return (.infinity, .infinity) }
    let fromPicker = model.pickerOpen ? min(over, picker - PickerPanel.widthRange.lowerBound) : 0
    over -= fromPicker
    return (picker - fromPicker, inspectorOpen ? inspector - max(over, 0) : 0)
  }

  var body: some View {
    VStack(spacing: 0) {
      if recipeBarOpen {
        RecipeBar(model: model)
        Divider()
      }
      GeometryReader { geo in
        let fit = panelWidths(geo.size.width)
      HStack(spacing: 0) {
        if model.pickerOpen {
          PickerPanel(model: model, maxWidth: fit.picker)
            .transition(.move(edge: .leading))
            // Above the canvas, so the edge's grab area reaches over it.
            .zIndex(1)
        }
        ZStack {
          CanvasView(model: model, state: canvas)
          overlays
          AgentBar(model: model)
          if model.standalone, model.inputURL == nil { emptyState }
          GeometryReader { g in
            Navigator(model: model, canvas: canvas, viewSize: g.size)
              .padding(14)
              .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
          }
          panelToggles
        }
        .frame(minWidth: 400, maxWidth: .infinity)
        if inspectorOpen {
          InspectorPane(model: model, maxWidth: fit.inspector)
            .transition(.move(edge: .trailing))
            .zIndex(1)
        }
      }
      .animation(.easeOut(duration: 0.18), value: model.pickerOpen)
      .animation(.easeOut(duration: 0.18), value: inspectorOpen)
      }
      Divider()
      if timelineShown {
        HistoryTimeline(model: model).zIndex(1)
        Divider()
      }
      StatusBar(model: model, canvas: canvas)
    }
    .toolbar { toolbarContent }
    .navigationTitle(model.source?.url.lastPathComponent ?? "PhotoEmul")
    .alert(tr("오류", "Error"), isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
      Button("OK") { model.errorMessage = nil }
    } message: {
      Text(model.errorMessage ?? "")
    }
    .background(KeyHandler(model: model, canvas: canvas))
    .background(CloseGuard())
    .onAppear { Snapshotter.shared.register(model: model, canvas: canvas) }
    .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
      guard model.standalone, let provider = providers.first else { return false }
      _ = provider.loadObject(ofClass: URL.self) { url, _ in
        if let url { DispatchQueue.main.async { model.open(url) } }
      }
      return true
    }
  }

  @State private var dropTargeted = false

  /// Lightroom's edge triangles: one at the middle of each canvas edge folds or unfolds the panel beyond it.
  private var panelToggles: some View {
    ZStack {
      PanelToggle(edge: .top, open: recipeBarOpen) { recipeBarOpen.toggle() }
      PanelToggle(edge: .bottom, open: timelineShown) { timelineShown.toggle() }
      PanelToggle(edge: .leading, open: model.pickerOpen) { model.pickerOpen.toggle() }
      PanelToggle(edge: .trailing, open: inspectorOpen) { inspectorOpen.toggle() }
    }
  }
  /// Read so the empty state repaints when the backdrop setting changes.
  @AppStorage(Appearance.backdropKey) private var backdrop = Backdrop.auto.rawValue

  /// Standalone launch without a photo.
  private var emptyState: some View {
    VStack(spacing: 14) {
      Image(systemName: "photo.on.rectangle.angled").font(.system(size: 56, weight: .light)).foregroundStyle(.secondary)
      Text(tr("사진을 열거나 여기에 끌어다 놓으세요", "Open a photo or drop it here")).font(.title3)
      Text(tr("RAW · TIFF · JPEG · HEIC · PNG", "RAW · TIFF · JPEG · HEIC · PNG")).font(.caption).foregroundStyle(.secondary)
      Button { model.showOpenPanel() } label: { Label(tr("사진 열기…", "Open Photo…"), systemImage: "folder") }
        .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut("o")
    }
    .padding(40)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(nsColor: Appearance.canvasColor))
    .id(backdrop)
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 3, dash: [10, 6]))
      .padding(16).opacity(dropTargeted ? 1 : 0))
  }

  @AppStorage(OSD.infoOnKey) private var osdInfoOn = false
  @AppStorage(OSD.opacityKey) private var osdOpacity = OSD.defaultOpacity
  @AppStorage(SoftProof.onKey) private var softProof = false
  @AppStorage(SoftProof.targetKey) private var softProofTarget = "srgb"
  @AppStorage(SoftProof.iccKey) private var softProofICC = ""

  private var recipeText: String {
    "\(FilmInfo.displayName(Catalog.films[safe: model.value("film").intValue] ?? "")) → \(FilmInfo.displayName(Catalog.papers[safe: model.value("paper").intValue] ?? ""))"
  }

  private var currentTag: some View {
    Tag(text: model.hoverLabel.map { tr("미리보기 · ", "Preview · ") + $0 } ?? tr("현재", "Current"))
  }

  @ViewBuilder private var overlays: some View {
    if let job = model.detailJob, !job.loading, !job.finished, !job.quiet, model.wantsDetail, !model.showBefore,
       !model.compareMode.isSideBySide, job.done < job.cells.count {
      TileFocus(cell: job.cells[job.done], canvas: canvas, sourceSize: model.source.map { CGSize(width: $0.width, height: $0.height) } ?? .zero)
        .id(job.done)
        .opacity(osdOpacity)
    }
    VStack {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 6) {
        if model.showBefore {
          Tag(text: tr("원본", "Before"))
        } else if let name = model.hoverLabel, let next = model.hoverPendingLabel, model.compareMode == .off {
          Tag(text: tr("미리보기 · \(name) → \(next) 불러오는 중", "Preview · \(name) → loading \(next)"))
        } else if let name = model.hoverLabel, model.compareMode == .off {
          Tag(text: tr("미리보기 · ", "Preview · ") + name)
        } else if model.compareMode != .off {
          Tag(text: model.compareLabel)
        }
        if softProof, model.source != nil {
          // Read so the tag follows the target; the name comes from the same settings.
          let _ = (softProofTarget, softProofICC)
          Tag(text: tr("소프트 프루프 · ", "Soft Proof · ") + SoftProof.name)
        }
        if osdInfoOn, let source = model.source {
          PhotoInfoBox(source: source, recipe: recipeText, zoom: canvas.effectiveZoom)
        }
        }
        Spacer()
        if !model.showBefore, model.compareMode != .off, !model.compareMode.isStacked { currentTag }
        RenderPill(job: model.wantsDetail ? model.detailJob.flatMap { $0.quiet ? nil : $0 } : nil, previewBusy: model.previewBusy && model.preview != nil)
      }
      .opacity(osdOpacity)
      Spacer()
      // Top/bottom views: the current image is the lower part.
      if !model.showBefore, model.compareMode.isStacked {
        HStack { currentTag; Spacer() }.opacity(osdOpacity)
      }
    }
    .padding(10)
    if model.saving || (model.preview == nil && model.inputURL != nil && model.errorMessage == nil) {
      VStack(spacing: 10) {
        ProgressView()
        Text(model.statusText.isEmpty ? tr("렌더링 중…", "Rendering…") : model.statusText)
      }
      .padding(20)
      .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
  }

  @ToolbarContentBuilder private var toolbarContent: some ToolbarContent {
    ToolbarItemGroup(placement: .navigation) {
      if model.standalone {
        Button { model.showOpenPanel() } label: { Label(tr("열기", "Open"), systemImage: "folder") }
          .labelStyle(.titleAndIcon).help(tr("사진 열기", "Open photo") + " ⌘O")
      } else {
        Button(tr("취소", "Cancel")) { model.cancel() }.help(tr("저장하지 않고 닫기", "Close without saving"))
      }
    }
    ToolbarItemGroup(placement: .principal) {
      Button { model.undo() } label: { Image(systemName: "arrow.uturn.backward") }
        .disabled(model.undoStack.isEmpty).help(tr("실행 취소", "Undo") + " ⌘Z")
      Button { model.redo() } label: { Image(systemName: "arrow.uturn.forward") }
        .disabled(model.redoStack.isEmpty).help(tr("다시 실행", "Redo") + " ⇧⌘Z")
      Divider()
      Picker(tr("확대", "Zoom"), selection: Binding(
        get: {
          guard let z = canvas.zoom else { return 0 }
          return canvas.fill ? 3 : z == 1 ? 1 : z == 2 ? 2 : -1
        },
        set: { $0 == 3 ? canvas.chooseFill() : canvas.choose($0 == 0 ? nil : Double($0)) })) {
        Text(tr("맞춤", "Fit")).tag(0)
        Text(tr("채움", "Fill")).tag(3)
        Text("100%").tag(1)
        Text("200%").tag(2)
        if let z = canvas.zoom, z != 1, z != 2, !canvas.fill { Text("\(Int((z * 100).rounded()))%").tag(-1) }
      }
      .pickerStyle(.segmented)
      .help(tr("클릭 · Z: 맞춤 ↔ 확대, 누른 채 끌기: 잠깐 확대, ⌘+ / ⌘−: 단계", "Click · Z: Fit ↔ zoom, press and drag: peek, ⌘+ / ⌘−: steps"))
      Button { model.showHistory.toggle() } label: { Image(systemName: "camera.on.rectangle") }
        .help(tr("스냅샷", "Snapshots") + " ⌥⌘S")
        .popover(isPresented: $model.showHistory, arrowEdge: .bottom) {
          HistoryList(model: model).frame(width: 300, height: 440)
        }
      Toggle(isOn: $model.showBefore) { Image(systemName: "eye") }
        .help(tr("원본 보기", "Show original") + " (\\)")
      CompareTools(mode: model.compareMode, lastSplit: model.lastSplit, lastSideBySide: model.lastSideBySide) {
        model.compareMode = $0
      }
      .fixedSize()
      Menu {
        Button(tr("원본", "Original")) { model.compareBase = .original }
        if !model.snapshots.isEmpty {
          Section(tr("스냅샷", "Snapshots")) {
            ForEach(model.snapshots) { s in Button(s.name) { model.compareBase = .snapshot(s.id) } }
          }
        }
        if case .film(let i) = model.compareBase {
          Section(tr("필름", "Film")) { Text(FilmInfo.displayName(Catalog.films[safe: i] ?? "")) }
        }
      } label: {
        Text(tr("기준: ", "Base: ") + model.compareLabel)
      }
      .fixedSize()
      .disabled(model.compareMode == .off)
      .help(tr("비교 기준. 필름 목록에서 우클릭 → 이 필름과 비교", "Compare base. Right-click a film → Compare with this film"))
    }
    ToolbarItemGroup(placement: .primaryAction) {
      Button { model.save() } label: {
        if model.standalone {
          Label(tr("내보내기…", "Export…"), systemImage: "square.and.arrow.up")
        } else {
          Label(tr("Lightroom에 저장", "Save to Lightroom"), systemImage: "square.and.arrow.down")
        }
      }
        .labelStyle(.titleAndIcon).buttonStyle(.borderedProminent)
        .disabled(model.source == nil || model.saving).help("⌘S")
    }
  }
}

/// Top-right progress for full-resolution tiles (with a map of them) and slow previews.
struct RenderPill: View {
  let job: DetailJob?
  let previewBusy: Bool
  @AppStorage(OSD.backgroundKey) private var background = OSD.defaultBackground
  /// Previews show the pill only once they take longer than a moment, so quick ones do not flash it.
  @State private var slowPreview = false

  var body: some View {
    Group {
      if let job {
        HStack(spacing: 10) {
          TileMap(job: job)
          VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 7) {
              indicator(done: job.finished)
              Text(job.finished ? tr("완료", "Done") : job.loading ? tr("원본 불러오는 중", "Loading original")
                : tr("선명하게 만드는 중", "Sharpening view"))
              Spacer(minLength: 10)
              Text("\(min(job.done, job.cells.count)) / \(job.cells.count)").font(.caption.monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
            }
            ProgressView(value: Double(min(job.done, job.cells.count)), total: Double(max(job.cells.count, 1)))
              .progressViewStyle(.linear).tint(job.finished ? .green : .accentColor).controlSize(.mini)
          }
          .frame(width: 170)
        }
      } else if slowPreview {
        HStack(spacing: 7) {
          indicator(done: false)
          Text(tr("미리보기 계산 중", "Updating preview"))
        }
      }
    }
    .font(.caption.weight(.semibold))
    .foregroundStyle(.white)
    .padding(.horizontal, 12).padding(.vertical, 8)
    .shadow(color: .black.opacity(background < 0.3 ? 0.8 : 0), radius: 1.5)
    .background(.black.opacity(min(background + 0.1, 1)), in: RoundedRectangle(cornerRadius: 11))
    .shadow(color: .black.opacity(0.3 * background), radius: 8, y: 3)
    .opacity(job != nil || slowPreview ? 1 : 0)
    .animation(.easeOut(duration: 0.3), value: job == nil && !slowPreview)
    .task(id: previewBusy) {
      if previewBusy { try? await Task.sleep(for: .milliseconds(350)) }
      if !Task.isCancelled { slowPreview = previewBusy }
    }
  }

  @ViewBuilder private func indicator(done: Bool) -> some View {
    if done {
      Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
    } else {
      ProgressView().controlSize(.mini).colorScheme(.dark)
    }
  }
}

/// The tiles of a batch laid out as they sit in the photo: white when done, blue for the one in
/// progress, green when all are done.
struct TileMap: View {
  let job: DetailJob
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var pulse = false

  var body: some View {
    let box = job.cells.reduce(job.cells.first ?? .zero) { $0.union($1) }
    let maxSide: CGFloat = 38
    let k = box.isEmpty ? 1 : min(maxSide / box.width, maxSide * 0.8 / box.height)
    ZStack(alignment: .topLeading) {
      ForEach(Array(job.cells.enumerated()), id: \.offset) { i, cell in
        let current = !job.finished && !job.loading && i == job.done
        RoundedRectangle(cornerRadius: 1.5)
          .fill(job.finished ? Color.green : i < job.done ? Color.white.opacity(0.9) : current ? Color.accentColor : Color.white.opacity(0.15))
          .opacity(current && pulse ? 0.35 : 1)
          .frame(width: max(cell.width * k - 2, 2), height: max(cell.height * k - 2, 2))
          .offset(x: (cell.minX - box.minX) * k + 1, y: (cell.minY - box.minY) * k + 1)
      }
    }
    .frame(width: box.width * k, height: box.height * k, alignment: .topLeading)
    .onAppear {
      guard !reduceMotion else { return }
      withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) { pulse = true }
    }
  }
}

/// Thin blinking corner marks on the tile being rendered, over the photo.
struct TileFocus: View {
  let cell: CGRect
  let canvas: CanvasState
  let sourceSize: CGSize
  @Environment(\.displayScale) private var displayScale
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var dim = false

  var body: some View {
    GeometryReader { geo in
      // Same placement as the canvas renderer, in points with y down.
      let z = canvas.effectiveZoom / max(displayScale, 1)
      let w = sourceSize.width * z, h = sourceSize.height * z
      let cx = w <= geo.size.width ? 0.5 : canvas.center.x
      let cy = h <= geo.size.height ? 0.5 : canvas.center.y
      let x0 = geo.size.width / 2 - cx * w, y0 = geo.size.height / 2 - cy * h
      // Only the part of the tile that is on screen: tiles reach past the photo and the view edges.
      let shown = CGRect(x: x0, y: y0, width: w, height: h).intersection(CGRect(origin: .zero, size: geo.size))
      let r = CGRect(x: x0 + cell.minX * z, y: y0 + cell.minY * z, width: cell.width * z, height: cell.height * z)
        .intersection(shown).insetBy(dx: 3, dy: 3)
      let l = r.isNull ? 0 : min(18, r.width / 3, r.height / 3)
      Path { p in
        guard l > 1 else { return }
        p.move(to: CGPoint(x: r.minX, y: r.minY + l)); p.addLine(to: CGPoint(x: r.minX, y: r.minY)); p.addLine(to: CGPoint(x: r.minX + l, y: r.minY))
        p.move(to: CGPoint(x: r.maxX - l, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY)); p.addLine(to: CGPoint(x: r.maxX, y: r.minY + l))
        p.move(to: CGPoint(x: r.maxX, y: r.maxY - l)); p.addLine(to: CGPoint(x: r.maxX, y: r.maxY)); p.addLine(to: CGPoint(x: r.maxX - l, y: r.maxY))
        p.move(to: CGPoint(x: r.minX + l, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY)); p.addLine(to: CGPoint(x: r.minX, y: r.maxY - l))
      }
      .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
      .shadow(color: .black.opacity(0.5), radius: 1)
      .opacity(dim ? 0.3 : 0.9)
    }
    .clipped()
    .allowsHitTesting(false)
    .onAppear {
      guard !reduceMotion else { return }
      withAnimation(.easeInOut(duration: 0.45).repeatForever(autoreverses: true)) { dim = true }
    }
  }
}

struct Tag: View {
  let text: String
  @AppStorage(OSD.backgroundKey) private var background = OSD.defaultBackground
  var body: some View {
    Text(text).font(.caption.bold()).padding(.horizontal, 8).padding(.vertical, 4)
      .shadow(color: .black.opacity(background < 0.3 ? 0.8 : 0), radius: 1.5)
      .background(.black.opacity(background), in: Capsule()).foregroundStyle(.white)
  }
}

/// While an AI request runs: what it is doing, and Apply / Discard (Esc) once it is done.
struct AgentBar: View {
  let model: EditModel
  private let agent = AgentSession.shared
  /// Step shown before the press-and-hold compare began.
  @State private var held: Int?

  var body: some View {
    if agent.active {
      VStack {
        HStack(spacing: 10) {
          Text(agent.finished
               ? tr("✦ AI 작업 끝 · \(agent.request) · \(agent.steps.count)단계", "✦ AI done · \(agent.request) · \(agent.steps.count) steps")
               : tr("✦ AI 조작 중 · 내 편집은 계속할 수 있습니다", "✦ AI at work · you can keep editing"))
            .font(.caption.bold())
          if agent.finished {
            Menu(tr("적용", "Apply")) {
              Button(tr("여기까지 적용 (#\(agent.at))", "Apply Up to Here (#\(agent.at))")) { agent.apply(model, ask: true, pick: .upTo) }
              Button(tr("고른 단계만 적용", "Apply Ticked Steps Only")) { agent.apply(model, ask: true, pick: .picked) }
              Button(tr("전부 적용", "Apply All")) { agent.apply(model, ask: true) }
              Divider()
              Button(tr("스냅샷으로 보관", "Keep as Snapshot")) { agent.keepAsSnapshot(model) }
              Button(tr("프리셋으로 저장", "Save as Preset")) { agent.saveAsPreset() }
              Button(tr("레슨 저장 (Markdown)…", "Save Lesson (Markdown)…")) { agent.saveLesson() }
            } primaryAction: { agent.apply(model, ask: true, pick: .upTo) }
              .fixedSize()
              .help(tr("누르면 지금 보이는 단계까지 적용, ▾에서 다른 방법", "Click applies up to the step shown; ▾ for other ways"))
          }
          Button(agent.finished ? tr("버리기", "Discard") : tr("중지", "Stop")) { agent.end(model) }
            .keyboardShortcut(.cancelAction)
            .help(tr("AI 작업본을 버립니다 (Esc). 내 히스토리는 그대로입니다.", "Drops the AI draft (Esc). Your history stays as it is."))
        }
        .controlSize(.small)
        .padding(.horizontal, 10).padding(.vertical, 5)
        .background(Capsule().fill(.black.opacity(0.75)))
        .overlay(Capsule().strokeBorder(.orange, lineWidth: 1.5))
        .foregroundStyle(.white)
        // The capsule is always dark; in light mode the Apply menu's label was dark on dark.
        .environment(\.colorScheme, .dark)
        .padding(.top, 10)
        if agent.finished, !agent.steps.isEmpty { review }
        Spacer()
      }
    }
  }
}

extension AgentBar {
  /// Step list to go back and forth through: values, the agent's reason, a tick for "ticked only".
  private var review: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Button { agent.show(model, agent.at - 1) } label: { Image(systemName: "chevron.left") }
          .keyboardShortcut(.leftArrow, modifiers: []).disabled(agent.at == 0)
        Text(agent.at == 0 ? tr("요청 전", "Before") : "#\(agent.at) / \(agent.steps.count)").monospacedDigit()
        Button { agent.show(model, agent.at + 1) } label: { Image(systemName: "chevron.right") }
          .keyboardShortcut(.rightArrow, modifiers: []).disabled(agent.at == agent.steps.count)
        Image(systemName: "square.on.square")
          .foregroundStyle(agent.at == 0 ? .secondary : .primary)
          .onLongPressGesture(minimumDuration: .infinity, pressing: { down in
            if down, held == nil, agent.at > 0 { held = agent.at; agent.show(model, agent.at - 1) }
            if !down, let h = held { agent.show(model, h); held = nil }
          }, perform: {})
          .help(tr("누르고 있으면 이전 단계를 봅니다", "Hold to see the step before"))
        Spacer()
        Text(tr("←→ 단계 이동 · 클릭: 그 단계 보기", "←→ steps · click a step to show it")).foregroundStyle(.secondary)
      }
      .font(.caption)
      let leaning = agent.leaning()
      ScrollView {
        VStack(alignment: .leading, spacing: 2) {
          // Each row holds its own step: applying empties `steps` while old rows can still update.
          ForEach(Array(agent.steps.enumerated()), id: \.offset) { i, step in
            HStack(alignment: .top, spacing: 6) {
              Toggle("", isOn: Binding(get: { !agent.skipped.contains(i) }, set: { agent.setSkipped(i, !$0) }))
                .labelsHidden().toggleStyle(.checkbox)
              VStack(alignment: .leading, spacing: 1) {
                Text("#\(i + 1) " + step.label).font(.caption.bold())
                Text(StepChanges.lines(from: agent.state(i), to: agent.state(i + 1)).joined(separator: "\n"))
                  .font(.caption2).foregroundStyle(.secondary)
                if let note = step.note {
                  Text(tr("왜: ", "Why: ") + note).font(.caption2).italic()
                }
                if let i = leaning[i] {
                  Text(tr("⚠ 건너뛴 #\(i + 1) 뒤에 맞춘 단계입니다", "⚠ Tuned after skipped #\(i + 1)"))
                    .font(.caption2).foregroundStyle(.orange)
                }
              }
              Spacer(minLength: 0)
            }
            .padding(4)
            .background(RoundedRectangle(cornerRadius: 5).fill(i == agent.at - 1 ? Color.orange.opacity(0.3) : .clear))
            .opacity(i < agent.at ? 1 : 0.5)
            .contentShape(Rectangle())
            .onTapGesture { agent.show(model, i + 1) }
          }
        }
      }
      .frame(maxHeight: 260)
    }
    .padding(10)
    .frame(width: 340)
    .background(RoundedRectangle(cornerRadius: 10).fill(.black.opacity(0.8)))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.orange.opacity(0.6)))
    .foregroundStyle(.white)
  }
}

struct StatusBar: View {
  @Bindable var model: EditModel
  let canvas: CanvasState

  var body: some View {
    HStack(spacing: 16) {
      Text(model.renderMs > 0 ? String(format: "GPU %.0f ms", model.renderMs) : "GPU – ms")
        .monospacedDigit()
        .help(tr("최근 미리보기 렌더 시간(중앙값)", "Typical preview render time (median of recent renders)"))
      if let s = model.source {
        Text("\(s.width)×\(s.height) · " + (model.standalone ? model.exportFormat.title : "ProPhoto 16-bit " + tr("출력", "output")))
      }
      Text("\(FilmInfo.displayName(Catalog.films[safe: model.value("film").intValue] ?? "")) → \(FilmInfo.displayName(Catalog.papers[safe: model.value("paper").intValue] ?? ""))")
      Text("\(Int((canvas.effectiveZoom * 100).rounded()))%")
      if model.resumed {
        Label(tr("이전 편집을 이어서 합니다", "Resumed previous edit"), systemImage: "clock.arrow.circlepath")
          .foregroundStyle(.secondary)
      }
      ProbeView(probe: canvas.probe)
      if let notice = model.notice {
        Button {
          if let url = model.lastExport { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        } label: { Label(notice, systemImage: "checkmark.circle.fill") }
          .buttonStyle(.link).help(tr("Finder에서 보기", "Show in Finder"))
      }
      Spacer()
      Text(model.standalone
        ? tr("\\ 원본 · Y 비교 · ←→ 필름 · ⌘Z 실행취소 · ⌘O 열기 · ⌘S 내보내기", "\\ before · Y compare · ←→ film · ⌘Z undo · ⌘O open · ⌘S export")
        : tr("\\ 원본 · Y 비교 · ←→ 필름 · ⌘Z 실행취소 · ⌘S 저장", "\\ before · Y compare · ←→ film · ⌘Z undo · ⌘S save")).foregroundStyle(.secondary)
        .layoutPriority(-1)  // the hint gives way first
    }
    .lineLimit(1)  // one line always: a second line would shrink the canvas and re-fit the photo when the probe readout appears
    .font(.caption.monospacedDigit())
    .padding(.horizontal, 12).padding(.vertical, 5)
  }
}

/// Colour picker readout: Display P3 0-255 under the cursor.
struct ProbeView: View {
  let probe: ProbeState

  var body: some View {
    if let r = probe.reading {
      HStack(spacing: 6) {
        RoundedRectangle(cornerRadius: 2)
          .fill(Color(.displayP3, red: r.rgb[0], green: r.rgb[1], blue: r.rgb[2]))
          .frame(width: 12, height: 12)
          .overlay(RoundedRectangle(cornerRadius: 2).stroke(.secondary.opacity(0.5)))
        Text(String(format: "R %3d  G %3d  B %3d", Self.byte(r.rgb[0]), Self.byte(r.rgb[1]), Self.byte(r.rgb[2])))
        Text("(\(r.x), \(r.y))").foregroundStyle(.secondary)
      }
      .help("Display P3")
    }
  }

  static func byte(_ v: Double) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
}

/// Closing the main window quits the app anyway; doing it through terminate lets
/// applicationShouldTerminate ask before the window is gone.
struct CloseGuard: NSViewRepresentable {
  final class View: NSView {
    override func viewDidMoveToWindow() {
      guard let button = window?.standardWindowButton(.closeButton) else { return }
      button.target = self
      button.action = #selector(quit)
    }
    @objc func quit() { NSApp.terminate(nil) }
  }
  func makeNSView(context: Context) -> NSView { View() }
  func updateNSView(_ nsView: NSView, context: Context) {}
}

/// App-wide single-key shortcuts that SwiftUI menus do not cover.
struct KeyHandler: NSViewRepresentable {
  let model: EditModel
  let canvas: CanvasState

  func makeNSView(context: Context) -> NSView {
    let v = NSView()
    context.coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak v] event in
      // Only the editor window: Settings lists and the open panel keep their arrow keys.
      guard let v, event.window === v.window else { return event }
      // Leave typing in text fields alone.
      if NSApp.keyWindow?.firstResponder is NSTextView { return event }
      // Panels like Lightroom: F5 top, F6 bottom, F7 left, F8 right; Tab both sides, ⇧Tab all.
      let bare = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.function, .numericPad])
      switch event.keyCode {
      case 96 where bare.isEmpty: Panels.flip(Panels.recipeBarKey); return nil
      case 97 where bare.isEmpty: Panels.flip(HistoryTimeline.shownKey); return nil
      case 98 where bare.isEmpty: model.pickerOpen.toggle(); return nil
      case 100 where bare.isEmpty: Panels.flip(Panels.inspectorKey); return nil
      case 48 where bare.subtracting(.shift).isEmpty:
        bare.contains(.shift) ? Panels.all(model) : Panels.sides(model); return nil
      default: break
      }
      switch event.charactersIgnoringModifiers {
      case "\\": model.showBefore.toggle(); return nil
      case "y", "Y":
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        // Like Lightroom: Y side by side, ⇧Y split, each in the orientation used last; ⌥Y turns the view 90°.
        guard flags.subtracting(.shift).isEmpty || flags == .option else { return event }
        if flags == .option { model.compareMode = model.compareMode.rotated; return nil }
        let target = flags.contains(.shift) ? model.lastSplit : model.lastSideBySide
        model.compareMode = model.compareMode == target ? .off : target
        return nil
      case "z" where event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty:
        canvas.toggle(); return nil
      case "i" where event.modifierFlags.intersection(.deviceIndependentFlagsMask).isEmpty:
        // Like Lightroom's I: photo info on and off.
        UserDefaults.standard.set(!UserDefaults.standard.bool(forKey: OSD.infoOnKey), forKey: OSD.infoOnKey)
        return nil
      default: break
      }
      // ← → previous/next film, ⇧← ⇧→ paper; ⌥← ⌥→ one history step, ⌥⌘← ⌥⌘→ first/last.
      if event.keyCode == 123 || event.keyCode == 124 {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.numericPad, .function])
        let forward = event.keyCode == 124
        if flags == .option { forward ? model.redo() : model.undo(); return nil }
        if flags == [.option, .command] { model.moveHistory(to: forward ? model.historyCount : 0); return nil }
        guard flags.subtracting(.shift).isEmpty else { return event }
        model.stepStock(film: !flags.contains(.shift), by: event.keyCode == 124 ? 1 : -1)
        return nil
      }
      return event
    }
    return v
  }

  func updateNSView(_ nsView: NSView, context: Context) {}
  func makeCoordinator() -> Coordinator { Coordinator() }

  final class Coordinator {
    var monitor: Any?
    deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
  }
}

/// App appearance: follow the system, or force dark or light.
enum Appearance: String, CaseIterable, Identifiable {
  case system, dark, light
  static let key = "appearance"
  static let backdropKey = "canvasBackdrop"
  static let marginKey = "canvasMargin"
  static let marginSizeKey = "canvasMarginSize"
  static let defaultMarginSize = 24.0
  static let marginSizes = 4.0...120.0

  /// Space (points) kept free around the photo in Fit and Fill; other zoom levels show it once
  /// panning reaches the photo's edge.
  static var canvasMargin: Double {
    let d = UserDefaults.standard
    guard d.object(forKey: marginKey) == nil || d.bool(forKey: marginKey) else { return 0 }
    let size = d.object(forKey: marginSizeKey) == nil ? defaultMarginSize : d.double(forKey: marginSizeKey)
    return min(max(size, marginSizes.lowerBound), marginSizes.upperBound)
  }
  var id: String { rawValue }
  var title: String {
    switch self {
    case .system: return tr("시스템", "System")
    case .dark: return tr("다크", "Dark")
    case .light: return tr("라이트", "Light")
    }
  }

  static func apply(_ raw: String) {
    switch Appearance(rawValue: raw) ?? .system {
    case .system: NSApp.appearance = nil
    case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
    case .light: NSApp.appearance = NSAppearance(named: .aqua)
    }
  }

  /// Canvas surround: by default near-black in dark mode, a neutral mid-grey in light mode
  /// (a white surround would make every photo look darker than it is); Settings can fix it.
  static var canvasColor: NSColor {
    let backdrop = Backdrop(rawValue: UserDefaults.standard.string(forKey: backdropKey) ?? "") ?? .auto
    if let grey = backdrop.grey { return NSColor(srgbRed: grey, green: grey, blue: grey, alpha: 1) }
    return NSColor(name: nil) { a in
      a.bestMatch(from: [.darkAqua, .aqua]) == .aqua
        ? NSColor(srgbRed: 0.81, green: 0.808, blue: 0.796, alpha: 1)
        : NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
    }
  }
}

/// Settings › General › Photo backdrop.
enum Backdrop: String, CaseIterable, Identifiable {
  case auto, black, dark, grey, light, white
  var id: String { rawValue }
  var title: String {
    switch self {
    case .auto: return tr("모양에 맞춤", "Match Appearance")
    case .black: return tr("검정", "Black")
    case .dark: return tr("어두운 회색", "Dark Grey")
    case .grey: return tr("중간 회색 (18%)", "Middle Grey (18%)")
    case .light: return tr("밝은 회색", "Light Grey")
    case .white: return tr("흰색", "White")
    }
  }
  /// sRGB grey level; nil follows the appearance.
  var grey: Double? {
    switch self {
    case .auto: return nil
    case .black: return 0
    case .dark: return 0.2
    case .grey: return 0.46
    case .light: return 0.75
    case .white: return 1
    }
  }
}

/// Film → paper → preset at a glance; clicking a pick opens the docked picker on that tab.
struct RecipeBar: View {
  @Bindable var model: EditModel

  private var film: Int { model.value("film").intValue }
  private var paper: Int { model.value("paper").intValue }
  private var filmName: String { Catalog.films[safe: film] ?? "" }

  private func toggle(_ tab: SidebarTab) {
    if model.pickerOpen && model.sidebarTab == tab {
      model.pickerOpen = false
    } else {
      model.sidebarTab = tab
      model.pickerOpen = true
    }
  }

  private func active(_ tab: SidebarTab) -> Bool { model.pickerOpen && model.sidebarTab == tab }

  var body: some View {
    HStack(spacing: 6) {
      Button { model.pickerOpen.toggle() } label: { Image(systemName: "sidebar.left") }
        .buttonStyle(.borderless).help(tr("재료 패널", "Stock panel") + " ⌘1")
      RecipePick(caption: tr("필름", "Film"), name: FilmInfo.displayName(filmName),
                 thumb: model.filmThumbs[film], symbol: "film", active: active(.film)) { toggle(.film) }
      Image(systemName: "arrow.right").font(.caption).foregroundStyle(.tertiary)
      RecipePick(caption: tr("인화지", "Paper"), name: FilmInfo.displayName(Catalog.papers[safe: paper] ?? ""),
                 thumb: model.paperThumbs[paper], symbol: "doc.richtext", active: active(.paper)) { toggle(.paper) }
      Image(systemName: "plus").font(.caption).foregroundStyle(.tertiary)
      RecipePick(caption: tr("프리셋", "Preset"), name: model.presetName ?? "—",
                 thumb: nil, symbol: "slider.horizontal.3", active: active(.preset)) { toggle(.preset) }
      Button { toggle(.ai) } label: { Image(systemName: "sparkles").foregroundStyle(active(.ai) ? Color.accentColor : .secondary) }
        .buttonStyle(.borderless).help(tr("AI 대화", "AI Chat"))
      Spacer(minLength: 12)
      Text(meta).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
    }
    .padding(.horizontal, 10).padding(.vertical, 5)
  }

  private var meta: String {
    var parts = [FilmInfo.category(filmName).title]
    if let s = model.source { parts.append("\(s.width)×\(s.height)") }
    parts.append(tr("←→ 필름 · ⇧←→ 인화지", "←→ film · ⇧←→ paper"))
    return parts.joined(separator: " · ")
  }
}

struct RecipePick: View {
  let caption: String
  let name: String
  let thumb: CGImage?
  let symbol: String
  let active: Bool
  let action: () -> Void
  @State private var hover = false

  var body: some View {
    Button(action: action) {
      HStack(spacing: 7) {
        ZStack {
          RoundedRectangle(cornerRadius: 3).fill(Color.primary.opacity(0.08))
          if let thumb {
            Image(decorative: thumb, scale: 1).resizable().aspectRatio(contentMode: .fill)
          } else {
            Image(systemName: symbol).font(.caption).foregroundStyle(.secondary)
          }
        }
        .frame(width: 36, height: 24).clipShape(RoundedRectangle(cornerRadius: 3))
        VStack(alignment: .leading, spacing: 0) {
          Text(caption).font(.caption2).foregroundStyle(.secondary)
          Text(name).font(.callout.weight(.medium)).lineLimit(1)
        }
        Image(systemName: "chevron.down").font(.caption2).foregroundStyle(.tertiary)
          .rotationEffect(.degrees(active ? 180 : 0))
      }
      .padding(.leading, 4).padding(.trailing, 8).padding(.vertical, 3)
      .background(RoundedRectangle(cornerRadius: 6).fill(
        active ? Color.accentColor.opacity(0.18) : hover ? Color.primary.opacity(0.06) : .clear))
      .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(active ? Color.accentColor.opacity(0.6) : .clear))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { hover = $0 }
    .help(active ? tr("클릭: 패널 닫기", "Click: close panel") : tr("클릭: 고르기", "Click: choose"))
  }
}

