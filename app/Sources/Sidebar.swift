// PhotoEmul - native editor for spektrafilm (GPL-3.0-or-later)
// Left picker docked beside the canvas: film and paper browsers with live thumbnails, presets.
// History lives in a toolbar popover.

import AppKit
import SwiftUI
import UniformTypeIdentifiers

enum SidebarTab: String, CaseIterable, Identifiable {
  case film, paper, preset, ai
  var id: String { rawValue }
  var title: String {
    switch self {
    case .film: return tr("필름", "Film")
    case .paper: return tr("인화지", "Paper")
    case .preset: return tr("프리셋", "Presets")
    case .ai: return "AI"
    }
  }
}

/// Docked, not floating: the canvas shrinks and the photo re-fits, so the picker never covers it.
struct PickerPanel: View {
  @Bindable var model: EditModel
  @AppStorage("pickerWidth") private var width = 300.0
  /// Narrower than the chosen width when the window is too narrow for both panels and the canvas.
  var maxWidth = Double.infinity
  // Card size and spacing are remembered per tab.
  // Until moved, they start from Settings › Film Panel's default size and spacing.
  @AppStorage private var filmCard: Double
  @AppStorage private var filmGap: Double
  @AppStorage private var paperCard: Double
  @AppStorage private var paperGap: Double
  @AppStorage(FilmPanel.cardStyleKey) private var cardStyle = FilmPanel.CardStyle.photo.rawValue

  init(model: EditModel, maxWidth: Double = .infinity) {
    _model = Bindable(model)
    self.maxWidth = maxWidth
    _filmCard = AppStorage(wrappedValue: FilmPanel.cardSize, "pickerCard.film")
    _filmGap = AppStorage(wrappedValue: FilmPanel.cardGap, "pickerGap.film")
    _paperCard = AppStorage(wrappedValue: FilmPanel.cardSize, "pickerCard.paper")
    _paperGap = AppStorage(wrappedValue: FilmPanel.cardGap, "pickerGap.paper")
  }

  static let widthRange = 220.0...720.0

  private var card: Binding<Double> { model.sidebarTab == .paper ? $paperCard : $filmCard }
  private var gap: Binding<Double> { model.sidebarTab == .paper ? $paperGap : $filmGap }

  var body: some View {
    HStack(spacing: 0) {
      // No tab header: the recipe bar above already switches film / paper / presets.
      VStack(spacing: 0) {
        switch model.sidebarTab {
        case .film: StockBrowser(model: model, isFilm: true, cardSize: filmCard, gap: filmGap)
        case .paper: StockBrowser(model: model, isFilm: false, cardSize: paperCard, gap: paperGap)
        case .preset: PresetList(model: model)
        case .ai: AIPanel()
        }
        if model.sidebarTab == .film || model.sidebarTab == .paper {
          Divider()
          HStack(spacing: 6) {
            // A list has no card size, only row spacing.
            if cardStyle != FilmPanel.CardStyle.list.rawValue {
              Image(systemName: "square.grid.2x2").foregroundStyle(.secondary)
                .help(tr("카드 크기", "Card size"))
              Slider(value: card, in: FilmPanel.cardSizeRange).controlSize(.mini)
            } else {
              Spacer(minLength: 0)
            }
            Image(systemName: "arrow.left.and.right").foregroundStyle(.secondary)
              .help(tr("카드 간격", "Card spacing"))
            Slider(value: gap, in: FilmPanel.cardGapRange).controlSize(.mini).frame(maxWidth: 80)
          }
          .font(.caption)
          .padding(.horizontal, 10).padding(.vertical, 6)
          .onTapGesture(count: 2) { card.wrappedValue = FilmPanel.cardSize; gap.wrappedValue = FilmPanel.cardGap }
        }
      }
      .frame(width: max(min(width, Self.widthRange.upperBound, maxWidth), Self.widthRange.lowerBound))
      PanelEdge(width: $width, range: Self.widthRange, reset: 300, grows: 1)
    }
  }
}

