// PhotoEmul - native editor for spektrafilm (GPL-3.0-or-later)
// Settings › Film Panel: how the film / paper browser looks, which groups it shows, what a new
// photo starts with, hover preview timing and the favourites file.

import AppKit
import CSpektra
import Foundation
import SwiftUI
import UniformTypeIdentifiers

enum FilmPanel {
  enum CardStyle: String, CaseIterable, Identifiable {
    case photo, curves, list
    var id: String { rawValue }
    var title: String {
      switch self {
      case .photo: return tr("사진", "Photo")
      case .curves: return tr("사진+곡선", "Photo + curves")
      case .list: return tr("목록", "List")
      }
    }
  }

  enum OnOpen: String, CaseIterable, Identifiable {
    case last, defaults, collapsed
    var id: String { rawValue }
    var title: String {
      switch self {
      case .last: return tr("마지막 상태 그대로", "As I left them")
      case .defaults: return tr("기본값", "Defaults")
      case .collapsed: return tr("모두 접기", "All collapsed")
      }
    }
  }

  static let cardStyleKey = "filmPanel.cardStyle"
  static let cardSizeKey = "filmPanel.cardSize"
  static let cardGapKey = "filmPanel.cardGap"
  static let shortNameKey = "filmPanel.shortName"
  static let badgeKey = "filmPanel.badge"
  static let orderKey = "filmPanel.groupOrder"
  static let hiddenKey = "filmPanel.groupHidden"
  static let defaultOpenKey = "filmPanel.groupDefaultOpen"
  static let onOpenKey = "filmPanel.onOpen"
  static let startFilmKey = "filmPanel.startFilm"
  static let startPaperKey = "filmPanel.startPaper"
  static let startLastKey = "filmPanel.startLast"
  static let hoverDelayKey = "filmPanel.hoverDelay"
  static let hoverHoldKey = "filmPanel.hoverHold"
  static let hoverPendingKey = "filmPanel.hoverPendingLabel"
  static let hoverFadeKey = "filmPanel.hoverFade"
  static let thumbsFollowKey = "filmPanel.thumbsFollowEdits"
  /// Off: card thumbnails show each stock on default values (only these follow), so edits never redraw them.
  static var thumbsFollowEdits: Bool { UserDefaults.standard.object(forKey: thumbsFollowKey) as? Bool ?? true }
  static let thumbFixedKeys: Set<String> = ["film", "paper", "process"]

  static let keys = [cardStyleKey, cardSizeKey, cardGapKey, shortNameKey, badgeKey, orderKey, hiddenKey,
                     defaultOpenKey, onOpenKey, startFilmKey, startPaperKey, startLastKey, hoverDelayKey,
                     hoverHoldKey, hoverPendingKey, hoverFadeKey, thumbsFollowKey]

  static let defaultCardSize = 120.0
  static let defaultCardGap = 8.0
  static let cardSizeRange = 72.0...180.0
  static let cardGapRange = 2.0...24.0
  static let defaultOrder = "favorites,negative,cine,slide,bw,instant"
  static let defaultOpen = "favorites"
  static let defaultStartFilm = "kodak_portra_400"
  static let defaultStartPaper = "kodak_portra_endura"
  /// Seconds the pointer rests on a card before its preview renders (바로 / 짧게 / 길게).
  static let hoverDelays = [0.0, 0.15, 0.45]
  /// Seconds the last hover look stays after the pointer leaves a card (끔 / 짧게 / 길게), so
  /// crossing the gap to the next card goes straight from one look to the next.
  static let hoverHolds = [0.0, 0.3, 0.6]

  private static var store: UserDefaults { .standard }

  static var cardSize: Double { store.object(forKey: cardSizeKey) as? Double ?? defaultCardSize }
  static var cardGap: Double { store.object(forKey: cardGapKey) as? Double ?? defaultCardGap }
  static var hoverDelay: Double {
    hoverDelays[min(max(store.object(forKey: hoverDelayKey) as? Int ?? 1, 0), hoverDelays.count - 1)]
  }

