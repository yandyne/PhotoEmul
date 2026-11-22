// PhotoEmul - native editor for spektrafilm (GPL-3.0-or-later)
// Bromide drag: a process defect offered as a look.
//
// Developing silver releases bromide, which slows development. With too little agitation the used
// developer slides off dense areas in one direction (downward in a tank left upright, or along a
// tray rock) and holds back development behind them, so a bright object prints with a dark tail.
// Where the flow leaves a thin (dark) area, fresh developer reaches the next part first, so the
// start of a bright area comes out a little lighter.
//
// Applied before the engine on scene exposure (Effects.metal dragDown/dragShift/dragApply), over
// the whole frame so tiles and proxies agree. The tail length is in film millimetres for the chosen
// film format. Black-and-white and colour negative only: slides and instant film are developed in
// a different process and viewed directly.

import Foundation

enum BromideDrag {
  struct Setup { var strength: Double; var angleDeg: Double; var lengthPx: Double }

  /// Gain at 100%: a cell one log unit (3⅓ stops) brighter than its tail moves it by 0.5 log.
  private static let fullStrength = 0.5

  static func setup(_ values: [String: ParamValue], longEdgePx: Int) -> Setup? {
    guard values["bromideDragEnabled"]?.boolValue == true,
          let film = Catalog.films[safe: values["film"]?.intValue ?? -1], appliesTo(film) else { return nil }
    let amount = max(values["bromideDragAmount"]?.doubleValue ?? 50, 0) / 100
    let mm = max(values["bromideDragLength"]?.doubleValue ?? 3, 0)
    let f = max(0, min(LensProfile.formatMm.count - 1, values["filmFormat"]?.intValue ?? 4))
    let px = mm * Double(longEdgePx) / LensProfile.formatMm[f]
    guard amount > 0, px >= 1 else { return nil }
    return Setup(strength: amount * fullStrength, angleDeg: values["bromideDragAngle"]?.doubleValue ?? 0, lengthPx: px)
  }

  static func appliesTo(_ film: String) -> Bool {
    let c = FilmInfo.category(film)
    return c != .slide && c != .instant && !FilmInfo.isPositive(film)
  }
}
