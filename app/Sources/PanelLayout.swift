// PhotoEmul - native editor for spektrafilm (GPL-3.0-or-later)
// Right-panel layouts: how the modules are grouped and ordered, as JSON files users can swap.
// Built-ins: "Default" (the module list) and "Process Order" (film > capture > develop > print > scan > finish).

#if canImport(AppKit)
import AppKit  // the save / open panels and the settings views below; the layout model and built-ins also build for the iPad probe
#endif
import SwiftUI
import UniformTypeIdentifiers

/// A right-panel layout file. Only grouping and order: values live in the edit session either way.
struct PanelLayout: Codable {
  static let currentFormat = 1

  var format = PanelLayout.currentFormat
  var name: String
  var stages: [Stage]

  struct Stage: Codable {
    var id: String
    /// No title: the panels show without a stage header (the default layout).
    var title: String?
    var hint: String?
    /// "#rrggbb", the bar beside the stage.
    var color: String?
    var panels: [Panel]
  }

  /// One card: a built-in module (`module`) or a hand-picked list of params (`params`).
  struct Panel: Codable {
    var id: String?
    /// Process step shown before the title, like "2A".
    var key: String?
    var title: String?
    var module: String?
    var params: [String]?
    var enable: [String]?
    var requires: [String]?
    var note: String?
    /// Developer-tier params to show without the developer toggle.
    var promote: [String]?
    /// Custom control drawn above the rows: "colorHead", "testStrip", "gradeCurve", "lensBrowser",
    /// "edgeProfile", "vignetteProfile", "illuminantSpd".
    var widget: String?
    /// "beginner", "standard" or "expert". Left out: the module's level, or for a params list the
    /// lowest level of the modules that hold those params.
    var level: String?
  }
}

/// A layout ready for the inspector: stages of module specs, with whatever the file left out
/// collected in a last stage so every control stays reachable.
struct ResolvedLayout {
  struct Stage: Identifiable {
    let id: String
    let title: String?
    let hint: String?
    let color: String?
    let specs: [ModuleSpec]
  }

  let key: String
  let stages: [Stage]
  /// Module ids and param names in the file that this version does not have.
  let unknown: [String]

  var staged: Bool { stages.contains { $0.title != nil } }
}

enum PanelLayouts {
  static let selectionKey = "panelLayout"
  static let revisionKey = "panelLayoutRevision"
  static let stripKey = "panelLayoutStrip"
  static let classicKey = "builtin:classic"
  static let workflowKey = "builtin:workflow"

  struct Entry: Identifiable, Hashable {
    let key: String
    let name: String
    var builtIn: Bool { key.hasPrefix("builtin:") }
    var id: String { key }
  }

