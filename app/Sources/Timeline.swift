// PhotoEmul - native editor for spektrafilm (GPL-3.0-or-later)
// History timeline: one icon per step under the canvas, like a CAD feature timeline.
// The marker sits after the last applied step; drag it to see the photo at that point. Clicking an
// icon picks the step and shows its tool in the inspector. Steps right of the marker are the redo stack and go away when a value changes there.

import AppKit
import SwiftUI

/// Which process stage a param belongs to, for the step icon and colour. Taken from the
/// process-order layout so it follows the inspector's chapters.
enum TimelineStage {
  struct Info { let title: String; let color: Color; let symbol: String }

  private static let symbols = [
    "result": "slider.horizontal.3", "film": "film", "shoot": "camera", "develop": "drop",
    "print": "photo", "scan": "scanner", "finish": "wand.and.stars",
  ]

  private static var cache: (Bool, [String: Info], [String: String], [String: Int])?

  private static var byParam: [String: Info] { maps.info }

  /// Where a param sits in the process order (stage, card, row), for listing a step's changes.
  static func processOrder(_ name: String) -> Int { maps.order[name] ?? .max }

  static func stageTitle(_ name: String) -> String? { byParam[name]?.title }

  /// The tool (inspector card) each param sits in; film and paper are their own.
  private static var toolByParam: [String: String] { maps.tool }

  private static var maps: (info: [String: Info], tool: [String: String], order: [String: Int]) {
    if let (ko, map, tool, order) = cache, ko == L10n.isKorean { return (map, tool, order) }
    var map: [String: Info] = [:], tool: [String: String] = [:], order: [String: Int] = [:]
    let layout = PanelLayouts.resolve(PanelLayouts.workflow(), key: PanelLayouts.workflowKey)
    for stage in layout.stages {
      let info = Info(title: stage.title ?? "", color: Color(hex: stage.color) ?? .secondary,
                      symbol: symbols[stage.id] ?? "circle")
      for spec in stage.specs {
        for name in PanelLayouts.shown(spec) where map[name] == nil {
          map[name] = info
          tool[name] = spec.id
          order[name] = order.count
        }
      }
      if stage.id == "film" { map["film"] = info; order["film"] = order.count }
      if stage.id == "print" { map["paper"] = info; order["paper"] = order.count }
    }
    cache = (L10n.isKorean, map, tool, order)
    return (map, tool, order)
  }

  /// The tools whose values differ between two states (a param in no card counts as its own tool).
  static func tools(from old: [String: ParamValue], to new: [String: ParamValue]) -> Set<String> {
    Set(Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }.map { toolByParam[$0] ?? $0 })
  }

  /// The stage of the params that differ between two states. A step over several stages (Reset
  /// All, a preset, a merge) gets a neutral icon instead of its first param's stage: a reset when
  /// every value it changed went back to its default.
  static func info(from old: [String: ParamValue], to new: [String: ParamValue]) -> Info? {
    let changed = Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }
      .sorted { (processOrder($0), $0) < (processOrder($1), $1) }
    var stages: [Info] = []
    for info in changed.compactMap({ byParam[$0] }) where !stages.contains(where: { $0.title == info.title }) {
      stages.append(info)
    }
    guard stages.count > 1 else { return stages.first }
    let reset = changed.allSatisfy { n in
      guard let d = EditModel.defaultValues[n] ?? Catalog.byName[n]?.defaultParamValue else { return new[n] == nil }
      return (new[n] ?? d) == d
    }
    let list = stages.map(\.title).joined(separator: ", ")
    return Info(title: (reset ? tr("초기화", "Reset") : tr("여러 단계", "Several stages")) + " · " + list,
                color: .secondary, symbol: reset ? "arrow.counterclockwise" : "square.grid.2x2")
  }
}

/// "Label: before → after" lines for a step's tooltip.
enum StepChanges {
  static let maxLines = 8

