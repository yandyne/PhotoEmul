// PhotoEmul - native editor for spektrafilm (GPL-3.0-or-later)
// Compare view modes, shared with the iPad probe (no AppKit).
import Foundation

enum CompareMode: String, CaseIterable, Identifiable {
  /// `split` divides left/right, `splitStacked` top/bottom (before on top); the side-by-side
  /// views put two whole panes next to each other or one above the other.
  case off, split, splitStacked, sideBySide, sideBySideStacked
  var id: String { rawValue }
  var isSplit: Bool { self == .split || self == .splitStacked }
  var isSideBySide: Bool { self == .sideBySide || self == .sideBySideStacked }
  /// The compare image is above the current one.
  var isStacked: Bool { self == .splitStacked || self == .sideBySideStacked }
  /// The same view turned 90°.
  var rotated: CompareMode {
    switch self {
    case .off: return .off
    case .split: return .splitStacked
    case .splitStacked: return .split
    case .sideBySide: return .sideBySideStacked
    case .sideBySideStacked: return .sideBySide
    }
  }
  var title: String {
    switch self {
    case .off: return tr("비교 끄기", "No Compare")
    case .split: return tr("좌우 분할 비교", "Split View (Left/Right)")
    case .splitStacked: return tr("상하 분할 비교", "Split View (Top/Bottom)")
    case .sideBySide: return tr("좌우 나란히 비교", "Side by Side (Left/Right)")
    case .sideBySideStacked: return tr("상하 나란히 비교", "Side by Side (Top/Bottom)")
    }
  }
  var symbol: String {
    switch self {
    case .off: return "rectangle"
    case .split: return "rectangle.lefthalf.inset.filled"
    case .splitStacked: return "rectangle.tophalf.inset.filled"
    case .sideBySide: return "rectangle.split.2x1"
    case .sideBySideStacked: return "rectangle.split.1x2"
    }
  }
}