  static var directory: URL {
    let dir = Presets.directory.appendingPathComponent("Layouts", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  static func fileURL(_ key: String) -> URL? {
    guard key.hasPrefix("file:") else { return nil }
    return directory.appendingPathComponent(String(key.dropFirst(5)))
  }

  static func list() -> [Entry] {
    let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    let user = files.filter { $0.pathExtension == "json" }
      .map { Entry(key: "file:" + $0.lastPathComponent, name: (read($0)?.name).flatMap { $0.isEmpty ? nil : $0 } ?? $0.deletingPathExtension().lastPathComponent) }
      .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    return [Entry(key: classicKey, name: classic().name), Entry(key: workflowKey, name: workflow().name)] + user
  }

  static func layout(_ key: String) -> PanelLayout? {
    switch key {
    case classicKey: return classic()
    case workflowKey: return workflow()
    default: return fileURL(key).flatMap(read)
    }
  }

  static func read(_ url: URL) -> PanelLayout? {
    guard let data = try? Data(contentsOf: url),
          let layout = try? JSONDecoder().decode(PanelLayout.self, from: data),
          layout.format <= PanelLayout.currentFormat else { return nil }
    return layout
  }

  static func write(_ layout: PanelLayout, to url: URL) -> Bool {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? enc.encode(layout) else { return false }
    return (try? data.write(to: url, options: .atomic)) != nil
  }

  // MARK: Cache

  private static var cache: (String, ResolvedLayout)?

  /// The layout for `key`, falling back to the default when the file is gone or broken.
  /// Cached per key, revision and language; the inspector asks on every redraw.
  static func resolved(_ key: String, revision: Int) -> ResolvedLayout {
    let tag = "\(key)|\(revision)|\(L10n.isKorean)"
    if let (t, r) = cache, t == tag { return r }
    let r = resolve(layout(key) ?? classic(), key: layout(key) == nil ? classicKey : key)
    cache = (tag, r)
    return r
  }

  static func bumpRevision() {
    let d = UserDefaults.standard
    d.set(d.integer(forKey: revisionKey) + 1, forKey: revisionKey)
  }

  // MARK: Resolving

  /// Params a module card shows, its switch included: what the default layout makes reachable.
  static func shown(_ spec: ModuleSpec) -> [String] {
    let names = spec.names.isEmpty
      ? Catalog.params.filter { spec.groups.contains($0.group) }.map(\.name)
      : spec.names.filter { Catalog.byName[$0] != nil }
    return (spec.enableParams + names).filter { !Modules.hiddenEverywhere.contains($0) && !spec.hidden.contains($0) }
  }

  /// Whether a card has anything to show: some layouts list only developer values in a card.
  static func hasRows(_ spec: ModuleSpec, developer: Bool) -> Bool {
    spec.panel != nil || !spec.enableParams.isEmpty || shown(spec).contains {
      developer || spec.promote.contains($0) || (Catalog.byName[$0]?.tier ?? 2) <= 1
    }
  }

  /// The next layout in the list, for ⌥⌘P.
  static func next(after key: String) -> String {
    let keys = list().map(\.key)
    guard let i = keys.firstIndex(of: key) else { return classicKey }
    return keys[(i + 1) % keys.count]
  }

  static let widgets: [String: ModuleSpec.Panel] = [
    "colorHead": .colorHead, "testStrip": .testStrip, "gradeCurve": .gradeCurve, "lensBrowser": .lensBrowser,
    "edgeProfile": .edgeProfile, "vignetteProfile": .vignetteProfile, "illuminantSpd": .illuminantSpd,
  ]

  static func resolve(_ layout: PanelLayout, key: String) -> ResolvedLayout {
    let modules = Dictionary(uniqueKeysWithValues: Modules.all.map { ($0.id, $0) })
    var unknown: [String] = []
    var covered = Set<String>()
    var used = Set<String>()

    var stages: [ResolvedLayout.Stage] = layout.stages.enumerated().map { si, stage in
      let specs: [ModuleSpec] = stage.panels.enumerated().compactMap { pi, panel in
        var spec: ModuleSpec
        if let m = panel.module {
          guard let base = modules[m] else { unknown.append(m); return nil }
          spec = base
          if let t = panel.title { spec = spec.retitled(t) }
          if let l = panel.level.flatMap(ToolLevel.init) { spec.level = l }
        } else {
          let names = panel.params ?? []
          unknown += names.filter { Catalog.byName[$0] == nil }
          let known = names.filter { Catalog.byName[$0] != nil }
          let enable = (panel.enable ?? []).filter { Catalog.byName[$0] != nil }
          guard !known.isEmpty || !enable.isEmpty else { return nil }
          spec = ModuleSpec(
            id: panel.id ?? "\(stage.id).\(pi)", title: panel.title ?? "",
            names: known, enableParams: enable,
            requires: (panel.requires ?? []).filter { Catalog.byName[$0] != nil },
            // Listed by hand, so tier-1 params show up front; developer values stay behind the toggle.
            promote: Set(known.filter { (Catalog.byName[$0]?.tier ?? 2) <= 1 || panel.promote?.contains($0) == true }),
            panel: panel.widget.flatMap { Self.widgets[$0] },
            note: panel.note,
            level: panel.level.flatMap(ToolLevel.init)
              ?? Modules.all.filter { !Set(shown($0)).isDisjoint(with: known + enable) }.map(\.level).min() ?? .expert)
        }
        if let k = panel.key { spec = spec.retitled("\(k)  \(spec.title)") }
        // ForEach needs unique ids; the same module may be listed twice.
        var id = spec.id
        while used.contains(id) { id += "+" }
        used.insert(id)
        spec = spec.reidentified(id)
        covered.formUnion(shown(spec))
        return spec
      }
      return ResolvedLayout.Stage(id: stage.id.isEmpty ? "s\(si)" : stage.id, title: stage.title, hint: stage.hint,
                                  color: stage.color, specs: specs)
    }

    // Anything the default layout shows that this file does not: added by a newer version or left out.
    let all = Modules.all.flatMap(shown)
    var seen = Set<String>()
    let missing = all.filter { !covered.contains($0) && seen.insert($0).inserted }
    if !missing.isEmpty {
      let spec = ModuleSpec(id: "other", title: tr("나머지 항목", "Other Controls"), names: missing,
                            promote: Set(missing.filter { (Catalog.byName[$0]?.tier ?? 2) <= 1 }),
                            note: tr("이 레이아웃 파일에 없는 항목입니다.", "Controls this layout file does not place."))
      stages.append(.init(id: "other", title: stages.contains { $0.title != nil } ? tr("기타", "Other") : nil,
                          hint: nil, color: "#8e8f95", specs: [spec]))
    }
    return ResolvedLayout(key: key, stages: stages, unknown: unknown)
  }

  // MARK: Files

  /// Writes a copy of the layout under a new name into the layouts folder and returns its key.
  static func duplicate(_ key: String) -> String? {
    guard var layout = layout(key) else { return nil }
    layout.name = uniqueName(layout.name + tr(" 사본", " Copy"))
    let url = directory.appendingPathComponent(fileName(layout.name))
    return write(layout, to: url) ? "file:" + url.lastPathComponent : nil
  }

  static func delete(_ key: String) {
    if let url = fileURL(key) { try? FileManager.default.removeItem(at: url) }
  }

  #if os(macOS)
  static func export(_ key: String) {
    guard let layout = layout(key) else { return }
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "PhotoEmul Layout - \(layout.name).json"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    _ = write(layout, to: url)
  }

  enum ImportResult {  // macOS importFile; the iPad probe builds its own with fileImporter
    case added(key: String, name: String, unknown: [String])
    case failed
  }

  /// Copies a layout file into the layouts folder; names this version does not know are reported.
  static func importFile() -> ImportResult? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    guard panel.runModal() == .OK, let src = panel.url else { return nil }
    guard var layout = read(src) else { return .failed }
    layout.name = uniqueName(layout.name.isEmpty ? src.deletingPathExtension().lastPathComponent : layout.name)
    let url = directory.appendingPathComponent(fileName(layout.name))
    guard write(layout, to: url) else { return .failed }
    return .added(key: "file:" + url.lastPathComponent, name: layout.name,
                  unknown: resolve(layout, key: "").unknown)
  }
  #endif

  private static func uniqueName(_ base: String) -> String {
    let names = Set(list().map(\.name))
    var name = base, n = 2
    while names.contains(name) || FileManager.default.fileExists(atPath: directory.appendingPathComponent(fileName(name)).path) {
      name = "\(base) \(n)"; n += 1
    }
    return name
  }

  private static func fileName(_ name: String) -> String {
    name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + ".json"
  }

  // MARK: Built-ins

  /// The module list in light-path order, as it has always been.
  static func classic() -> PanelLayout {
    PanelLayout(name: tr("기본", "Default"), stages: [
      .init(id: "modules", panels: Modules.all.map { .init(module: $0.id) }),
    ])
  }

  /// The real darkroom order: chapter = stage number, section = step letter (as in the manual).
  static func workflow() -> PanelLayout {
    func m(_ key: String, _ module: String) -> PanelLayout.Panel { .init(key: key, module: module) }
    func p(_ key: String, _ id: String, _ title: String, _ params: [String], widget: String? = nil, promote: [String]? = nil,
           note: String? = nil, level: ToolLevel) -> PanelLayout.Panel {
      .init(id: id, key: key, title: title, params: params, note: note, promote: promote, widget: widget, level: level.rawValue)
    }
    return PanelLayout(name: tr("공정 순서", "Process Order"), stages: [
      .init(id: "result", panels: [
        p("", "result", tr("결과물", "Output"), ["process"],
          note: tr("어디까지 갈지: 인화 시뮬레이션은 4 인화까지, 네거 스캔은 4를 건너뜁니다. 네거 인화는 입력을 현상된 네거로 보고 1–3을 건너뛰어 바로 인화합니다.",
                   "How far to go: print simulation runs through 4 Print, negative scan skips it. Process negative takes the input as a developed negative and skips 1–3, printing it directly."), level: .beginner),
      ]),
      .init(id: "film", title: tr("1 필름 준비", "1 Film Prep"), hint: tr("찍기 전에 정해지는 것", "Settled before shooting"), color: "#9fbf6a", panels: [
        p("1A", "film.format", tr("포맷", "Format"), ["filmFormat", "rgbToRawMethod"],
          note: tr("필름 종류는 왼쪽 재료 패널에서 고릅니다.", "Pick the stock in the stock panel on the left."), level: .standard),
        p("1B", "film.storage", tr("보관 상태", "Storage"), ["agingYears", "agingStorage", "agingHumidity"], level: .standard),
      ]),
      .init(id: "shoot", title: tr("2 촬영", "2 Capture"), hint: tr("카메라 앞", "In front of the film"), color: "#5aa2ff", panels: [
        m("2A", "lensProfile"), m("2A", "lensBlur"), m("2A", "vignette"), m("2A", "aberration"),
        m("2B", "cameraDiffusion"),
        p("2B", "shoot.filters", tr("렌즈 앞 필터", "Lens Filters"),
          ["cameraUvFilterEnabled", "cameraUvCutNm", "cameraIrFilterEnabled", "cameraIrCutNm", "cameraColorFilter"], level: .standard),
        p("2C", "shoot.exposure", tr("노출", "Exposure"), ["filmExposureEv", "autoExposure", "autoExposureMethod", "shutterSpeed", "reciprocityCompensate"],
          note: tr("셔터 속도는 장노출 상반칙 불궤에만 쓰입니다. 보정을 켜면 데이터시트대로 노출을 더 준 것으로 보고 색 틀어짐과 콘트라스트 변화만 남깁니다.",
                   "Shutter speed only drives reciprocity failure on long exposures. Compensated assumes you opened up per the datasheet, leaving the colour shift and contrast change."), level: .beginner),
        p("2C", "shoot.light", tr("조명 광원", "Scene Light"), ["sceneIlluminant", "sceneIlluminantAmount"],
          note: tr("필름은 데이라이트(5500K) 또는 텅스텐(3200K)에 맞춰져 있습니다. 다른 빛 아래서 찍으면 그 차이가 색으로 남습니다.",
                   "Film is balanced for daylight (5500K) or tungsten (3200K). Shooting under other light leaves the difference as a colour cast."), level: .standard),
        m("2D", "halation"),
      ]),
      .init(id: "develop", title: tr("3 필름 현상", "3 Film Development"), hint: "C-41 · ECN-2 · E-6 · B&W", color: "#f0b429", panels: [
        p("3A", "dev.process", tr("공정", "Process"), ["devTempDelta", "devTimePercent", "filmPushPullMode", "filmPushPullStops"],
          note: tr("표준: C-41 37.8°C 3:15, ECN-2 41.1°C 3:00, E-6 38°C, 흑백 20°C, 인스턴트 약 25°C.",
                   "Standard: C-41 37.8°C 3:15, ECN-2 41.1°C 3:00, E-6 38°C, B&W 20°C, instant about 25°C."), level: .standard),
        p("3B", "dev.chemistry", tr("약품", "Chemistry"), ["devDeveloper", "devDilution", "negativeBleachBypassAmount", "negativeLeucoCyanCoupling", "filmGamma"],
          promote: ["negativeBleachBypassAmount", "negativeLeucoCyanCoupling", "filmGamma"],
          note: tr("현상액을 바꾸면 입상성 · 선예도 · 숄더 기본값이 바뀝니다. 아래 슬라이더는 그 위에 더하는 값입니다.",
                   "Changing the developer changes the default grain, sharpness and shoulder. The sliders below add on top."), level: .expert),
        m("3B", "adjacency"), m("3B", "uneven"), m("3B", "bromideDrag"),
        m("3C", "dir"), m("3C", "grain"),
        m("3D", "dust"),
      ]),
      .init(id: "print", title: tr("4 인화", "4 Print"), hint: tr("암실 · RA-4 또는 흑백", "Darkroom · RA-4 or B&W"), color: "#ff6b6b", panels: [
        p("4A", "print.enlarger", tr("인화지 · 확대기", "Paper · Enlarger"),
          ["enlargerLightSource", "paperGradeHalf", "printTiming", "enlargerScale", "enlargerOffsetXPercent", "enlargerOffsetYPercent"],
          widget: "gradeCurve",
          note: tr("인화지 종류는 왼쪽 재료 패널에서 고릅니다. 콘덴서: 캘리어 효과로 대비 +½ 등급, 그레인과 먼지가 더 보임. 디퓨저 · 콜드라이트: 부드럽고 먼지가 덜 보임. 등급은 흑백 다계조 인화지에서만 씁니다.",
                   "Pick the paper in the stock panel on the left. Condenser: Callier effect adds about half a grade of contrast and shows grain and dust more. Diffuser and cold light: softer, dust shows less. Grades apply to black-and-white multigrade paper only."), level: .standard),
        m("4A", "printDiffusion"),
        m("4B", "colorHead"),
        p("4C", "print.exposure", tr("인화 노출", "Print Exposure"),
          ["printExposureEv", "printSplitGrade", "printSoftSeconds", "printHardSeconds"],
          note: tr("분할 등급은 00 필터 노출과 5 필터 노출을 더합니다. 연한 쪽이 하이라이트, 진한 쪽이 그림자를 정합니다. 기준 10초.",
                   "Split grade adds a 00-filter and a 5-filter exposure. The soft one sets the highlights, the hard one the shadows. Reference 10 s."), level: .beginner),
        m("4C", "testStrip"), m("4C", "preflash"),
        p("4D", "print.develop", tr("인화지 현상", "Paper Development"),
          ["printPushPullStops", "printBleachBypassAmount", "printGamma", "printShadowShape", "printHighlightShape"],
          promote: ["printPushPullStops", "printBleachBypassAmount", "printGamma"], level: .expert),
        m("4D", "toning"),
      ]),
      .init(id: "scan", title: tr("5 스캔", "5 Scan"), hint: tr("디지털로 옮기기", "Into digital"), color: "#4fd1c5", panels: [
        m("5A", "scanner"), m("5B", "glare"),
        p("5C", "scan.invert", tr("네거 반전 · 색 적응", "Negative Inversion · Adaptation"),
          ["scanNegativeInvert", "colorAdaptation", "colorAdaptationInputCompression", "colorAdaptationCurveSmoothing",
           "colorAdaptationOutputLightnessCompression", "colorAdaptationOutputChromaCompression"], level: .standard),
      ]),
      .init(id: "finish", title: tr("6 마무리", "6 Finish"), hint: tr("테두리", "Border"), color: "#b58cf0", panels: [
        m("6A", "frame"),
      ]),
    ])
  }
}

extension ModuleSpec {
  func retitled(_ title: String) -> ModuleSpec {
    ModuleSpec(id: id, title: title, groups: groups, names: names, enableParams: enableParams, requires: requires,
               hidden: hidden, promote: promote, panel: panel, note: note, level: level, basic: basic)
  }