  static func lines(from old: [String: ParamValue], to new: [String: ParamValue]) -> [String] {
    // In process order; a step over several stages gets a heading per stage.
    let changed = Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }
      .sorted { (TimelineStage.processOrder($0), $0) < (TimelineStage.processOrder($1), $1) }
    let headed = Set(changed.map { TimelineStage.stageTitle($0) ?? "" }).count > 1
    var lines: [String] = [], stage: String?
    for name in changed.prefix(maxLines) {
      let s = TimelineStage.stageTitle(name) ?? tr("기타", "Other")
      if headed && s != stage { lines.append("▸ " + s); stage = s }
      lines.append((headed ? "   " : "") + "\(label(name)): \(text(name, old[name])) → \(text(name, new[name]))")
    }
    if changed.count > maxLines { lines.append(tr("외 \(changed.count - maxLines)개", "+\(changed.count - maxLines) more")) }
    return lines
  }

  private static func label(_ name: String) -> String {
    switch name {
    case "film": return tr("필름", "Film")
    case "paper": return tr("인화지", "Paper")
    default: return Labels.param(name)
    }
  }

  private static func text(_ name: String, _ value: ParamValue?) -> String {
    let d = Catalog.byName[name]
    guard let v = value ?? d?.defaultParamValue else { return "–" }
    switch (name, v) {
    case ("film", .int(let i)): return FilmInfo.displayName(Catalog.films[safe: i] ?? "")
    case ("paper", .int(let i)): return FilmInfo.displayName(Catalog.papers[safe: i] ?? "")
    case ("lensProfileId", .int(let i)): return LensProfile.lens(i).map { "\($0.m) \($0.n)" } ?? (i == 0 ? "–" : "\(i)")
    case (_, .bool(let b)): return b ? tr("켬", "On") : tr("끔", "Off")
    case (_, .int(let i)):
      if d?.kind == .choice, let o = d?.options[safe: i] { return Labels.option(o) }
      return "\(i)"
    case (_, .double(let x)): return number(x)
    case (_, .vector(let xs)): return xs.map(number).joined(separator: ", ")
    }
  }

  private static func number(_ x: Double) -> String {
    let s = String(format: abs(x) >= 100 ? "%.0f" : abs(x) >= 10 ? "%.1f" : "%.2f", x)
    return s.contains(".") ? String(s.reversed().drop { $0 == "0" }.drop { $0 == "." }.reversed()) : s
  }
}

struct HistoryTimeline: View {
  @Bindable var model: EditModel
  @State private var scrubbing = false
  /// While dragging: the tile under the marker. The photo and history only follow once it
  /// rests there for `EditModel.scrubPause`; passing over tiles just moves the marker.
  @State private var scrubMark: Int?
  @State private var scrubWork: DispatchWorkItem?
  @State private var hovering = false
  /// The tile under the pointer and the strip's left edge in the bar, for the hover card.
  /// PHOTOEMUL_TIMELINE_HOVER=i shows tile i's card from the start, for snapshot checks.
  @State private var hoverItem = ProcessInfo.processInfo.environment["PHOTOEMUL_TIMELINE_HOVER"].flatMap(Int.init)
  @State private var stripX = 0.0
  /// Picked steps: a click picks one (its tool is opened and flashed in the inspector), ⌘-click
  /// adds or drops one, ⇧-click picks the run from the last pick.
  @State private var selection: Set<Int> = []
  @State private var anchor: Int?
  @State private var renaming: StepGroup?
  @State private var newName = ""
  static let shownKey = "timelineShown"
  /// 0 all steps, 1 hide AI steps, 2 AI steps only.
  @AppStorage("timelineAIFilter") private var aiFilter = 0
  private let tile = 28.0
  private let pitch = 34.0
  private let stripHeight = 50.0
  /// Tiles sit at the top of the strip, leaving room below for the rail and the marker's foot.
  private static let tileTop = 4.0
  /// Centre of the rail under the tiles; the marker's foot rides on it.
  private static let railY = 40.0
  /// The tile row's height; the buttons either side are centred on it, not on the whole strip.
  private var rowHeight: Double { Self.tileTop * 2 + tile }