struct StockBrowser: View {
  @Bindable var model: EditModel
  let isFilm: Bool
  var cardSize = 120.0
  var gap = 8.0
  @State private var search = ""
  @State private var contentWidth = 280.0
  @AppStorage("favoriteStocks") private var favoritesRaw = ""
  @AppStorage("pickerExpanded.film") private var filmExpandedRaw = "favorites"
  @AppStorage("pickerExpanded.paper") private var paperExpandedRaw = "favorites"
  @AppStorage(FilmPanel.cardStyleKey) private var cardStyleRaw = FilmPanel.CardStyle.photo.rawValue
  @AppStorage(FilmPanel.shortNameKey) private var shortName = true
  @AppStorage(FilmPanel.badgeKey) private var showBadge = true
  @AppStorage(FilmPanel.orderKey) private var orderRaw = FilmPanel.defaultOrder
  @AppStorage(FilmPanel.hiddenKey) private var hiddenRaw = ""

  private var cardStyle: FilmPanel.CardStyle { FilmPanel.CardStyle(rawValue: cardStyleRaw) ?? .photo }

  /// Accordion groups as in Lightroom's preset panel: Favorites first, then the
  /// film categories (papers have no categories, so they get one All group).
  /// A favourite stays in its own category as well.
  enum Group: Hashable {
    case favorites, category(FilmInfo.Category), all
    var key: String {
      switch self {
      case .favorites: return "favorites"
      case .category(let c): return c.rawValue
      case .all: return "all"
      }
    }
  }

  /// Film groups follow Settings › Film Panel's order; hidden ones come back while searching.
  private var groups: [Group] {
    guard isFilm else { return [.favorites, .all] }
    let hidden = search.isEmpty ? Set(FilmPanel.list(hiddenRaw)) : []
    return FilmPanel.order(orderRaw).filter { !hidden.contains($0) }.compactMap { key in
      key == "favorites" ? .favorites : FilmInfo.Category(rawValue: key).map { .category($0) }
    }
  }

  private var expandedRaw: Binding<String> { isFilm ? $filmExpandedRaw : $paperExpandedRaw }
  private var expanded: Set<String> { Set(expandedRaw.wrappedValue.split(separator: ",").map(String.init)) }

  /// While searching every group with a match is open, so nothing is hidden.
  private func isOpen(_ g: Group) -> Bool { !search.isEmpty || expanded.contains(g.key) }

  private func toggle(_ g: Group) {
    var e = expanded
    if e.contains(g.key) { e.remove(g.key) } else { e.insert(g.key) }
    expandedRaw.wrappedValue = e.sorted().joined(separator: ",")
  }

  private func title(_ g: Group) -> String {
    switch g {
    case .favorites: return tr("즐겨찾기", "Favorites")
    case .category(let c): return c.title
    case .all: return FilmInfo.Category.all.title
    }
  }

  private var favorites: Set<String> { Set(favoritesRaw.split(separator: "\n").map(String.init)) }

  private func toggleFavorite(_ name: String) {
    var f = favorites
    if f.contains(name) { f.remove(name) } else { f.insert(name) }
    favoritesRaw = f.sorted().joined(separator: "\n")
  }

  private var param: String { isFilm ? "film" : "paper" }
  private var unused: String? { ProcessScope.stockReason(film: isFilm, model.settledValues) }
  /// Picking this film with Print switches to a scan.
  private func scans(_ i: Int) -> Bool {
    isFilm && (model.settledValues["process"]?.intValue ?? 0) == 0 && FilmInfo.isPositive(names[i])
  }
  private var names: [String] { isFilm ? Catalog.films : Catalog.papers }

  /// Catalogue order in every group; favourites are not moved out of their category.
  private func members(_ g: Group) -> [Int] {
    names.indices.filter { i in
      let n = names[i]
      let inGroup: Bool
      switch g {
      case .favorites: inGroup = favorites.contains(n)
      case .category(let c): inGroup = FilmInfo.category(n) == c
      case .all: inGroup = true
      }
      return inGroup && (search.isEmpty || FilmInfo.displayName(n).localizedCaseInsensitiveContains(search)
                         || (FilmPanel.badge(n)?.localizedCaseInsensitiveContains(search) ?? false))
    }
  }

