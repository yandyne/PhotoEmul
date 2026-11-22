// PhotoEmul - native editor for spektrafilm (GPL-3.0-or-later)
// Right panel: histogram and the module stack generated from the engine descriptors.

import SwiftUI

struct HistogramView: View {
  let histogram: Histogram

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Canvas { ctx, size in
        let colors: [Color] = [.red, .green, .blue]
        for (c, bins) in histogram.bins.enumerated() where !bins.isEmpty {
          var path = Path()
          path.move(to: CGPoint(x: 0, y: size.height))
          for (i, v) in bins.enumerated() {
            let x = size.width * CGFloat(i) / CGFloat(bins.count - 1)
            path.addLine(to: CGPoint(x: x, y: size.height * (1 - CGFloat(v))))
          }
          path.addLine(to: CGPoint(x: size.width, y: size.height))
          path.closeSubpath()
          ctx.blendMode = .plusLighter
          ctx.fill(path, with: .color(colors[c].opacity(0.55)))
        }
      }
      .frame(height: 90)
      .background(Color.black.opacity(0.35))
      .clipShape(RoundedRectangle(cornerRadius: 4))
      HStack {
        Label(String(format: "%.1f%%", histogram.shadowClip), systemImage: "arrowtriangle.left.fill")
        Spacer()
        Text(tr("클리핑", "Clipping")).foregroundStyle(.secondary)
        Spacer()
        Label(String(format: "%.1f%%", histogram.highlightClip), systemImage: "arrowtriangle.right.fill")
          .labelStyle(TrailingIconLabelStyle())
      }
      .font(.caption2.monospacedDigit())
      .foregroundStyle(histogram.highlightClip > 1 || histogram.shadowClip > 1 ? .orange : .secondary)
    }
  }
}

struct TrailingIconLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HStack(spacing: 4) { configuration.title; configuration.icon }
  }
}

/// Right-hand panel with a draggable left edge; its width is remembered like the picker's.
struct InspectorPane: View {
  let model: EditModel
  @AppStorage("inspectorWidth") private var width = 320.0
  /// Narrower than the chosen width when the window is too narrow for both panels and the canvas.
  var maxWidth = Double.infinity

  static let widthRange = 280.0...480.0

  var body: some View {
    HStack(spacing: 0) {
      PanelEdge(width: $width, range: Self.widthRange, reset: 320, grows: -1)
      InspectorView(model: model)
        .frame(width: max(min(width, Self.widthRange.upperBound, maxWidth), Self.widthRange.lowerBound))
    }
  }
}

struct InspectorView: View {
  @Bindable var model: EditModel
  // Folded modules and opened "more" rows, remembered across launches.
  @AppStorage("inspectorCollapsed") private var collapsed = ""
  @AppStorage("inspectorMore") private var expanded = ""
  @AppStorage(PanelLayouts.selectionKey) private var layoutKey = PanelLayouts.classicKey
  @AppStorage(PanelLayouts.revisionKey) private var revision = 0
  @AppStorage(PanelLayouts.stripKey) private var showStrip = true
  @AppStorage(ProcessScope.styleKey) private var inactiveStyle = ProcessScope.Style.dim.rawValue
  @AppStorage(ToolLevel.key) private var toolLevel = ToolLevel.standard

  private var layout: ResolvedLayout { PanelLayouts.resolved(layoutKey, revision: revision) }

  /// The card (and row) of the history step picked in the timeline.
  struct Flash: Equatable {
    let spec: String; let name: String; let id: Int
    /// Other cards the step changed: they flash too, but stay as they are (no opening, no scroll).
    var others: Set<String> = []
  }
  @State private var flash: Flash?
  /// Cards above the tool level: the edited ones on demand, and the one a history step picked.
  @State private var showOver = false
  @State private var peek: String?

  var body: some View {
    let layout = layout
    VStack(spacing: 0) {
      InspectorHeader(model: model)
      Divider()
      ScrollViewReader { proxy in
        if layout.staged && showStrip {
          StageStrip(model: model, layout: layout, hiddenStages: hiddenStages(layout)) { id in
            stageCollapsed(id, in: layout).wrappedValue = false
            withAnimation(.easeInOut(duration: 0.2)) { proxy.scrollTo("stage:" + id, anchor: .top) }
          }
          Divider()
        }
        ScrollView {
          // Plain VStack: a LazyVStack re-measures rows of changing height while scrolling.
          VStack(spacing: 6) {
            let hidden = hiddenStages(layout)
            let over = overUsed(layout)
            if over > 0 || showOver {
              Button {
                withAnimation(.easeOut(duration: 0.15)) { showOver.toggle() }
              } label: {
                Label(tr("숨긴 도구 \(over)개 적용 중", "\(over) hidden tools in use")
                        + " · " + (showOver ? tr("숨기기", "Hide") : tr("보기", "Show")),
                      systemImage: showOver ? "eye.slash" : "eye")
                  .font(.caption).frame(maxWidth: .infinity, alignment: .leading)
              }
              .buttonStyle(.borderless)
              .help(tr("도구 수준에서 숨긴 도구 중 값이 바뀐 것을 펼쳐 보거나 초기화합니다", "Show edited tools hidden by the tool level, to see or reset them"))
            }
            ForEach(layout.stages.filter { !hidden.contains($0.id) }) { stage in
              StageSection(model: model, stage: stage, collapsed: stageCollapsed(stage.id, in: layout)) {
                ForEach(visibleSpecs(stage, in: layout)) { spec in
                  ModulePanel(
                    model: model, spec: spec,
                    collapsed: binding(for: panelKey(spec.id, in: layout), in: $collapsed),
                    showMore: binding(for: panelKey(spec.id, in: layout), in: $expanded),
                    flash: flash?.spec == spec.id ? flash
                      : flash.flatMap { $0.others.contains(spec.id) ? Flash(spec: spec.id, name: "", id: $0.id) : nil },
                    levelBadge: spec.level > toolLevel ? spec.level.title : nil)
                  .id("module:" + spec.id)
            // The card the AI is changing in its draft.
            .overlay {
              if !AgentSession.shared.touching.isDisjoint(with: PanelLayouts.shown(spec)) {
                RoundedRectangle(cornerRadius: 8).strokeBorder(.orange, lineWidth: 2).allowsHitTesting(false)
              }
            }
                }
              }
              .id("stage:" + stage.id)
            }
          }
          .padding(8)
        }
        // A different layout starts at the top.
        .id(layout.key)
        .onChange(of: model.spotlight) { _, s in reveal(s, in: layout, proxy: proxy) }
      }
      Divider()
      HStack {
        Spacer()
        ToolLevelPicker().controlSize(.small).fixedSize()
        PanelLayoutMenu()
        Button(tr("모두 초기화", "Reset All")) { model.resetAll() }.font(.caption)
      }
      .padding(8)
    }
  }