  /// One tile: a step, or a collapsed group standing for all its steps. Tile 0 is the photo as opened.
  private struct Item {
    let steps: ClosedRange<Int>
    let group: StepGroup?
  }

  private func items(_ count: Int) -> [Item] {
    var out = [Item(steps: 0...0, group: nil)]
    guard count > 0 else { return out }
    for k in 1...count {
      let g = model.historyEntry(k).group
      if let g, g.collapsed, let last = out.last, last.group?.id == g.id {
        out[out.count - 1] = Item(steps: last.steps.lowerBound...k, group: g)
      } else {
        out.append(Item(steps: k...k, group: g))
      }
    }
    return aiFilter == 0 ? out : out.filter { $0.steps.lowerBound == 0 || isAI($0.steps) == (aiFilter == 2) }
  }

  private func isAI(_ r: ClosedRange<Int>) -> Bool {
    r.lowerBound > 0 && r.contains { model.historyEntry($0).isAI }
  }

  var body: some View {
    let count = model.historyCount
    let items = items(count)
    let scrubTo = scrubMark.flatMap { items.indices.contains($0) ? $0 : nil }
    // While dragging only the marker moves; the current tile follows once the photo does.
    let position = model.historyPosition
    let mark = scrubTo ?? items.firstIndex { $0.steps.contains(position) } ?? 0
    HStack(alignment: .top, spacing: 8) {
      HStack(spacing: 0) {
        button("backward.end.fill", tr("처음으로", "To Start") + " ⌥⌘←", disabled: position == 0) { model.moveHistory(to: 0) }
        button("chevron.left", tr("한 단계 뒤로", "Step Back") + " ⌥← · ⌘Z", disabled: position == 0) { model.undo() }
        button("chevron.right", tr("한 단계 앞으로", "Step Forward") + " ⌥→ · ⇧⌘Z", disabled: position == count) { model.redo() }
        button("forward.end.fill", tr("끝으로", "To End") + " ⌥⌘→", disabled: position == count) { model.moveHistory(to: count) }
      }
      .frame(height: rowHeight)
      ScrollViewReader { proxy in
        ScrollView(.horizontal, showsIndicators: false) {
          strip(items, position: position, mark: mark)
            .padding(.horizontal, 4)
        }
        // Not while dragging: scrolling under the pointer would move the marker again.
        .onChange(of: mark) { _, i in if !scrubbing { proxy.scrollTo(i, anchor: .center) } }
        .onAppear { proxy.scrollTo(mark, anchor: .center) }
      }
      // A new or dropped step renumbers the strip: let go of the picks.
      .onChange(of: count) { pick([]) }
      Group {
      // Otherwise hidden steps look like steps that were never recorded.
      if aiFilter != 0 {
        Button { aiFilter = 0 } label: {
          Label(aiFilter == 1 ? tr("AI 숨김", "AI Hidden") : tr("AI만", "AI Only"), systemImage: "line.3.horizontal.decrease.circle.fill")
            .font(.caption).lineLimit(1).fixedSize()
        }
        .buttonStyle(.borderless).foregroundStyle(.orange)
        .cardTip(tr("타임라인 필터가 켜져 있어 일부 단계가 숨겨져 있습니다. 누르면 모두 보입니다.",
                    "A timeline filter hides some steps. Click to show all."), trailing: true)
      }
      if position < count {
        Text(tr("여기서 바꾸면 뒤 단계 \(count - position)개는 지워집니다", "Changing here drops the \(count - position) later steps"))
          .font(.caption).foregroundStyle(.orange).lineLimit(1).fixedSize()
          .cardTip(tr("과거 시점을 보고 있습니다. 값을 바꾸면 오른쪽 단계들이 지워지고 여기서 새로 이어집니다.",
                      "You are looking at a past point. Changing a value drops the steps on the right and continues from here."), trailing: true)
      }
      Text("\(position) / \(count)").font(.caption).monospacedDigit().foregroundStyle(.secondary).fixedSize()
      button("photo.badge.plus", tr("이 시점으로 스냅샷 만들기", "Snapshot at the Marker"), disabled: false, trailing: true) {
        model.addSnapshot(atHistory: position)
      }
      }
      .frame(height: rowHeight)
    }
    .padding(.horizontal, 8)
    .frame(height: stripHeight)
    .coordinateSpace(name: Self.space)
    // The card sits above the hovered tile, left-aligned with it, over the canvas; outside the
    // scroll view so it is not clipped.
    .overlay(alignment: .topLeading) {
      if let i = hoverItem, !scrubbing, items.indices.contains(i) {
        StepCard(lines: card(items[i]), thumb: model.stepThumbs[items[i].steps.upperBound]?.image)
          .fixedSize()
          .frame(width: 0, height: 0, alignment: .bottomLeading)
          .offset(x: max(stripX + Double(i) * pitch + (pitch - tile) / 2, 4), y: -4)
          .allowsHitTesting(false)
          .transition(.opacity)
      }
    }
    .onChange(of: hoverItem) { _, i in if let i, items.indices.contains(i) { model.wantStepThumb(items[i].steps.upperBound) } }
    .animation(.easeOut(duration: 0.12), value: hoverItem)
    .alert(tr("그룹 이름", "Group Name"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
      TextField(tr("이름", "Name"), text: $newName)
      Button(tr("확인", "OK")) {
        let name = newName.trimmingCharacters(in: .whitespaces)
        if let g = renaming, !name.isEmpty { model.updateHistoryGroup(g.id) { $0.name = name } }
        renaming = nil
      }
      Button(tr("취소", "Cancel"), role: .cancel) { renaming = nil }
    }
  }

  private static let space = "historyTimeline"
  private static let stripSpace = "historyStrip"
  /// Points either side of the marker's foot that grab it.
  private static let grab = 14.0
  /// The marker's round foot, the only part that drags.
  private static let knob = 13.0
  /// Top of the marker's grab: everything under the tiles, so the small foot is easy to hit.
  private var grabTop: Double { Self.tileTop + tile }

  private func button(_ symbol: String, _ help: String, disabled: Bool, trailing: Bool = false,
                      action: @escaping () -> Void) -> some View {
    Button(action: action) { Image(systemName: symbol).frame(width: 22, height: 22) }
      .buttonStyle(.borderless).disabled(disabled).cardTip(help, trailing: trailing)
  }

  /// The marker sits after tile `mark`, the one holding the current position.
  private func strip(_ items: [Item], position: Int, mark: Int) -> some View {
    HStack(spacing: 0) {
      ForEach(items.indices, id: \.self) { i in
        slot(items[i], index: i, position: position).frame(width: pitch, height: stripHeight).id(i)
      }
    }
    .background(alignment: .topLeading) { groupRuns(items) }
    .background(alignment: .topLeading) { rail(items.count, mark: mark) }
    .overlay(alignment: .topLeading) { marker.offset(x: Double(mark + 1) * pitch - Self.knob / 2).allowsHitTesting(false) }
    // Only the round foot moves the marker; its grab sits above the tiles' context-menu clicks.
    .overlay(alignment: .bottomLeading) {
      Color.clear.frame(width: Self.grab * 2, height: stripHeight - grabTop).contentShape(Rectangle())
        .offset(x: Double(mark + 1) * pitch - Self.grab)
        .highPriorityGesture(scrubGesture(items))
    }
    .contentShape(Rectangle())
    .coordinateSpace(name: Self.stripSpace)
    .onGeometryChange(for: Double.self) { $0.frame(in: .named(Self.space)).minX } action: { stripX = $0 }
    // The move cursor only on the marker (or while dragging it); the tiles keep the arrow.
    .onContinuousHover { phase in
      var onMarker = false
      if scrubbing { setMarkerCursor(true); return }
      if case .active(let p) = phase {
        onMarker = abs(p.x - Double(mark + 1) * pitch) <= Self.grab && p.y >= grabTop
        let i = Int((p.x / pitch).rounded(.down))
        let inTile = abs(p.x - (Double(i) + 0.5) * pitch) <= tile / 2 && p.y <= Self.tileTop + tile
        hoverItem = inTile && !onMarker && items.indices.contains(i) ? i : nil
      } else {
        hoverItem = nil
      }
      setMarkerCursor(onMarker || scrubbing)
    }
    .onDisappear { setMarkerCursor(false); hoverItem = nil; pick([]) }
    // Click a tile to pick it. Dragging the marker's foot moves into the past and back; the marker
    // snaps to the nearest gap and the photo follows once it rests there.
    .gesture(
      DragGesture(minimumDistance: 0).onEnded { g in
        guard abs(g.translation.width) < 4 else { return }
        let i = Int((g.location.x / pitch).rounded(.down))
        if i >= 1, items.indices.contains(i) { click(items[i]) }
      }
    )
  }

  private func scrubGesture(_ items: [Item]) -> some Gesture {
    DragGesture(minimumDistance: 0, coordinateSpace: .named(Self.stripSpace))
      .onChanged { g in
        setMarkerCursor(true)
        if !scrubbing {
          scrubbing = true
          model.beginHistoryScrub()
        }
        // The marker stands between tiles: snap it to the nearest gap, so grabbing it doesn't jump a tile.
        let i = min(max(Int((g.location.x / pitch).rounded()) - 1, 0), items.count - 1)
        guard i != scrubMark else { return }
        scrubMark = i
        scrubWork?.cancel()
        let k = items[i].steps.upperBound
        let work = DispatchWorkItem { model.moveHistory(to: k) }
        scrubWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + EditModel.scrubPause, execute: work)
      }
      .onEnded { _ in
        if scrubbing {
          scrubWork?.cancel()
          scrubWork = nil
          let k = scrubMark.flatMap { items.indices.contains($0) ? items[$0].steps.upperBound : nil } ?? model.historyPosition
          scrubMark = nil
          scrubbing = false
          setMarkerCursor(false)
          model.endHistoryScrub(at: k)
        }
      }
  }