  func reidentified(_ id: String) -> ModuleSpec {
    ModuleSpec(id: id, title: title, groups: groups, names: names, enableParams: enableParams, requires: requires,
               hidden: hidden, promote: promote, panel: panel, note: note, level: level, basic: basic)
  }
}

/// Segmented level picker for the panel footer and Settings.
#if os(macOS)
struct ToolLevelPicker: View {
  @AppStorage(ToolLevel.key) private var level = ToolLevel.standard

  var body: some View {
    Picker(tr("도구 수준", "Tool Level"), selection: $level) {
      ForEach(ToolLevel.allCases, id: \.self) { Text($0.title).tag($0) }
    }
    .pickerStyle(.segmented).labelsHidden()
    .help(tr("보여 줄 도구의 난이도. 숨은 도구의 값도 그대로 적용됩니다.", "How advanced the shown tools are. Hidden tools keep applying their values."))
  }
}

/// View › Tool Panel: pick a layout, ⌥⌘P steps to the next one.
struct PanelLayoutCommands: View {
  @AppStorage(PanelLayouts.selectionKey) private var layoutKey = PanelLayouts.classicKey
  @AppStorage(ToolLevel.key) private var toolLevel = ToolLevel.standard
  @AppStorage(PanelLayouts.revisionKey) private var revision = 0