  /// Opens the card holding the first value a history step changed, scrolls to it and flashes it.
  private func reveal(_ s: EditModel.Spotlight?, in layout: ResolvedLayout, proxy: ScrollViewProxy) {
    guard let s else { flash = nil; peek = nil; return }
    let names = Set(s.names)
    // Cards the step changed, top to bottom as the panel shows them: the top one opens and
    // scrolls into view (a step over many tools, like Reset All, shows its first card).
    // A card above the tool level shows while the step is picked.
    var hits: [(stage: String, spec: ModuleSpec, name: String)] = []
    for stage in layout.stages {
      for spec in visibleSpecs(stage, in: layout, anyLevel: true) {
        if let name = PanelLayouts.shown(spec).first(where: names.contains) { hits.append((stage.id, spec, name)) }
      }
    }
    guard let top = hits.first else { flash = nil; peek = nil; return }
    peek = top.spec.level > toolLevel ? top.spec.id : nil
    stageCollapsed(top.stage, in: layout).wrappedValue = false
    binding(for: panelKey(top.spec.id, in: layout), in: $collapsed).wrappedValue = false
    if let d = Catalog.byName[top.name], !top.spec.isBasic(d, at: toolLevel) {
      binding(for: panelKey(top.spec.id, in: layout), in: $expanded).wrappedValue = true
    }
    flash = Flash(spec: top.spec.id, name: top.name, id: s.id, others: Set(hits.dropFirst().map(\.spec.id)))
    // After the opened card has its height.
    DispatchQueue.main.async {
      withAnimation(.easeInOut(duration: 0.25)) { proxy.scrollTo("module:" + top.spec.id, anchor: .center) }
    }
  }

  private func visibleSpecs(_ stage: ResolvedLayout.Stage, in layout: ResolvedLayout, anyLevel: Bool = false) -> [ModuleSpec] {
    stage.specs.filter {
      (anyLevel || $0.level <= toolLevel || $0.id == peek || (showOver && model.isModified(PanelLayouts.shown($0))))
        && (layout.key == PanelLayouts.classicKey || PanelLayouts.hasRows($0, developer: toolLevel == .expert))
        && !ProcessScope.hides($0, model.settledValues, style: inactiveStyle)
    }
  }

  /// Edited cards the tool level hides.
  private func overUsed(_ layout: ResolvedLayout) -> Int {
    layout.stages.flatMap { visibleSpecs($0, in: layout, anyLevel: true) }
      .filter { $0.level > toolLevel && model.isModified(PanelLayouts.shown($0)) }.count
  }

  /// Titled stages left with no card when cards the mode skips are hidden.
  private func hiddenStages(_ layout: ResolvedLayout) -> Set<String> {
    Set(layout.stages.filter { $0.title != nil && !$0.specs.isEmpty && visibleSpecs($0, in: layout).isEmpty }.map(\.id))
  }

  /// The default layout keeps the plain module ids, so folds made before layouts existed stay.
  private func panelKey(_ id: String, in layout: ResolvedLayout) -> String {
    layout.key == PanelLayouts.classicKey ? id : "\(layout.key)/\(id)"
  }

  private func stageCollapsed(_ id: String, in layout: ResolvedLayout) -> Binding<Bool> {
    binding(for: "\(layout.key)/stage:\(id)", in: $collapsed)
  }

  private func binding(for id: String, in raw: Binding<String>) -> Binding<Bool> {
    Binding(
      get: { raw.wrappedValue.split(separator: ",").contains(Substring(id)) },
      set: { on in
        var ids = Set(raw.wrappedValue.split(separator: ",").map(String.init))
        if on { ids.insert(id) } else { ids.remove(id) }
        raw.wrappedValue = ids.sorted().joined(separator: ",")
      })
  }
}

extension Color {
  /// "#rrggbb" from a layout file; nil when it does not parse.
  init?(hex: String?) {
    guard var s = hex?.trimmingCharacters(in: .whitespaces) else { return nil }
    if s.hasPrefix("#") { s.removeFirst() }
    guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
    self.init(red: Double(v >> 16 & 0xff) / 255, green: Double(v >> 8 & 0xff) / 255, blue: Double(v & 0xff) / 255)
  }
}

/// A stage of a process layout: colored bar, foldable title. Untitled stages show their panels bare.
struct StageSection<Content: View>: View {
  let model: EditModel
  let stage: ResolvedLayout.Stage
  @Binding var collapsed: Bool
  @ViewBuilder let content: Content

  var body: some View {
    if let title = stage.title {
      let color = Color(hex: stage.color) ?? .secondary
      VStack(alignment: .leading, spacing: 6) {
        Button { collapsed.toggle() } label: {
          HStack(spacing: 6) {
            Image(systemName: collapsed ? "chevron.right" : "chevron.down").font(.caption2).frame(width: 12)
            Text(title).font(.subheadline.weight(.bold))
            if let hint = stage.hint { Text(hint).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            Spacer()
            if model.isModified(stage.specs.flatMap(PanelLayouts.shown)) {
              Circle().fill(Color.accentColor).frame(width: 6, height: 6)
                .help(tr("바뀐 값이 있습니다", "Has edited values"))
            }
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 4)
        if !collapsed {
          VStack(spacing: 6) { content }
        }
      }
      .padding(.leading, 8)
      .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3) }
    } else {
      content
    }
  }
}