  /// A soft band behind each open group, with a line under it.
  private func groupRuns(_ items: [Item]) -> some View {
    var runs: [(start: Int, count: Int)] = []
    for (i, item) in items.enumerated() {
      guard let g = item.group, !g.collapsed else { continue }
      if let last = runs.last, last.start + last.count == i, items[i - 1].group?.id == g.id {
        runs[runs.count - 1].count += 1
      } else {
        runs.append((i, 1))
      }
    }
    return ZStack(alignment: .topLeading) {
      ForEach(runs, id: \.start) { run in
        RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.07))
          .overlay(alignment: .bottom) {
            Capsule().fill(Color.secondary.opacity(0.8)).frame(height: 2).padding(.horizontal, 8).offset(y: -1)
          }
          .frame(width: Double(run.count) * pitch - 2, height: tile + 6)
        .offset(x: Double(run.start) * pitch + 1, y: Self.tileTop - 3)
      }
    }
  }

  private func click(_ item: Item) {
    let steps = Set(item.steps)
    let flags = NSEvent.modifierFlags
    if flags.contains(.command) {
      pick(steps.isSubset(of: selection) ? selection.subtracting(steps) : selection.union(steps))
      anchor = item.steps.upperBound
    } else if flags.contains(.shift), let a = anchor {
      pick(Set(min(a, item.steps.lowerBound)...max(a, item.steps.upperBound)))
    } else if selection == steps {
      pick([])
    } else {
      pick(steps, show: item.steps)
      anchor = item.steps.upperBound
    }
  }

  /// A plain click on one tile opens its tool in the inspector (`show`); adding picks does not.
  private func pick(_ steps: Set<Int>, show: ClosedRange<Int>? = nil) {
    selection = steps
    if steps.isEmpty { anchor = nil }
    model.spotlight(steps: show)
  }

  /// The steps as one unbroken run, if they are one.
  private func run(_ steps: Set<Int>) -> ClosedRange<Int>? {
    guard let a = steps.min(), let b = steps.max(), b - a + 1 == steps.count else { return nil }
    return a...b
  }

  /// A line from the tiles' top edge down between them to a hollow handle on the rail.
  private var marker: some View {
    VStack(spacing: 0) {
      Rectangle().fill(Color.accentColor).frame(width: 2, height: Self.railY - Self.knob / 2 - Self.tileTop)
      Circle().strokeBorder(Color.accentColor, lineWidth: 2)
        .background(Circle().fill(Color(nsColor: .windowBackgroundColor)))
        .frame(width: Self.knob, height: Self.knob)
    }
    .padding(.top, Self.tileTop)
  }

  /// The rail from the first tile to the end: filled up to the marker, greyed after it.
  private func rail(_ count: Int, mark: Int) -> some View {
    HStack(spacing: 0) {
      Capsule().fill(Color.accentColor).frame(width: Double(mark + 1) * pitch - pitch / 2)
      Capsule().fill(Color.secondary.opacity(0.25))
    }
    .frame(width: Double(count) * pitch - pitch / 2, height: 2)
    .offset(x: pitch / 2, y: Self.railY - 1)
  }

  private func setMarkerCursor(_ on: Bool) {
    // Set on every event, like PanelEdge: AppKit resets the cursor as the marker moves under the
    // pointer, and a one-time push lost to that made the cursor flicker.
    if on { NSCursor.resizeLeftRight.set() } else if hovering { NSCursor.arrow.set() }
    hovering = on
  }

  private func card(_ item: Item) -> StepCard.Lines {
    let r = item.steps
    guard r.lowerBound > 0 else {
      return .init(title: model.historyName(0), stage: nil, changes: [],
                   hint: tr("끌기: 시점 이동 · 우클릭: 더 보기", "Drag to scrub · right-click for more"))
    }
    let old = model.historyState(r.lowerBound - 1), new = model.historyState(r.upperBound)
    var title = model.historyName(r.lowerBound)
    if let g = item.group {
      title = r.count > 1 ? "\(g.name) · #\(r.lowerBound)–#\(r.upperBound) (" + tr("\(r.count)단계", "\(r.count) steps") + ")"
        : title + " · " + g.name
    }
    let notes = r.compactMap { model.historyEntry($0).note }.map { tr("왜: ", "Why: ") + $0 }
    return .init(title: title, stage: TimelineStage.info(from: old, to: new)?.title,
                 changes: StepChanges.lines(from: old, to: new) + notes,
                 hint: tr("클릭: 도구 보기 · ⌘/⇧클릭: 여러 개 · 끌기: 시점 이동 · 우클릭: 합치기·그룹·삭제",
                          "Click: show the tool · ⌘/⇧-click: several · drag to scrub · right-click: compact, group, delete"))
  }

  @ViewBuilder
  private func slot(_ item: Item, index i: Int, position: Int) -> some View {
    let r = item.steps
    let info = r.lowerBound == 0 ? nil
      : TimelineStage.info(from: model.historyState(r.lowerBound - 1), to: model.historyState(r.upperBound))
    let folded = r.count > 1
    let current = r.contains(position) && (r.lowerBound > 0 || position == 0)
    let shape = RoundedRectangle(cornerRadius: 6)
    let picked = r.lowerBound > 0 && Set(r).isSubset(of: selection)
    let ai = isAI(r)
    shape.fill(current ? Color.accentColor.opacity(0.22)
               : ai ? Color.orange.opacity(hoverItem == i ? 0.3 : 0.18) : Color.primary.opacity(hoverItem == i ? 0.12 : 0.06))
      .overlay(shape.strokeBorder(current ? Color.accentColor : ai ? Color.orange : Color.primary.opacity(0.16),
                                  lineWidth: current ? 1.5 : 1))
      .overlay(alignment: .topLeading) {
        if ai { Text("✦").font(.system(size: 8, weight: .bold)).foregroundStyle(.orange).offset(x: -3, y: -4) }
      }
      // A collapsed group looks like a small stack of tiles, with its step count.
      .background {
        if folded { shape.strokeBorder(Color.primary.opacity(0.3), lineWidth: 1).offset(x: 2.5, y: -2.5) }
      }
      .overlay(
        Image(systemName: r.lowerBound == 0 ? "photo" : folded ? "square.stack.3d.up.fill" : info?.symbol ?? "circle")
          .font(.system(size: 12, weight: .semibold))
          .foregroundStyle(r.lowerBound == 0 ? Color.secondary : info?.color ?? .secondary)
      )
      .overlay(alignment: .bottomTrailing) {
        if folded {
          Text("\(r.count)").font(.system(size: 8, weight: .bold)).monospacedDigit()
            .padding(.horizontal, 3).background(Capsule().fill(Color.secondary.opacity(0.35)))
            .offset(x: 4, y: 1)
        }
      }
      .frame(width: tile, height: tile)
      .opacity(r.lowerBound > position ? 0.4 : 1)
      .overlay {
        if picked {
          RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor, lineWidth: 2)
            .frame(width: tile + 5, height: tile + 5)
        }
      }
      .padding(.top, Self.tileTop)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
      .contentShape(Rectangle())
      .contextMenu { menu(item) }
  }

  /// Right-click: on a picked tile the menu acts on all picks, otherwise on that tile.
  @ViewBuilder
  private func menu(_ item: Item) -> some View {
    let k = item.steps.upperBound
    Button(tr("여기로 이동", "Go Here")) { model.moveHistory(to: k) }
    Button(tr("이 단계로 스냅샷 만들기", "Create Snapshot from This Step")) { model.addSnapshot(atHistory: k) }
    Button(tr("이 시점과 비교", "Compare with This Point")) { model.compare(withHistory: k) }
    Picker(tr("AI 단계", "AI Steps"), selection: $aiFilter) {
      Text(tr("모두 보기", "Show All")).tag(0)
      Text(tr("AI 숨기기", "Hide AI")).tag(1)
      Text(tr("AI만", "AI Only")).tag(2)
    }
    if item.steps.lowerBound > 0, item.steps.upperBound <= model.historyCount {
      let own = Set(item.steps)
      // The selection can still hold steps a history edit just removed.
      let targets = (own.isSubset(of: selection) ? selection : own).filter { (1...model.historyCount).contains($0) }
      let r = run(targets)
      let groups = Set(targets.map { model.historyEntry($0).group?.id })
      Divider()
      // Only neighbouring steps of the same tool merge; other tools keep their own steps.
      if let r, r.count > 1, case let runs = model.compactRuns(r), runs.count < r.count {
        Button(tr("같은 도구끼리 합치기 (\(r.count) → \(runs.count)단계)", "Compact Same-Tool Steps (\(r.count) → \(runs.count))")) {
          model.compactHistorySteps(r)
        }
      }
      // Already exactly one whole group: only the group items below make sense.
      let wholeGroup = groups.count == 1 && (groups.first ?? nil).map { model.historySteps(inGroup: $0) == targets } == true
      if let r, !wholeGroup {
        Button(tr("그룹으로 묶기", "Group")) { model.groupHistorySteps(r) }
      }
      if groups.contains(where: { $0 != nil }), !wholeGroup {
        Button(tr("그룹에서 빼기", "Remove from Group")) { model.ungroupHistorySteps(targets) }
      }
      if let g = item.group {
        Divider()
        Button(g.collapsed ? tr("그룹 펼치기", "Expand Group") : tr("그룹 접기", "Collapse Group")) {
          model.updateHistoryGroup(g.id) { $0.collapsed.toggle() }
        }
        Button(tr("그룹 이름 바꾸기…", "Rename Group…")) { newName = g.name; renaming = g }
        Button(tr("그룹 해제 (단계는 남김)", "Ungroup (Keep Steps)")) { model.ungroupHistorySteps(model.historySteps(inGroup: g.id)) }
        Button(tr("그룹 삭제 (단계까지)", "Delete Group and Its Steps"), role: .destructive) {
          model.deleteHistorySteps(model.historySteps(inGroup: g.id))
        }
      }
      Divider()
      Button(targets.count > 1 ? tr("단계 \(targets.count)개 삭제", "Delete \(targets.count) Steps") : tr("이 단계 삭제", "Delete This Step"),
             role: .destructive) { model.deleteHistorySteps(targets) }
    }
  }
}