  /// Stocks in open groups, deduplicated, for thumbnail scheduling.
  private var visible: [Int] {
    var seen = Set<Int>()
    return groups.filter(isOpen).flatMap(members).filter { seen.insert($0).inserted }
  }

  var body: some View {
    VStack(spacing: 0) {
      TextField(tr("검색", "Search"), text: $search).textFieldStyle(.roundedBorder)
        .padding(10)
      // The picker stays usable in every style (hiding it would strand the pick): dimmed, with why.
      if let unused {
        Label(unused, systemImage: "info.circle").font(.caption).foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 10).padding(.bottom, 8)
      }
      Divider()
      ScrollView {
        // A plain stack: the lazy one re-estimated each group's height while scrolling and the
        // scroll view kept correcting its offset, which hung the app (legacy scrollers, mouse).
        VStack(spacing: 0) {
          ForEach(groups, id: \.self) { g in
            let items = members(g)
            // While searching, groups without a match drop out entirely.
            if search.isEmpty || !items.isEmpty {
              groupHeader(g, count: items.count)
              if isOpen(g) { groupContent(g, items) }
            }
          }
        }
        .frame(maxWidth: .infinity)
        // Width inside the scroller, rounded, so a scroller showing up or sub-point jitter
        // doesn't reflow the card columns over and over.
        .onGeometryChange(for: Double.self) { $0.size.width.rounded() } action: { w in
          if abs(w - contentWidth) >= 1 { contentWidth = w }
        }
        .padding(.bottom, 10)
        .opacity(unused == nil ? 1 : 0.5)
      }
      // Off the cards altogether: the hover look goes at once rather than after the hold.
      .onHover { if !$0 { model.hoverLeftPanel() } }
      .onChange(of: visible, initial: true) { _, v in model.showThumbnails(v, film: isFilm) }
      .onDisappear { model.showThumbnails([], film: isFilm) }
    }
  }

  private func groupHeader(_ g: Group, count: Int) -> some View {
    Button { toggle(g) } label: {
      HStack(spacing: 6) {
        Image(systemName: "chevron.right")
          .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
          .rotationEffect(.degrees(isOpen(g) ? 90 : 0))
        if g == .favorites {
          Image(systemName: "star.fill").font(.caption).foregroundStyle(.yellow)
        }
        Text(title(g)).font(.callout.weight(.semibold))
        Spacer(minLength: 0)
        Text("\(count)").font(.caption).monospacedDigit().foregroundStyle(.secondary)
      }
      .padding(.horizontal, 12).padding(.vertical, 7)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .disabled(!search.isEmpty)
    .background(.bar)
    .overlay(alignment: .bottom) { Divider().opacity(0.6) }
  }

  @ViewBuilder private func groupContent(_ g: Group, _ items: [Int]) -> some View {
    if g == .favorites && items.isEmpty {
      Text(tr("썸네일의 ☆를 눌러 즐겨찾기에 추가하세요", "Click ☆ on a thumbnail to add a favorite"))
        .font(.caption).foregroundStyle(.secondary)
        .frame(maxWidth: .infinity).padding(.vertical, 14)
    } else if cardStyle == .list {
      VStack(spacing: gap / 2) {
        ForEach(items, id: \.self) { i in row(i) }
      }
      .padding(10)
    } else if cardStyle == .curves {
      VStack(spacing: gap) {
        ForEach(items, id: \.self) { i in curveRow(i) }
      }
      .padding(10)
    } else {
      // Plain rows with a column count from the measured width: a lazy grid nested in the
      // lazy section stack gets no width when a group opens, cards blow up and layout spins.
      // Cards share the width they are given rather than a width worked out from the measure,
      // so a stale measure can't make a row wider than the panel (it was cut off on the left).
      let cols = max(1, Int((contentWidth - 20 + gap) / (cardSize + gap)))
      VStack(alignment: .leading, spacing: gap + 2) {
        ForEach(Array(stride(from: 0, to: items.count, by: cols)), id: \.self) { start in
          let row = items[start..<min(start + cols, items.count)]
          HStack(alignment: .top, spacing: gap) {
            ForEach(row, id: \.self) { i in
              card(i).frame(minWidth: 0, maxWidth: .infinity)
            }
            // Keep the last, short row's cards the same width as the others.
            ForEach(0..<(cols - row.count), id: \.self) { _ in
              Color.clear.frame(minWidth: 0, maxWidth: .infinity, maxHeight: 0)
            }
          }
        }
      }
      .padding(10)
    }
  }

  private func thumbView(_ i: Int) -> some View {
    let thumb = isFilm ? model.filmThumbs[i] : model.paperThumbs[i]
    return ZStack {
      Rectangle().fill(Color.black.opacity(0.3))
      if let thumb {
        Image(decorative: thumb, scale: 1).resizable().aspectRatio(contentMode: .fit)
      } else if model.inputURL == nil {
        // No photo open: nothing is being rendered.
        Image(systemName: isFilm ? "film" : "doc.richtext").foregroundStyle(.tertiary)
      } else {
        ProgressView().controlSize(.small)
      }
    }
    .aspectRatio(1.5, contentMode: .fit)
  }

  private func starButton(_ i: Int, onImage: Bool) -> some View {
    let fav = favorites.contains(names[i])
    return Button { toggleFavorite(names[i]) } label: {
      Image(systemName: fav ? "star.fill" : "star")
        .font(.caption)
        .foregroundStyle(fav ? Color.yellow : onImage ? Color.white.opacity(0.7) : Color.secondary)
        .shadow(color: .black.opacity(onImage ? 0.8 : 0), radius: 1)
        .padding(4)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help(fav ? tr("즐겨찾기 해제", "Remove from favorites") : tr("즐겨찾기", "Add to favorites"))
  }

  private func card(_ i: Int) -> some View {
    let selected = model.value(param).intValue == i
    return Button {
      model.setAndCommit(param, .int(i))
    } label: {
      VStack(spacing: 4) {
        thumbView(i)
          .overlay(alignment: .topTrailing) { starButton(i, onImage: true) }
          .overlay(alignment: .topLeading) { badgeView(i) }
          .overlay(RoundedRectangle(cornerRadius: 4).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
          .clipShape(RoundedRectangle(cornerRadius: 4))
        Text(label(i))
          .font(.caption).lineLimit(2).multilineTextAlignment(.center)
          .foregroundStyle(selected ? Color.accentColor : .primary)
      }
    }
    .buttonStyle(.plain)
    .onHover { model.hover(param, i, inside: $0) }
    .contextMenu { menu(i) }
  }

  private func row(_ i: Int) -> some View {
    let selected = model.value(param).intValue == i
    return Button {
      model.setAndCommit(param, .int(i))
    } label: {
      HStack(spacing: 8) {
        thumbView(i).frame(width: 54).clipShape(RoundedRectangle(cornerRadius: 3))
        Text(label(i)).font(.callout).lineLimit(1)
          .foregroundStyle(selected ? Color.accentColor : .primary)
        Spacer(minLength: 0)
        if scans(i) { Text(tr("스캔", "Scan")).font(.caption2).foregroundStyle(Color.accentColor) }
        if showBadge, let badge = FilmPanel.badge(names[i]) {
          Text(badge).font(.caption2).monospacedDigit().foregroundStyle(.secondary)
        }
        starButton(i, onImage: false)
      }
      .padding(4)
      .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.accentColor.opacity(0.15) : .clear))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { model.hover(param, i, inside: $0) }
    .contextMenu { menu(i) }
  }

  private func label(_ i: Int) -> String { FilmPanel.name(names[i], short: shortName) }

  @ViewBuilder private func badgeView(_ i: Int) -> some View {
    if scans(i) {
      Text(tr("스캔", "Scan"))
        .font(.system(size: 9, weight: .semibold))
        .foregroundStyle(.white)
        .padding(.horizontal, 4).padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 3).fill(Color.accentColor.opacity(0.85)))
        .padding(4)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .help(tr("포지티브 필름: 인화하지 않고 스캔으로 처리됩니다.", "Positive film: scanned, not printed."))
    }
    if showBadge, let badge = FilmPanel.badge(names[i]) {
      Text(badge)
        .font(.system(size: 9, weight: .semibold)).monospacedDigit()
        .foregroundStyle(.white)
        .padding(.horizontal, 4).padding(.vertical, 1)
        .background(RoundedRectangle(cornerRadius: 3).fill(Color.black.opacity(0.55)))
        .padding(4)
    }
  }

  /// Thumbnail beside the name and the stock's R, G, B characteristic curves.
  private func curveRow(_ i: Int) -> some View {
    let selected = model.value(param).intValue == i
    // Thumbnail and curves grow together with the panel (sized for the default 300 pt panel); the
    // curves take the rest of the row and grow in height more slowly than the thumbnail.
    let grow = max(contentWidth, 200) / 280
    let thumbW = min(max(54, cardSize * 0.6 * grow), (contentWidth - 16) / 2.2)
    return Button {
      model.setAndCommit(param, .int(i))
    } label: {
      HStack(spacing: 8) {
        thumbView(i)
          .overlay(alignment: .topLeading) { badgeView(i) }
          .frame(width: thumbW)
          .clipShape(RoundedRectangle(cornerRadius: 3))
        VStack(alignment: .leading, spacing: 3) {
          HStack(spacing: 2) {
            Text(label(i)).font(.caption).lineLimit(1)
              .foregroundStyle(selected ? Color.accentColor : .primary)
            Spacer(minLength: 0)
            starButton(i, onImage: false)
          }
          if let curves = FilmPanel.curves(paper: !isFilm, index: i) {
            CurveSketch(curves: curves).frame(height: max(22, cardSize * 0.24 * grow.squareRoot()))
          }
        }
      }
      .padding(4)
      .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.accentColor.opacity(0.15) : .clear))
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .onHover { model.hover(param, i, inside: $0) }
    .contextMenu { menu(i) }
  }

  @ViewBuilder private func menu(_ i: Int) -> some View {
    Button(favorites.contains(names[i]) ? tr("즐겨찾기 해제", "Remove from favorites")
                                        : tr("즐겨찾기에 추가", "Add to favorites")) { toggleFavorite(names[i]) }
    if isFilm {
      Button(tr("이 필름과 비교", "Compare with this film")) {
        model.compareBase = .film(i)
        if model.compareMode == .off { model.compareMode = .split }
      }
    }
  }
}