  var body: some View {
    let _ = revision
    Menu(tr("도구 패널", "Tool Panel")) {
      Picker(tr("도구 패널", "Tool Panel"), selection: $layoutKey) {
        ForEach(PanelLayouts.list()) { Text($0.name).tag($0.key) }
      }
      .pickerStyle(.inline)
    }
    Button(tr("다음 도구 패널 레이아웃", "Next Tool Panel Layout")) { layoutKey = PanelLayouts.next(after: layoutKey) }
      .keyboardShortcut("p", modifiers: [.command, .option])
    Picker(tr("도구 수준", "Tool Level"), selection: $toolLevel) {
      ForEach(ToolLevel.allCases, id: \.self) { Text($0.title).tag($0) }
    }
  }
}

/// Settings › Tool Panel: the layouts, their files, and the stage strip.
struct PanelLayoutSettings: View {
  @AppStorage(PanelLayouts.selectionKey) private var layoutKey = PanelLayouts.classicKey
  @AppStorage(PanelLayouts.revisionKey) private var revision = 0
  @AppStorage(PanelLayouts.stripKey) private var showStrip = true
  @AppStorage(ProcessScope.styleKey) private var inactiveStyle = ProcessScope.Style.dim.rawValue
  @State private var note: String?
  @State private var confirmDelete: PanelLayouts.Entry?