  static var hoverHold: Double {
    hoverHolds[min(max(store.object(forKey: hoverHoldKey) as? Int ?? 1, 0), hoverHolds.count - 1)]
  }
  /// "A → B 불러오는 중" on the canvas while the next card renders.
  static var hoverPendingLabel: Bool { store.object(forKey: hoverPendingKey) as? Bool ?? true }
  /// Hover looks cross-fade on the canvas instead of cutting.
  static var hoverFade: Bool { store.object(forKey: hoverFadeKey) as? Bool ?? true }

  static func list(_ raw: String) -> [String] { raw.split(separator: ",").map(String.init) }

  /// Film group keys in the chosen order; keys added in a later version join at the end.
  static func order(_ raw: String) -> [String] {
    var keys = list(raw).filter { list(defaultOrder).contains($0) }
    keys += list(defaultOrder).filter { !keys.contains($0) }
    return keys
  }

  /// Settings › 처음 열 때, applied once per launch before the browser reads its open groups.
  static func prepareForLaunch() {
    guard Layout.persists else { return }
    let mode = OnOpen(rawValue: store.string(forKey: onOpenKey) ?? "") ?? .last
    switch mode {
    case .last: return
    case .collapsed:
      store.set("", forKey: "pickerExpanded.film")
      store.set("", forKey: "pickerExpanded.paper")
    case .defaults:
      let open = list(store.string(forKey: defaultOpenKey) ?? defaultOpen)
      store.set(open.joined(separator: ","), forKey: "pickerExpanded.film")
      store.set(open.contains("favorites") ? "favorites,all" : "all", forKey: "pickerExpanded.paper")
    }
  }

  /// Settings › 새 사진의 시작값: the last edit, with the default film and paper unless the
  /// last combination is wanted. Photos with a saved edit never come here.
  static func startValues() -> [String: ParamValue] {
    var values = Presets.loadLast() ?? EditModel.appDefaults()
    guard !(store.object(forKey: startLastKey) as? Bool ?? true) else { return values }
    if let i = Catalog.films.firstIndex(of: store.string(forKey: startFilmKey) ?? defaultStartFilm) {
      values["film"] = .int(i)
    }
    if let i = Catalog.papers.firstIndex(of: store.string(forKey: startPaperKey) ?? defaultStartPaper) {
      values["paper"] = .int(i)
    }
    return values
  }

  static func reset() {
    for key in keys { store.removeObject(forKey: key) }
    store.removeObject(forKey: EditModel.hoverKey)
    for tab in ["film", "paper"] {
      store.removeObject(forKey: "pickerCard.\(tab)")
      store.removeObject(forKey: "pickerGap.\(tab)")
    }
  }

  // MARK: Names and badges

  private static let makers: Set<String> = ["Kodak", "Fujifilm", "Ilford", "Harman"]

  /// "Kodak Portra 400" or, short, "Portra 400"; a maker followed by a number keeps it.
  static func name(_ stock: String, short: Bool) -> String {
    let full = FilmInfo.displayName(stock)
    guard short, let space = full.firstIndex(of: " "), makers.contains(String(full[..<space])) else { return full }
    let rest = full[full.index(after: space)...]
    return rest.first?.isNumber ?? true ? full : String(rest)
  }

  /// Box speeds the stock name does not carry.
  private static let speeds: [String: String] = [
    "kodak_trix": "200", "kodak_doublex": "250", "ilford_fp4_plus": "125", "ilford_hp5_plus": "400",
    "ilford_pan_f_plus": "50", "ilford_xp2_super": "400", "fujifilm_acros_ii": "100",
    "fujifilm_instax": "800", "polaroid_600": "640", "fujifilm_fp100c": "100", "fujifilm_c200": "200",
    "fujifilm_pro_400h": "400", "fujifilm_provia_100f": "100", "fujifilm_provia_400x": "400",
  ]