/// Buttons for the titled stages; pressing one opens and scrolls to it. A dot marks edited stages.
struct StageStrip: View {
  let model: EditModel
  let layout: ResolvedLayout
  var hiddenStages: Set<String> = []
  let jump: (String) -> Void

  var body: some View {
    HStack(spacing: 3) {
      ForEach(layout.stages.filter { $0.title != nil && !hiddenStages.contains($0.id) }) { stage in
        Button { jump(stage.id) } label: {
          HStack(spacing: 2) {
            Text(stage.title ?? "").lineLimit(1).minimumScaleFactor(0.7)
            if model.isModified(stage.specs.flatMap(PanelLayouts.shown)) {
              Circle().fill(Color.accentColor).frame(width: 4, height: 4)
            }
          }
          .font(.caption2.weight(.semibold))
          .frame(maxWidth: .infinity).padding(.vertical, 4)
          .overlay(alignment: .bottom) {
            Rectangle().fill(Color(hex: stage.color) ?? .secondary).frame(height: 2)
          }
          .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(stage.hint ?? "")
      }
    }
    .padding(.horizontal, 8).padding(.vertical, 5)
  }
}

/// Footer and View-menu picker of the panel layout.
struct PanelLayoutMenu: View {
  @AppStorage(PanelLayouts.selectionKey) private var layoutKey = PanelLayouts.classicKey
  @AppStorage(PanelLayouts.revisionKey) private var revision = 0

  var body: some View {
    let _ = revision
    Menu {
      Picker(tr("도구 패널", "Tool Panel"), selection: $layoutKey) {
        ForEach(PanelLayouts.list()) { Text($0.name).tag($0.key) }
      }
      .pickerStyle(.inline)
      Divider()
      SettingsLink { Text(tr("레이아웃 관리…", "Manage Layouts…")) }
    } label: {
      Image(systemName: "rectangle.3.group")
    }
    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
    .help(tr("도구 패널 레이아웃", "Tool panel layout"))
  }
}

/// Histogram and file line; its own view so a new render does not rebuild the module stack.
struct InspectorHeader: View {
  let model: EditModel

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HistogramView(histogram: model.histogram)
      if let s = model.source {
        Text("\(s.url.lastPathComponent) · \(s.width)×\(s.height)")
          .font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
      }
    }
    .padding(12)
  }
}

extension ModuleSpec {
  /// Open without More: the beginner's picks, else tier 0 and promoted rows.
  func isBasic(_ d: ParamDescriptor, at level: ToolLevel) -> Bool {
    level == .beginner && !basic.isEmpty ? basic.contains(d.name) : d.tier == 0 || promote.contains(d.name)
  }
}

struct ModulePanel: View {
  @Bindable var model: EditModel
  let spec: ModuleSpec
  @Binding var collapsed: Bool
  @Binding var showMore: Bool
  /// Set while this card holds the step picked in the history timeline.
  var flash: InspectorView.Flash?
  /// The tool level this card belongs to, when it is above the one picked.
  var levelBadge: String? = nil
  @AppStorage(ProcessScope.styleKey) private var inactiveStyle = ProcessScope.Style.dim.rawValue
  @AppStorage(ToolLevel.key) private var toolLevel = ToolLevel.standard

  private var params: [ParamDescriptor] {
    let all = spec.names.isEmpty
      ? Catalog.params.filter { spec.groups.contains($0.group) }
      : spec.names.compactMap { Catalog.byName[$0] }
    let graded = Darkroom.onGradedPaper(model.settledValues), bwPrint = Darkroom.isBwPrinting(model.settledValues)
    let bwFilm = isBwFilm, slowAgitation = (model.settledValues["adjacencyAgitation"]?.intValue ?? Adjacency.defaultAgitation) >= 3
    return all.filter {
      !Modules.hiddenEverywhere.contains($0.name) && !spec.hidden.contains($0.name)
        && !spec.enableParams.contains($0.name)
        && !(Self.gradedOnly.contains($0.name) && !graded)
        && !(Self.bwPrintOnly.contains($0.name) && !bwPrint)
        && !(Self.bwFilmOnly.contains($0.name) && !bwFilm)
        && !($0.name == "devBromideDrag" && !slowAgitation)
        && !(hidesInactive && !ProcessScope.isActive($0.name, model.settledValues))
    }
  }
  private var hidesInactive: Bool { inactiveStyle == ProcessScope.Style.hide.rawValue }
  /// Why the whole card does nothing in this mode, or why some of its rows do not.
  private var cardInactive: String? { ProcessScope.reason(spec, model.settledValues) }
  private var rowsInactive: String? {
    hidesInactive ? nil : params.lazy.compactMap { ProcessScope.reason($0.name, model.settledValues) }.first
  }
  private var isBwFilm: Bool {
    Catalog.films[safe: model.settledValues["film"]?.intValue ?? -1].map { FilmInfo.category($0) == .bw } ?? false
  }
  /// The note, plus a word on why the developer is missing on colour film.
  private var noteText: String? {
    let developer = spec.names.contains("devDeveloper") || (spec.groups.contains("develop") && !spec.hidden.contains("devDeveloper"))
    guard developer && !isBwFilm else { return spec.note }
    let extra = tr("컬러 필름은 공정 표준 현상액을 씁니다.", "Colour film uses its process's standard developer.")
    return spec.note.map { "\($0) \(extra)" } ?? extra
  }
  /// Grades only exist on black-and-white variable-contrast paper; the light source only matters
  /// for the silver of a black-and-white negative (Callier effect).
  private static let gradedOnly: Set<String> = ["paperGradeHalf", "printSplitGrade", "printSoftSeconds", "printHardSeconds"]
  private static let bwPrintOnly: Set<String> = ["enlargerLightSource"]
  /// Developer and dilution only change black-and-white film; bromide drag needs slow agitation.
  private static let bwFilmOnly: Set<String> = ["devDeveloper", "devDilution", "devHighlightCompression", "devBromideDrag"]