struct PresetList: View {
  @Bindable var model: EditModel
  @State private var presets = Presets.list()
  @State private var newName = ""
  @State private var renaming: Preset?
  @State private var renameText = ""
  /// Presets whose saved picks contradict themselves (positive film with Process negative).
  @State private var conflicted: Set<URL> = []

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack {
        TextField(tr("새 프리셋 이름", "New preset name"), text: $newName).textFieldStyle(.roundedBorder)
        Button(tr("저장", "Save")) {
          guard !newName.isEmpty else { return }
          Presets.save(model.values, name: Presets.uniqueName(newName))
          newName = ""
          presets = Presets.list()
        }
        .disabled(newName.isEmpty)
        Button { importPresets() } label: { Image(systemName: "square.and.arrow.down.on.square") }
          .help(tr("프리셋 가져오기 (.json)", "Import presets (.json)"))
      }
      .padding([.horizontal, .top], 10)
      List {
        Button(tr("기본값 (엔진 기본 + 그레인·할레이션·스캔)", "Default (engine + grain, halation, scan)")) {
          model.apply(EditModel.appDefaults(), label: tr("프리셋: 기본값", "Preset: Default"))
          model.presetName = tr("기본값", "Default")
        }
          .buttonStyle(.plain)
        ForEach(presets) { p in
          HStack {
            Button(p.name) { apply(p) }
              .buttonStyle(.plain)
            if conflicted.contains(p.url) {
              Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange).font(.caption)
                .help(tr("포지티브 필름을 네거 인화 모드로 저장한 프리셋입니다. 적용하면 필름 선택이 쓰이지 않습니다.",
                         "Saved with positive film in Process negative mode: the film choice will not be used."))
            }
            Spacer()
            Button { delete(p) } label: { Image(systemName: "trash") }
              .buttonStyle(.borderless).help(tr("삭제", "Delete"))
          }
          .contextMenu {
            Button(tr("적용", "Apply")) { apply(p) }
            Button(tr("현재 설정으로 업데이트", "Update with current settings")) { Presets.save(model.values, name: p.name) }
            Button(tr("이름 바꾸기…", "Rename…")) { renameText = p.name; renaming = p }
            Divider()
            Button(tr("LUT로 내보내기 (.cube)…", "Export as LUT (.cube)…")) {
              if let v = Presets.load(p) { LutPanel.run(values: v, name: p.name) }
            }
            Button(tr("Finder에서 보기", "Show in Finder")) { NSWorkspace.shared.activateFileViewerSelecting([p.url]) }
            Divider()
            Button(tr("삭제", "Delete"), role: .destructive) { delete(p) }
          }
        }
      }
      .listStyle(.sidebar)
    }
    .task(id: presets) {
      conflicted = Set(presets.filter { Presets.load($0).flatMap(ProcessScope.conflict) != nil }.map(\.url))
    }
    .alert(tr("프리셋 이름 바꾸기", "Rename Preset"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
      TextField(tr("이름", "Name"), text: $renameText)
      Button(tr("취소", "Cancel"), role: .cancel) { renaming = nil }
      Button("OK") {
        if let p = renaming, !renameText.isEmpty, !Presets.rename(p, to: renameText) {
          let alert = NSAlert()
          alert.messageText = tr("이름을 바꾸지 못했습니다", "Could not rename")
          alert.informativeText = tr("같은 이름의 프리셋이 이미 있습니다: ", "A preset with this name already exists: ") + renameText
          alert.runModal()
        }
        renaming = nil
        presets = Presets.list()
      }
    }
  }

  private func apply(_ p: Preset) {
    if let v = Presets.load(p) {
      model.apply(v, label: tr("프리셋: ", "Preset: ") + p.name)
      model.presetName = p.name
    }
  }

  private func delete(_ p: Preset) {
    let alert = NSAlert()
    alert.messageText = tr("프리셋 \"\(p.name)\"을(를) 삭제할까요?", "Delete preset \"\(p.name)\"?")
    alert.addButton(withTitle: tr("삭제", "Delete")).hasDestructiveAction = true
    alert.addButton(withTitle: tr("취소", "Cancel"))
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    Presets.delete(p)
    presets = Presets.list()
  }

  private func importPresets() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    panel.allowsMultipleSelection = true
    guard panel.runModal() == .OK else { return }
    let bad = panel.urls.filter { !Presets.importFile($0) }
    presets = Presets.list()
    if !bad.isEmpty {
      let alert = NSAlert()
      alert.messageText = tr("가져오지 못한 파일", "Could not import")
      alert.informativeText = bad.map(\.lastPathComponent).joined(separator: "\n")
      alert.runModal()
    }
  }
}