  /// "ISO 400", or "500T" / "250D" for cine stocks with a light-balance letter; nil for print stocks.
  static func badge(_ stock: String) -> String? {
    if let s = speeds[stock] { return "ISO " + s }
    for word in stock.split(separator: "_") {
      let digits = word.prefix { $0.isNumber }
      guard let n = Int(digits), n >= 6, n <= 1600 || n == 3200 else { continue }
      let suffix = word.dropFirst(digits.count)
      if suffix.isEmpty { return "ISO \(n)" }
      if suffix == "t" || suffix == "d" { return "\(n)\(suffix.uppercased())" }
    }
    return nil
  }

  // MARK: Characteristic curves

  struct Curves {
    var logExposure: [Float]
    /// Per channel R, G, B, the densities at each log exposure.
    var density: [[Float]]
  }

  private static var curveCache: [String: Curves] = [:]

  static func curves(paper: Bool, index: Int) -> Curves? {
    let key = "\(paper ? "p" : "f")\(index)"
    if let hit = curveCache[key] { return hit }
    let id = Int32(paper ? 1 : 0), i = UInt32(index)
    let n = Int(SpektraAppStockCurves(id, i, nil, nil, 0))
    guard n > 1 else { return nil }
    var logE = [Float](repeating: 0, count: n), d = [Float](repeating: 0, count: n * 3)
    _ = SpektraAppStockCurves(id, i, &logE, &d, UInt32(n))
    let c = Curves(logExposure: logE, density: (0..<3).map { ch in (0..<n).map { d[$0 * 3 + ch] } })
    curveCache[key] = c
    return c
  }

  // MARK: Favourites file

  static func favorites() -> [String] {
    (store.string(forKey: "favoriteStocks") ?? "").split(separator: "\n").map(String.init)
  }

  static func setFavorites(_ names: [String]) {
    store.set(Set(names).sorted().joined(separator: "\n"), forKey: "favoriteStocks")
  }

  static func exportFavorites() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.json]
    panel.nameFieldStringValue = "PhotoEmul Favorites.json"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let data = try? JSONSerialization.data(withJSONObject: ["favorites": favorites()], options: [.prettyPrinted, .sortedKeys])
    try? data?.write(to: url, options: .atomic)
  }

  /// Adds the file's stocks to the favourites; names this version does not have are skipped.
  /// Returns how many were added, or nil when the file could not be read.
  @discardableResult static func importFavorites() -> Int? {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.json]
    guard panel.runModal() == .OK, let url = panel.url,
          let data = try? Data(contentsOf: url),
          let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let names = object["favorites"] as? [String] else { return nil }
    let known = Set(Catalog.films + Catalog.papers)
    let current = favorites()
    let added = names.filter { known.contains($0) && !current.contains($0) }
    setFavorites(current + added)
    return added.count
  }
}

/// R, G, B characteristic curves (density over log exposure) drawn small on a card.
struct CurveSketch: View {
  let curves: FilmPanel.Curves

  var body: some View {
    Canvas { context, size in
      let logE = curves.logExposure
      guard let x0 = logE.first, let x1 = logE.last, x1 > x0 else { return }
      let finite = curves.density.flatMap { $0 }.filter(\.isFinite)
      guard let lo = finite.min(), let hi = finite.max(), hi > lo else { return }
      let colors: [Color] = [Color(red: 1, green: 0.42, blue: 0.42), Color(red: 0.37, green: 0.83, blue: 0.55),
                             Color(red: 0.35, green: 0.64, blue: 1)]
      for (channel, color) in colors.enumerated() {
        var path = Path()
        var started = false
        for (i, d) in curves.density[channel].enumerated() where d.isFinite {
          let p = CGPoint(x: CGFloat((logE[i] - x0) / (x1 - x0)) * size.width,
                          y: size.height - CGFloat((d - lo) / (hi - lo)) * (size.height - 2) - 1)
          if started { path.addLine(to: p) } else { path.move(to: p); started = true }
        }
        context.stroke(path, with: .color(color), lineWidth: 1.2)
      }
    }
    .accessibilityLabel(tr("특성 곡선", "Characteristic curves"))
  }
}