  private func has(_ name: String) -> Bool { params.contains { $0.name == name } }

  /// What the shutter time costs on this film: the extra exposure (to ⅓ stop) and the colour
  /// correction filter for the layer that fails fastest (1 stop = CC30).
  private var reciprocityCaption: String? {
    guard let film = Catalog.films[safe: model.settledValues["film"]?.intValue ?? -1] else { return nil }
    var raw = model.settledValues
    raw["reciprocityCompensate"] = .bool(false)
    guard let e = Reciprocity.effect(raw, film: film), e.stops.reduce(0, +) / 3 >= 0.05 else {
      let t0 = Reciprocity.fit(for: film).t0
      let limit = t0 >= 60 ? "\(Int(t0 / 60)) min" : t0 >= 1 ? "\(Int(t0)) s" : "1/\(Int((1 / t0).rounded())) s"
      return tr("상반칙 불궤 없음 (\(limit) 미만)", "No reciprocity failure (under \(limit))")
    }
    let mean = e.stops.reduce(0, +) / 3
    let thirds = Int((mean * 3).rounded())
    let whole = thirds / 3, frac = ["", "⅓", "⅔"][thirds % 3]
    var text = "+" + (whole > 0 ? "\(whole)" : "") + (frac.isEmpty && whole == 0 ? "0" : frac) + " stop"
    text = tr("보정 ", "Compensate ") + text
    if FilmInfo.category(film) != .bw, let worst = (0..<3).max(by: { e.stops[$0] < e.stops[$1] }) {
      let cc = Int(((e.stops[worst] - mean) * 30 / 5).rounded()) * 5
      if cc >= 5 { text += tr(" · 색 보정 ", " · colour ") + "CC\(cc)" + ["C", "M", "Y"][worst] }
    }
    let on = model.settledValues["reciprocityCompensate"]?.boolValue ?? true
    return text + " · " + (on ? tr("보정 적용됨", "applied") : tr("보정 안 함, 어둡게 나옴", "not applied, comes out dark"))
  }

  private var basic: [ParamDescriptor] { params.filter { spec.isBasic($0, at: toolLevel) } }
  /// Expert also gets the developer rows, always open.
  private var more: [ParamDescriptor] {
    params.filter { !spec.isBasic($0, at: toolLevel) && ($0.tier < 2 || toolLevel == .expert) }
  }

  private var enabled: Bool {
    spec.enableParams.allSatisfy { model.value($0).boolValue }
  }
  private var requirementsMet: Bool { spec.requires.allSatisfy { model.value($0).boolValue } }
  /// Every value this module's reset puts back, the "more" and developer rows included.
  private var resettable: [String] { params.map(\.name) }
  private var modified: Bool { model.isModified(resettable) }

  private func resetModule() {
    model.reset(resettable, label: "\(spec.title) " + tr("초기화", "reset"))
  }

  /// A row the mode skips stays editable but dimmed, with the reason on hover. A dimmed card
  /// dims as a whole instead.
  @ViewBuilder private func row(_ d: ParamDescriptor) -> some View {
    Group {
      if cardInactive == nil, let reason = ProcessScope.reason(d.name, model.settledValues) {
        ParamRow(model: model, descriptor: d).opacity(0.45).help(reason)
      } else {
        ParamRow(model: model, descriptor: d)
      }
    }
    .background {
      if let flash, flash.name == d.name { FlashMark(fill: true).id(flash.id).padding(-3) }
    }
  }