struct HistoryList: View {
  @Bindable var model: EditModel
  @State private var renaming: EditSnapshot?
  @State private var renameText = ""

  var body: some View {
    List {
      Section {
        ForEach(model.snapshots.reversed()) { s in
          Button { model.applySnapshot(s) } label: {
            HStack {
              Image(systemName: "camera").foregroundStyle(.secondary)
              Text(s.name)
              Spacer()
              if model.compareMode != .off, model.compareBase == .snapshot(s.id) {
                Image(systemName: "rectangle.split.2x1").foregroundStyle(Color.accentColor)
              }
            }
          }
          .buttonStyle(.plain)
          .help(tr("클릭: 이 스냅샷 적용", "Click: apply this snapshot"))
          .contextMenu {
            Button(tr("적용", "Apply")) { model.applySnapshot(s) }
            Button(tr("이 스냅샷과 비교", "Compare with this snapshot")) {
              model.compareBase = .snapshot(s.id)
              if model.compareMode == .off { model.compareMode = .split }
            }
            Button(tr("이름 바꾸기…", "Rename…")) { renameText = s.name; renaming = s }
            Divider()
            Button(tr("삭제", "Delete"), role: .destructive) { model.deleteSnapshot(s) }
          }
        }
      } header: {
        HStack {
          Text(tr("스냅샷", "Snapshots"))
          Spacer()
          Button { model.addSnapshot() } label: { Label(tr("스냅샷", "Snapshot"), systemImage: "plus") }
            .buttonStyle(.borderless).controlSize(.small).help("⇧⌘N")
        }
      }
    }
    .listStyle(.sidebar)
    .alert(tr("스냅샷 이름 바꾸기", "Rename Snapshot"), isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
      TextField(tr("이름", "Name"), text: $renameText)
      Button(tr("취소", "Cancel"), role: .cancel) { renaming = nil }
      Button("OK") {
        if let s = renaming, !renameText.isEmpty { model.renameSnapshot(s, to: renameText) }
        renaming = nil
      }
    }
  }
}