  var body: some View {
    let _ = revision
    let entries = PanelLayouts.list()
    let current = entries.first { $0.key == layoutKey } ?? entries[0]
    Form {
      Section {
        ForEach(entries) { e in
          HStack {
            Image(systemName: e.key == current.key ? "checkmark.circle.fill" : "circle")
              .foregroundStyle(e.key == current.key ? Color.accentColor : .secondary)
            Text(e.name)
            if e.builtIn {
              Image(systemName: "lock.fill").font(.caption2).foregroundStyle(.tertiary)
                .help(tr("내장 레이아웃: 복제해서 고칠 수 있습니다", "Built-in: duplicate it to change"))
            }
            Spacer()
            Text(summary(e.key)).font(.caption).foregroundStyle(.secondary)
          }
          .contentShape(Rectangle())
          .onTapGesture { layoutKey = e.key }
        }
      } header: {
        Text(tr("레이아웃", "Layouts"))
      } footer: {
        Text(tr("묶음과 순서만 바뀝니다. 값 · 프리셋 · 세션은 어느 레이아웃에서나 같습니다. 보기 › 도구 패널, ⌥⌘P로도 바꿉니다.",
                "Only grouping and order change; values, presets and sessions are the same in every layout. Also View › Tool Panel, ⌥⌘P."))
          .font(.caption).foregroundStyle(.secondary)
      }

      Section {
        HStack {
          Button(tr("복제", "Duplicate")) {
            if let key = PanelLayouts.duplicate(current.key) { layoutKey = key; PanelLayouts.bumpRevision() }
          }
          Button(tr("삭제…", "Delete…")) { confirmDelete = current }.disabled(current.builtIn)
          Spacer()
          Button(tr("가져오기…", "Import…")) { importLayout() }
          Button(tr("내보내기…", "Export…")) { PanelLayouts.export(current.key) }
        }
        Button(tr("Finder에서 레이아웃 폴더 보기", "Show Layouts Folder in Finder")) {
          NSWorkspace.shared.activateFileViewerSelecting([PanelLayouts.directory])
        }
        if let note { Text(note).font(.caption).foregroundStyle(.secondary) }
      } footer: {
        Text(tr("레이아웃은 JSON 파일입니다. 내보낸 파일을 고쳐서 다시 가져오면 됩니다. 이 버전에 없는 항목은 건너뛰고, 파일에 빠진 항목은 맨 아래 \"기타\"에 모입니다.",
                "Layouts are JSON files: export, edit, import. Names this version lacks are skipped; controls the file leaves out gather in \"Other\" at the bottom."))
          .font(.caption).foregroundStyle(.secondary)
      }

      Section {
        LabeledContent(tr("도구 수준", "Tool Level")) { ToolLevelPicker().fixedSize() }
      } footer: {
        Text(tr("초보는 노출 · 그레인 · 먼지처럼 이름만 봐도 아는 도구, 일반은 렌즈 · 필터 · 확대기 수준까지, 전문가는 약품 · 공정 · 암실 기법까지 보여 줍니다. 레이아웃과 따로 기억하며, 숨은 도구의 값도 그대로 적용됩니다.",
                "Beginner shows tools you know by name (exposure, grain, dust), Standard adds lens, filter and enlarger controls, Expert adds chemistry, process and darkroom technique. Kept apart from the layout; hidden tools keep applying their values."))
          .font(.caption).foregroundStyle(.secondary)
      }

      Section {
        Toggle(tr("단계 띠 표시 (누르면 그 단계로 이동)", "Show stage strip (click to jump)"), isOn: $showStrip)
      } footer: {
        Text(tr("단계가 있는 레이아웃(공정 순서 등)에서 패널 맨 위에 표시됩니다.", "Shown at the top of the panel for layouts with stages, like Process Order."))
          .font(.caption).foregroundStyle(.secondary)
      }

      Section {
        Picker(tr("적용되지 않는 항목", "Controls That Don't Apply"), selection: $inactiveStyle) {
          ForEach(ProcessScope.Style.allCases) { Text($0.title).tag($0.rawValue) }
        }
        .pickerStyle(.segmented)
      } footer: {
        Text(tr("처리 모드에 따라 건너뛰는 단계의 항목입니다. 네거 스캔은 인화를, 네거 인화는 촬영 · 필름 현상 · 그레인을 건너뜁니다. 흐리게 하면 값은 그대로 고칠 수 있고, 숨겨도 값은 남아 있다가 모드를 바꾸면 다시 적용됩니다.",
                "Controls of the stages the mode skips: Scan negative skips the print, Process negative skips capture, film development and grain. Dimmed ones stay editable; hidden ones keep their values and apply again when the mode changes."))
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .confirmationDialog(tr("이 레이아웃을 삭제할까요?", "Delete this layout?"), isPresented: Binding(
      get: { confirmDelete != nil }, set: { if !$0 { confirmDelete = nil } })) {
      Button(tr("삭제", "Delete"), role: .destructive) {
        if let e = confirmDelete {
          PanelLayouts.delete(e.key)
          if layoutKey == e.key { layoutKey = PanelLayouts.classicKey }
          PanelLayouts.bumpRevision()
        }
        confirmDelete = nil
      }
    } message: {
      Text(confirmDelete?.name ?? "")
    }
  }

  private func summary(_ key: String) -> String {
    guard let l = PanelLayouts.layout(key) else { return tr("읽을 수 없음", "Unreadable") }
    let stages = l.stages.filter { $0.title != nil }.count
    let panels = l.stages.reduce(0) { $0 + $1.panels.count }
    return stages > 0 ? tr("\(stages)단계 · 패널 \(panels)", "\(stages) stages · \(panels) panels")
      : tr("패널 \(panels)", "\(panels) panels")
  }

  private func importLayout() {
    switch PanelLayouts.importFile() {
    case nil: return
    case .failed:
      note = tr("레이아웃 파일로 읽을 수 없습니다 (형식이 다르거나 더 새 버전용).",
                "Could not read it as a layout file (different format or a newer version).")
    case let .added(key, name, unknown):
      layoutKey = key
      PanelLayouts.bumpRevision()
      note = unknown.isEmpty ? tr("\"\(name)\"을(를) 가져왔습니다.", "Imported \"\(name)\".")
        : tr("\"\(name)\"을(를) 가져왔습니다. 이 버전에 없는 항목 \(unknown.count)개는 건너뜁니다: \(unknown.prefix(6).joined(separator: ", "))",
             "Imported \"\(name)\". Skipped \(unknown.count) unknown: \(unknown.prefix(6).joined(separator: ", "))")
    }
  }
}
#endif