  /// A module that is switched off folds to its header line.
  private var folded: Bool { collapsed || !enabled }

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack {
        Image(systemName: folded ? "chevron.right" : "chevron.down")
          .font(.caption2).frame(width: 12)
          .foregroundStyle(enabled ? .primary : .tertiary)
        Text(spec.title).font(.headline)
          .foregroundStyle(enabled && cardInactive == nil ? .primary : .secondary)
        if let levelBadge {
          Text(levelBadge)
            .font(.caption2.weight(.medium)).foregroundStyle(.orange)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color.orange.opacity(0.14)))
        }
        if modified {
          Text(tr("수정됨", "Edited"))
            .font(.caption2.weight(.medium)).foregroundStyle(Color.accentColor)
            .padding(.horizontal, 5).padding(.vertical, 1)
            .background(Capsule().fill(Color.accentColor.opacity(0.14)))
        }
        Spacer()
        if modified {
          Button { resetModule() } label: { Image(systemName: "arrow.counterclockwise") }
            .buttonStyle(.borderless).font(.caption)
            .help(tr("이 모듈만 초기화", "Reset this module only"))
        }
        if !spec.enableParams.isEmpty {
          Toggle("", isOn: Binding(
            get: { enabled },
            set: { on in
              for p in spec.enableParams { model.set(p, .bool(on)) }
              model.commit(label: "\(spec.title) \(on ? tr("켬", "on") : tr("끔", "off"))")
            }))
          .toggleStyle(.switch).controlSize(.mini).labelsHidden()
        }
        if spec.panel == .testStrip {
          // Shows the strip as a tool; off also turns off 효과로 쓰기.
          Toggle("", isOn: Binding(get: { model.testStripShown }, set: { _ in model.toggleTestStrip() }))
            .toggleStyle(.switch).controlSize(.mini).labelsHidden()
            .disabled(!model.testStripAvailable)
            .help(tr("스트립 보기/숨기기 (T)", "Show/hide the strip (T)"))
        }
      }
      .contentShape(Rectangle())
      .onTapGesture(count: 2) { resetModule() }
      .onTapGesture { if enabled { withAnimation(.easeOut(duration: 0.15)) { collapsed.toggle() } } }
      .help(tr("클릭: 접기/펴기 · 더블클릭: 이 모듈 초기화", "Click: collapse/expand · Double-click: reset this module"))

      if !folded {
        if let reason = cardInactive ?? rowsInactive {
          Label(reason, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
        if let note = noteText {
          Text(note).font(.caption).foregroundStyle(requirementsMet ? Color.secondary : Color.orange)
            .fixedSize(horizontal: false, vertical: true)
        }
        if has("process"), let line = ProcessScope.conflict(model.settledValues) {
          VStack(alignment: .leading, spacing: 4) {
            Label(line, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.orange)
              .fixedSize(horizontal: false, vertical: true)
            Button(tr("스캔으로 바꾸기", "Switch to Scan")) { model.setAndCommit("process", .int(1)) }
              .controlSize(.small)
          }
        }
        if has("process"), let line = ProcessScope.modeNote(model.settledValues) {
          Label(line, systemImage: "info.circle").font(.caption).foregroundStyle(Color.accentColor)
            .fixedSize(horizontal: false, vertical: true)
        }
        if has("shutterSpeed"), let line = reciprocityCaption {
          Text(line).font(.caption).foregroundStyle(Color.accentColor)
            .fixedSize(horizontal: false, vertical: true)
        }
        Group {
          if spec.panel == .colorHead { ColorHeadPad(model: model) }
          if spec.panel == .lensBrowser { LensProfilePanel(model: model) }
          if spec.panel == .lensBrowser || spec.panel == .vignetteProfile { VignetteProfileGraph(values: model.settledValues) }
          if spec.panel == .gradeCurve || (spec.panel == nil && has("paperGradeHalf")) { GradeCurveGraph(values: model.settledValues) }
          if spec.panel == .illuminantSpd || has("sceneIlluminant") { IlluminantSpdGraph(values: model.settledValues) }
          if spec.panel == .edgeProfile || spec.groups.contains("adjacency") || spec.groups.contains("dir") { EdgeProfileGraph(values: model.settledValues) }
          ForEach(basic) { row($0) }
          if spec.groups.contains("adjacency"), let um = Adjacency.diffusionUm(model.settledValues) {
            Text(tr("확산 거리 \(Int(um.rounded())) µm", "Diffusion length \(Int(um.rounded())) µm"))
              .font(.caption).foregroundStyle(.secondary)
          }
          if toolLevel == .expert {
            ForEach(more) { row($0) }
          } else if !more.isEmpty {
            Button(showMore ? tr("간단히", "Less") : tr("더보기", "More") + " (\(more.count))") { showMore.toggle() }
              .buttonStyle(.link).font(.caption)
            if showMore {
              ForEach(more) { row($0) }
            }
          }
        }
        .disabled(!requirementsMet)
        .opacity(requirementsMet ? 1 : 0.45)
        .opacity(cardInactive == nil ? 1 : 0.45)
      }
    }
    .padding(.horizontal, 10)
    .padding(.vertical, enabled ? 10 : 7)
    // On: a filled card. Off: an outline only, so the stack reads at a glance.
    .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(enabled ? 0.055 : 0)))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(enabled ? 0.07 : 0.12)))
    .overlay { if let flash { FlashMark().id(flash.id) } }
  }
}

/// "Here": blinks three times, then stays lit softly while the step stays picked.
struct FlashMark: View {
  var fill = false
  @State private var level = 0.0

  var body: some View {
    let shape = RoundedRectangle(cornerRadius: fill ? 5 : 8)
    Group {
      if fill { shape.fill(Color.accentColor.opacity(0.25)) } else { shape.strokeBorder(Color.accentColor, lineWidth: 2) }
    }
    .opacity(level)
    .allowsHitTesting(false)
    .task {
      for _ in 0..<3 {
        withAnimation(.easeOut(duration: 0.12)) { level = 1 }
        try? await Task.sleep(for: .milliseconds(300))
        withAnimation(.easeIn(duration: 0.18)) { level = 0.1 }
        try? await Task.sleep(for: .milliseconds(250))
      }
      withAnimation(.easeOut(duration: 0.2)) { level = 0.6 }
    }
  }
}

/// Lightroom-style grid: right-aligned label column, then the control.
enum RowMetrics {
  static let label: CGFloat = 96
  static let value: CGFloat = 48
  static let spacing: CGFloat = 8
}

struct AlignedRow<Content: View>: View {
  let label: String
  var onLabelDoubleTap: (() -> Void)?
  @ViewBuilder let content: Content

  var body: some View {
    HStack(spacing: RowMetrics.spacing) {
      Text(label).font(.callout).foregroundStyle(.secondary)
        .lineLimit(1).minimumScaleFactor(0.7)
        .frame(width: RowMetrics.label, alignment: .trailing)
        .help(label)
        .onTapGesture(count: 2) { onLabelDoubleTap?() }
      content
    }
  }
}

struct ParamRow: View {
  @Bindable var model: EditModel
  let descriptor: ParamDescriptor
  @AppStorage(ToolLevel.key) private var toolLevel = ToolLevel.standard

  var body: some View {
    let d = descriptor
    let label = Labels.param(d.name)
    switch d.kind {
    case .bool:
      AlignedRow(label: "") {
        Toggle(label, isOn: Binding(
          get: { model.value(d.name).boolValue },
          set: { model.setAndCommit(d.name, .bool($0)) }))
        .toggleStyle(.checkbox).font(.callout)
        Spacer(minLength: 0)
      }
    case .choice:
      AlignedRow(label: label) {
        Picker(label, selection: Binding(
          get: { model.value(d.name).intValue },
          set: { model.setAndCommit(d.name, .int($0)) })) {
          // A beginner picks print or scan; process negative shows only when the photo already uses it.
          let options = Array(d.options.enumerated()).filter {
            !(d.name == "process" && toolLevel == .beginner && $0.offset == 2 && model.value(d.name).intValue != 2)
          }
          ForEach(options, id: \.offset) { i, o in Text(Labels.option(o)).tag(i) }
        }
        .labelsHidden().controlSize(.small)
      }
    case .int:
      SliderRow(
        label: label, range: d.minimum...d.maximum, step: 1,
        value: Double(model.value(d.name).intValue),
        defaultValue: Double(d.defaultInt),
        onChange: { model.set(d.name, .int(Int($0.rounded()))) },
        onBegin: model.beginInteraction,
        onCommit: { model.commit() })
    case .double:
      SliderRow(
        label: label, range: d.minimum...d.maximum, step: nil,
        value: model.value(d.name).doubleValue, defaultValue: EditModel.defaultValues[d.name]?.doubleValue ?? d.defaultValue[0],
        onChange: { model.set(d.name, .double($0)) },
        onBegin: model.beginInteraction,
        onCommit: { model.commit() })
    case .double2, .double3:
      let n = d.kind == .double2 ? 2 : 3
      let names = n == 2 ? ["1", "2"] : ["R", "G", "B"]
      VStack(alignment: .leading, spacing: 4) {
        AlignedRow(label: "") {
          Text(label).font(.callout)
          Spacer(minLength: 0)
        }
        ForEach(0..<n, id: \.self) { i in
          SliderRow(
            label: names[i], range: d.minimum...d.maximum, step: nil,
            value: model.value(d.name).vectorValue[safe: i] ?? 0, defaultValue: d.defaultValue[i],
            onChange: { v in
              var vec = model.value(d.name).vectorValue
              while vec.count < 3 { vec.append(0) }
              vec[i] = v
              model.set(d.name, .vector(vec))
            },
            onBegin: model.beginInteraction,
            onCommit: { model.commit() })
        }
      }
    case .filmStock, .printPaper:
      EmptyView()
    }
  }
}