/// Draggable edge between a side panel and the canvas: a 1 pt line that is easy to catch (11 pt
/// wide, mostly over the canvas so the panel's scroller stays free) that darkens to a soft 2 pt bar
/// while the pointer is on it or dragging.
/// Double-click resets the width.
struct PanelEdge: View {
  @Binding var width: Double
  let range: ClosedRange<Double>
  let reset: Double
  /// +1 when dragging right widens the panel (left panel), -1 for the right panel.
  let grows: Double
  static let grab = 11.0
  /// How far the grab area reaches into the panel; the rest lies over the canvas.
  static let panelSide = 2.0
  /// True while the pointer is on an edge or dragging one: the canvas underneath keeps its
  /// hand off the cursor then, so the two do not take turns setting it.
  @MainActor static var engaged = false
  @State private var hot = false
  @State private var dragStart: Double?

  private var active: Bool { hot || dragStart != nil }

  private func engage(_ on: Bool) {
    Self.engaged = on
    (on ? NSCursor.resizeLeftRight : NSCursor.arrow).set()
  }

  var body: some View {
    Rectangle()
      .fill(active ? Color.primary.opacity(dragStart != nil ? 0.35 : 0.22) : Color(nsColor: .separatorColor))
      .frame(width: active ? 2 : 1)
      .animation(.easeOut(duration: 0.1), value: active)
      .padding(grows > 0 ? .leading : .trailing, Self.panelSide)
      .frame(width: Self.grab, alignment: grows > 0 ? .leading : .trailing)
      .contentShape(Rectangle())
      .onContinuousHover { phase in
        switch phase {
        case .active:
          hot = true
          engage(true)
        case .ended:
          hot = false
          // Leaving mid-drag keeps the cursor until the drag ends.
          if dragStart == nil { engage(false) }
        }
      }
      .gesture(DragGesture(minimumDistance: 1, coordinateSpace: .global)
        .onChanged { g in
          if dragStart == nil { dragStart = width }
          engage(true)
          width = min(max((dragStart ?? width) + grows * g.translation.width, range.lowerBound), range.upperBound)
        }
        .onEnded { _ in
          dragStart = nil
          if !hot { engage(false) }
        })
      .onTapGesture(count: 2) { width = reset }
      // Hidden with ⌘1 while the pointer is on it: no hover end comes, so give the canvas its cursor back.
      .onDisappear { if Self.engaged { engage(false) } }
      .padding(grows > 0 ? .leading : .trailing, -Self.panelSide)
      .padding(grows > 0 ? .trailing : .leading, -(Self.grab - 1 - Self.panelSide))
      .zIndex(1)
  }
}