/// The hover card of a step: name and stage, "before → after" lines, then what the mouse does.
struct StepCard: View {
  struct Lines { let title: String; let stage: String?; let changes: [String]; let hint: String }
  let lines: Lines
  var thumb: CGImage? = nil  // the step's look (EditModel.stepThumbs), as the iPad card shows it

  var body: some View {
    VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        Text(lines.title).font(.system(size: 12, weight: .semibold))
        if let stage = lines.stage, !stage.isEmpty {
          Text("(\(stage))").font(.system(size: 11)).foregroundStyle(.secondary)
        }
      }
      if let thumb { Image(decorative: thumb, scale: 1).resizable().scaledToFit().frame(width: 220).cornerRadius(5).padding(.vertical, 2) }
      ForEach(Array(lines.changes.enumerated()), id: \.offset) { _, line in
        Text(line).font(.system(size: 11).monospacedDigit()).foregroundStyle(.secondary)
      }
      Text(lines.hint).font(.system(size: 10)).foregroundStyle(.tertiary).padding(.top, 2)
    }
    .padding(.horizontal, 10)
    .padding(.vertical, 7)
    .background(RoundedRectangle(cornerRadius: 7).fill(.regularMaterial))
    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.18)))
    .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
  }
}

/// The bar's own tooltip: the step card's look, above the control after a short wait. Trailing
/// cards line up with the control's right edge so they stay inside the window.
private struct CardTip: ViewModifier {
  let text: String
  let trailing: Bool
  @State private var shown = false
  @State private var wait: Task<Void, Never>?