/// Slider on the label grid with an editable readout: type a number, Return applies it
/// and leaves the field, Escape cancels. Double-click the label or the slider to reset.
struct SliderRow: View {
  let label: String
  let range: ClosedRange<Double>
  let step: Double?
  let value: Double
  let defaultValue: Double
  let onChange: (Double) -> Void
  let onBegin: () -> Void
  let onCommit: () -> Void

  @State private var text = ""
  @FocusState private var editing: Bool

  /// Physical ranges like 0...1000 µm are unusable linearly; give them a gentler curve.
  private var curved: Bool { range.lowerBound >= 0 && range.upperBound / max(abs(defaultValue), 1e-6) > 40 }

  private func toSlider(_ v: Double) -> Double {
    guard curved else { return v }
    let t = (v - range.lowerBound) / (range.upperBound - range.lowerBound)
    return sqrt(max(t, 0))
  }

  private func fromSlider(_ s: Double) -> Double {
    guard curved else { return s }
    return range.lowerBound + s * s * (range.upperBound - range.lowerBound)
  }

  private func clamped(_ v: Double) -> Double {
    var v = min(max(v, range.lowerBound), range.upperBound)
    if let step { v = (v / step).rounded() * step }
    return v
  }

  var body: some View {
    AlignedRow(label: label, onLabelDoubleTap: { onChange(defaultValue); onCommit() }) {
      ResettableSlider(
        value: toSlider(min(max(value, range.lowerBound), range.upperBound)),
        range: curved ? 0...1 : range,
        onChange: { s in onChange(clamped(fromSlider(s))) },
        onBegin: onBegin,
        onEnd: onCommit,
        onReset: { onChange(defaultValue); onCommit() })
      TextField("", text: $text)
        .textFieldStyle(.plain)
        .multilineTextAlignment(.trailing)
        .font(.callout.monospacedDigit())
        .foregroundStyle(editing ? Color.primary : Color.secondary)
        .padding(.horizontal, 3)
        .background(RoundedRectangle(cornerRadius: 3).fill(editing ? Color(nsColor: .textBackgroundColor) : .clear))
        .overlay(RoundedRectangle(cornerRadius: 3).stroke(editing ? Color.accentColor : .clear, lineWidth: 1))
        .frame(width: RowMetrics.value)
        .focused($editing)
        .onSubmit { apply() }
        .onExitCommand { text = format(value); editing = false }
        .onChange(of: editing) { _, now in
          if now { text = plain(value) } else { text = format(value) }
        }
    }
    .onAppear { text = format(value) }
    .onChange(of: value) { _, v in if !editing { text = format(v) } }
  }

  private func apply() {
    let cleaned = text.replacingOccurrences(of: ",", with: "").replacingOccurrences(of: " ", with: "")
    if let v = Double(cleaned) {
      onChange(clamped(v))
      onCommit()
    }
    editing = false
    text = format(value)
  }

  private var decimals: Int {
    if step == 1 { return 0 }
    let mag = max(abs(range.upperBound), abs(range.lowerBound))
    return mag >= 100 ? 0 : mag >= 10 ? 1 : 2
  }

  /// Editing text: no sign padding or grouping.
  private func plain(_ v: Double) -> String { String(format: "%.\(decimals)f", v) }

  /// Readout: signed ranges show "+" like Lightroom.
  private func format(_ v: Double) -> String {
    let s = plain(v)
    return range.lowerBound < 0 && v > 0 && s != plain(0) ? "+" + s : s
  }
}

/// Mini slider that, like Lightroom's, goes back to its default when double-clicked.
/// (SwiftUI's Slider swallows the clicks, so this wraps NSSlider.)
struct ResettableSlider: NSViewRepresentable {
  let value: Double
  let range: ClosedRange<Double>
  let onChange: (Double) -> Void
  let onBegin: () -> Void
  let onEnd: () -> Void
  let onReset: () -> Void

  final class View: NSSlider {
    var parent: ResettableSlider?
    /// The button is down: the knob follows the pointer and the model may lag it (see `changed`).
    private(set) var tracking = false
    private var pending: Double?
    private var lastApply = 0.0

    /// An event older than this means the main thread is behind the pointer.
    static let fresh = 0.025
    /// Behind for this long: apply anyway so the picture keeps moving.
    static let longest = 0.15

    override func mouseDown(with event: NSEvent) {
      guard let parent else { return super.mouseDown(with: event) }
      if event.clickCount >= 2 { return parent.onReset() }
      parent.onBegin()
      tracking = true
      SliderTrace.begin()
      super.mouseDown(with: event)  // tracks the drag until the button goes up
      flush()
      tracking = false
      SliderTrace.end()
      parent.onEnd()
    }

    /// While dragging, a value goes to the model only when the event is fresh. Behind the pointer
    /// (panels and the picture took longer than the mouse), the late events just move the knob,
    /// the queue drains, and the latest value goes in: the knob never waits for the redraws.
    @objc func changed(_ sender: NSSlider) {
      pending = sender.doubleValue
      guard tracking else { return flush() }
      let now = ProcessInfo.processInfo.systemUptime
      let lag = NSApp.currentEvent.map { max(now - $0.timestamp, 0) } ?? 0
      SliderTrace.event(lag: lag)
      if lag < Self.fresh || now - lastApply > Self.longest { flush() } else { flushSoon() }
    }

    private func flushSoon() {
      NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(flushLater), object: nil)
      perform(#selector(flushLater), with: nil, afterDelay: Self.fresh, inModes: [.common])
    }

    @objc private func flushLater() { flush() }

    private func flush() {
      NSObject.cancelPreviousPerformRequests(withTarget: self, selector: #selector(flushLater), object: nil)
      guard let v = pending else { return }
      pending = nil
      let t = ProcessInfo.processInfo.systemUptime
      lastApply = t
      parent?.onChange(v)
      SliderTrace.apply(ms: (ProcessInfo.processInfo.systemUptime - t) * 1000)
    }
  }

  func makeNSView(context: Context) -> View {
    let v = View()
    v.controlSize = .mini
    v.isContinuous = true
    v.trackFillColor = NSColor(white: 0.62, alpha: 1)  // neutral like Lightroom; the accent colour is busy in a long stack
    v.target = v
    v.action = #selector(View.changed(_:))
    v.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return v
  }

  func updateNSView(_ v: View, context: Context) {
    v.parent = self
    if v.minValue != range.lowerBound { v.minValue = range.lowerBound }
    if v.maxValue != range.upperBound { v.maxValue = range.upperBound }
    // Dragging: the model may hold an older value than the knob; don't pull the knob back.
    if !v.tracking, v.doubleValue != value { v.doubleValue = value }
  }
}

/// Enlarger colour head: drag in the square to set the M and Y filter shifts together.
/// Horizontal is blue <-> yellow, vertical is green <-> magenta, as the print will look.
struct ColorHeadPad: View {
  @Bindable var model: EditModel
  @State private var dragging = false
  /// When the last press began and how deep the history was then: a double-click's first press
  /// moves the head and commits, so the reset takes that entry back first.
  @State private var press: (time: TimeInterval, depth: Int) = (0, 0)

  private let mName = "filterMShift", yName = "filterYShift"
  private var mRange: ClosedRange<Double> { range(mName) }
  private var yRange: ClosedRange<Double> { range(yName) }

  private func range(_ n: String) -> ClosedRange<Double> {
    let d = Catalog.byName[n]
    return (d?.minimum ?? -60)...(d?.maximum ?? 60)
  }

  // A larger filter shift removes more of that light, so the print moves the other way.
  static let yellowSign = -1.0, magentaSign = -1.0

  var body: some View {
    GeometryReader { geo in
      let size = geo.size
      let m = model.value(mName).doubleValue, y = model.value(yName).doubleValue
      let px = (Self.yellowSign * y - yRange.lowerBound) / (yRange.upperBound - yRange.lowerBound)
      let py = 1 - (Self.magentaSign * m - mRange.lowerBound) / (mRange.upperBound - mRange.lowerBound)
      ZStack {
        LinearGradient(colors: [Color(red: 0.25, green: 0.4, blue: 1), .gray, Color(red: 1, green: 0.85, blue: 0.2)],
                       startPoint: .leading, endPoint: .trailing)
        LinearGradient(colors: [Color(red: 1, green: 0.2, blue: 0.8).opacity(0.75), .clear,
                                Color(red: 0.2, green: 0.9, blue: 0.3).opacity(0.75)],
                       startPoint: .top, endPoint: .bottom)
          .blendMode(.overlay)
        Path { p in
          p.move(to: CGPoint(x: size.width / 2, y: 0)); p.addLine(to: CGPoint(x: size.width / 2, y: size.height))
          p.move(to: CGPoint(x: 0, y: size.height / 2)); p.addLine(to: CGPoint(x: size.width, y: size.height / 2))
        }
        .stroke(Color.white.opacity(0.35), lineWidth: 0.5)
        Circle().strokeBorder(Color.white, lineWidth: 2).background(Circle().fill(Color.black.opacity(0.25)))
          .frame(width: 14, height: 14)
          .position(x: px * size.width, y: py * size.height)
        VStack {
          Text(tr("마젠타", "Magenta")).font(.caption2)
          Spacer()
          HStack { Text(tr("블루", "Blue")); Spacer(); Text(String(format: "M %+.0f  Y %+.0f", m, y)).monospacedDigit(); Spacer(); Text(tr("옐로", "Yellow")) }
            .font(.caption2)
          Spacer()
          Text(tr("그린", "Green")).font(.caption2)
        }
        .foregroundStyle(.white).shadow(radius: 1).padding(4)
      }
      .clipShape(RoundedRectangle(cornerRadius: 6))
      .contentShape(Rectangle())
      .gesture(DragGesture(minimumDistance: 0)
        .onChanged { g in
          if !dragging {
            let now = ProcessInfo.processInfo.systemUptime
            if now - press.time > NSEvent.doubleClickInterval { press = (now, model.undoStack.count) }
            model.beginInteraction()
          }
          dragging = true
          let tx = min(max(g.location.x / size.width, 0), 1), ty = min(max(g.location.y / size.height, 0), 1)
          let yv = (yRange.lowerBound + tx * (yRange.upperBound - yRange.lowerBound)) * Self.yellowSign
          let mv = (mRange.lowerBound + (1 - ty) * (mRange.upperBound - mRange.lowerBound)) * Self.magentaSign
          model.set(yName, .double(yv.rounded()))
          model.set(mName, .double(mv.rounded()))
        }
        .onEnded { _ in dragging = false; model.commit(label: tr("컬러 헤드", "Color Head")) })
      .simultaneousGesture(TapGesture(count: 2).onEnded {
        while model.undoStack.count > press.depth { model.undo() }
        model.set(yName, .double(0)); model.set(mName, .double(0)); model.commit(label: tr("컬러 헤드 초기화", "Reset Color Head"))
      })
    }
    .aspectRatio(1.6, contentMode: .fit)
    .help(tr("드래그: 색 균형 · 더블클릭: 중앙", "Drag: color balance · Double-click: center"))
  }
}

// MARK: - Lens profile picker (lensfun database)

struct LensProfilePanel: View {
  @Bindable var model: EditModel
  @State private var picking = false