  func body(content: Content) -> some View {
    content
      .onHover { inside in
        wait?.cancel()
        if inside {
          wait = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            if !Task.isCancelled { shown = true }
          }
        } else {
          shown = false
        }
      }
      .onDisappear { wait?.cancel(); shown = false }
      .overlay(alignment: trailing ? .topTrailing : .topLeading) {
        if shown {
          TipCard(text: text)
            .fixedSize()
            .frame(width: 0, height: 0, alignment: trailing ? .bottomTrailing : .bottomLeading)
            .offset(y: -8)
            .allowsHitTesting(false)
            .transition(.opacity)
        }
      }
      .animation(.easeOut(duration: 0.12), value: shown)
  }
}

private struct TipCard: View {
  let text: String
  var body: some View {
    Text(text).font(.system(size: 11))
      .frame(maxWidth: 320, alignment: .leading).fixedSize(horizontal: false, vertical: true)
      .padding(.horizontal, 10).padding(.vertical, 6)
      .background(RoundedRectangle(cornerRadius: 7).fill(.regularMaterial))
      .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Color.primary.opacity(0.18)))
      .shadow(color: .black.opacity(0.3), radius: 8, y: 3)
  }
}

extension View {
  fileprivate func cardTip(_ text: String, trailing: Bool = false) -> some View {
    modifier(CardTip(text: text, trailing: trailing))
  }
}