  var body: some View {
    let id = model.value("lensProfileId").intValue
    let lens = LensProfile.lens(id)
    VStack(alignment: .leading, spacing: 6) {
      Button { picking.toggle() } label: {
        HStack {
          Image(systemName: "camera.aperture")
          Text(lens?.displayName ?? tr("렌즈 선택…", "Choose a lens…")).lineLimit(1).truncationMode(.middle)
          Spacer(minLength: 0)
          Image(systemName: "chevron.down").font(.caption2)
        }
        .frame(maxWidth: .infinity)
      }
      .controlSize(.small)
      .popover(isPresented: $picking, arrowEdge: .leading) {
        LensPickerList(selected: id) { e in
          picking = false
          model.set("lensProfileId", .int(e.id))
          let cur = model.value("lensFocalMm").doubleValue
          model.set("lensFocalMm", .double(LensProfile.clampedFocal(e, e.isZoom ? cur : e.f.first ?? cur)))
          if !model.value("lensProfileEnabled").boolValue { model.set("lensProfileEnabled", .bool(true)) }
          model.commit(label: tr("렌즈", "Lens") + " " + e.displayName)
        }
      }
      if let lens {
        Text(lensCaption(lens)).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
        if lens.isZoom {
          SliderRow(
            label: tr("초점 거리 (mm)", "Focal Length (mm)"), range: lens.f[0]...lens.f[1], step: 1,
            value: LensProfile.clampedFocal(lens, model.value("lensFocalMm").doubleValue),
            defaultValue: lens.f[0],
            onChange: { model.set("lensFocalMm", .double($0.rounded())) },
            onBegin: model.beginInteraction,
            onCommit: { model.commit() })
        }
      }
    }
  }

  private func lensCaption(_ e: LensEntry) -> String {
    var parts: [String] = []
    if !e.mt.isEmpty { parts.append(e.mt.joined(separator: ", ")) }
    parts.append(String(format: tr("보정 크롭 %.2g", "calibrated at crop %.2g"), e.c))
    var have: [String] = []
    if !e.d.isEmpty { have.append(tr("왜곡", "distortion")) }
    if !e.t.isEmpty { have.append(tr("색수차", "TCA")) }
    if !e.v.isEmpty { have.append(tr("감광", "vignetting")) }
    parts.append(have.joined(separator: " · "))
    return parts.joined(separator: " — ")
  }
}

private struct LensPickerList: View {
  let selected: Int
  let onPick: (LensEntry) -> Void
  @State private var query = ""
  @State private var fullFrameOnly = true
  /// LensEntry ids, one per line (the same format as "favoriteStocks").
  @AppStorage("favoriteLenses") private var favoritesRaw = ""

  private var favorites: Set<Int> { Set(favoritesRaw.split(separator: "\n").compactMap { Int($0) }) }
  private func toggleFavorite(_ id: Int) {
    var f = favorites
    if f.contains(id) { f.remove(id) } else { f.insert(id) }
    favoritesRaw = f.sorted().map(String.init).joined(separator: "\n")
  }

  private var results: [LensEntry] {
    let words = query.lowercased().split(separator: " ").map(String.init)
    return LensProfile.lenses.filter { e in
      if fullFrameOnly && e.c > 1.1 { return false }
      guard !words.isEmpty else { return true }
      let hay = "\(e.m) \(e.n) \(e.mt.joined(separator: " "))".lowercased()
      return words.allSatisfy { hay.contains($0) }
    }
  }

  var body: some View {
    let list = results
    VStack(alignment: .leading, spacing: 8) {
      TextField(tr("렌즈 검색 (예: nikkor 50 1.4)", "Search lenses (e.g. nikkor 50 1.4)"), text: $query)
        .textFieldStyle(.roundedBorder)
      Toggle(tr("풀프레임 이상 보정만", "Full-frame calibrations only"), isOn: $fullFrameOnly)
        .controlSize(.small)
      List {
        // Favourites on top while browsing; a search lists everything in one run.
        let favs = query.isEmpty ? favorites.compactMap(LensProfile.lens).sorted { $0.displayName < $1.displayName } : []
        if !favs.isEmpty {
          Section(tr("즐겨찾기", "Favorites")) {
            ForEach(favs) { row($0) }
          }
          Section(tr("전체", "All")) {
            ForEach(list.prefix(300)) { row($0) }
          }
        } else {
          ForEach(list.prefix(300)) { row($0) }
        }
      }
      .frame(minHeight: 320)
      Text(String(format: tr("%d개 · lensfun 데이터베이스 (CC BY-SA 3.0)", "%d lenses · lensfun database (CC BY-SA 3.0)"), list.count))
        .font(.caption2).foregroundStyle(.secondary)
    }
    .padding(12)
    .frame(width: 380, height: 460)
  }

  private func row(_ e: LensEntry) -> some View {
    HStack {
      Button { toggleFavorite(e.id) } label: {
        Image(systemName: favorites.contains(e.id) ? "star.fill" : "star")
          .foregroundStyle(favorites.contains(e.id) ? Color.accentColor : Color.secondary)
      }
      .buttonStyle(.borderless)
      .help(tr("즐겨찾기", "Favorite"))
      Button { onPick(e) } label: {
        HStack {
          VStack(alignment: .leading, spacing: 1) {
            Text(e.displayName).lineLimit(1)
            Text(e.mt.joined(separator: ", ")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
          }
          Spacer()
          if e.id == selected { Image(systemName: "checkmark") }
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
    }
  }
}
