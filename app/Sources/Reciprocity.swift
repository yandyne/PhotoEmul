// PhotoEmul - native editor for spektrafilm (GPL-3.0-or-later)
// Shutter speed and reciprocity failure (Schwarzschild effect).
//
// Below a threshold time t0 film follows exposure = intensity x time. Beyond it a long exposure
// records less than it should: the effective exposure behaves like I * t^(1/P), so the loss in
// stops is (1 - 1/P) * log2(t / t0). Colour layers fail at different rates, which tints long
// exposures (Velvia 50 turns green, Kodachrome loses red).
//
// The t0 / P values are fitted by hand to the compensation tables in the manufacturers' public
// datasheets (Ilford, Kodak, Fujifilm technical data). They are approximations, not measurements.
// When "compensated" is on, the photographer opened up by the datasheet's correction, so only the
// colour difference between layers and the contrast increase remain.

import Foundation

enum Reciprocity {
  static let params: [String] = ["shutterSpeed", "reciprocityCompensate"]

  /// Shutter speeds (seconds) of the "shutterSpeed" choices.
  static let speeds: [Double] = [
    1.0 / 8000, 1.0 / 4000, 1.0 / 2000, 1.0 / 1000, 1.0 / 500, 1.0 / 250, 1.0 / 125, 1.0 / 60,
    1.0 / 30, 1.0 / 15, 1.0 / 8, 1.0 / 4, 1.0 / 2, 1, 2, 4, 8, 15, 30, 60, 120, 240, 480, 900, 1800, 3600,
  ]
  static let speedLabels: [String] = [
    "1/8000", "1/4000", "1/2000", "1/1000", "1/500", "1/250", "1/125", "1/60", "1/30", "1/15", "1/8",
    "1/4", "1/2", "1 s", "2 s", "4 s", "8 s", "15 s", "30 s", "1 min", "2 min", "4 min", "8 min",
    "15 min", "30 min", "1 h",
  ]
  static let defaultSpeedIndex = 6

  struct Fit {
    var t0: Double
    var p: Double
    /// Extra loss per doubling of time beyond t0, in stops, for the red / green / blue layers.
    var bias: [Double] = [0, 0, 0]
  }

  static let genericColor = Fit(t0: 1, p: 1.3)
  static let genericMono = Fit(t0: 1, p: 1.31)

  static let fits: [String: Fit] = [
    "ilford_pan_f_plus": Fit(t0: 1, p: 1.33),
    "ilford_fp4_plus": Fit(t0: 1, p: 1.26),
    "ilford_hp5_plus": Fit(t0: 1, p: 1.31),
    "ilford_delta_100": Fit(t0: 1, p: 1.26),
    "ilford_delta_400": Fit(t0: 1, p: 1.41),
    "ilford_delta_3200": Fit(t0: 1, p: 1.33),
    "ilford_xp2_super": Fit(t0: 1, p: 1.31),
    "harman_phoenix_200": Fit(t0: 1, p: 1.33, bias: [0.04, 0, 0.06]),
    "kodak_tri_x_400": Fit(t0: 0.1, p: 1.43),
    "kodak_trix": Fit(t0: 0.1, p: 1.43),
    "kodak_tmax_100": Fit(t0: 1, p: 1.18),
    "kodak_tmax_400": Fit(t0: 3.2, p: 1.43),
    "kodak_doublex": genericMono,
    "fujifilm_acros_ii": Fit(t0: 120, p: 1.195),
    "fujifilm_provia_100f": Fit(t0: 128, p: 1.15),
    "fujifilm_velvia_100": Fit(t0: 60, p: 1.2, bias: [0.02, 0, 0.03]),
    "fujifilm_provia_400x": Fit(t0: 60, p: 1.2),
    "fujifilm_velvia_50": Fit(t0: 1, p: 1.2, bias: [0.07, 0, 0.07]),
    "kodak_kodachrome_64": Fit(t0: 0.1, p: 1.43, bias: [0.10, 0, 0]),
    "kodak_ektachrome_100": Fit(t0: 10, p: 1.2, bias: [0, 0, 0.03]),
    "kodak_portra_160": Fit(t0: 1, p: 1.33, bias: [0.02, 0, 0.04]),
    "kodak_portra_400": Fit(t0: 1, p: 1.33, bias: [0.02, 0, 0.04]),
    "kodak_portra_800": Fit(t0: 1, p: 1.33, bias: [0.02, 0, 0.04]),
    "kodak_portra_800_push1": Fit(t0: 1, p: 1.33, bias: [0.02, 0, 0.04]),
    "kodak_portra_800_push2": Fit(t0: 1, p: 1.33, bias: [0.02, 0, 0.04]),
    "kodak_ektar_100": Fit(t0: 1, p: 1.33, bias: [0.03, 0, 0.03]),
    "kodak_gold_200": Fit(t0: 0.1, p: 1.25, bias: [0.03, 0, 0.05]),
    "kodak_ultramax_400": Fit(t0: 0.1, p: 1.25, bias: [0.03, 0, 0.05]),
    "fujifilm_c200": Fit(t0: 2, p: 1.3, bias: [0, 0, 0.04]),
    "fujifilm_200": Fit(t0: 2, p: 1.3, bias: [0, 0, 0.04]),
    "fujifilm_xtra_400": Fit(t0: 2, p: 1.3, bias: [0, 0, 0.04]),
    "fujifilm_pro_400h": Fit(t0: 4, p: 1.3),
  ]

  static func fit(for film: String) -> Fit {
    if let f = fits[film] { return f }
    // Motion-picture negatives are made for 1/48 s and fail gently.
    if film.contains("vision3") || film.contains("eterna") || film.contains("cinestill") || film.hasPrefix("kodak_2") {
      return Fit(t0: 1, p: 1.2)
    }
    return FilmInfo.category(film) == .bw ? genericMono : genericColor
  }

  /// Per-layer exposure loss in stops (R, G, B) and the contrast factor for this shutter time.
  static func effect(_ values: [String: ParamValue], film: String) -> (stops: [Double], gamma: Double)? {
    let index = min(max(values["shutterSpeed"]?.intValue ?? defaultSpeedIndex, 0), speeds.count - 1)
    let t = speeds[index]
    let f = fit(for: film)
    guard t > f.t0 else { return nil }
    let doublings = log2(t / f.t0)
    let base = (1 - 1 / f.p) * doublings
    var stops = (0..<3).map { base + f.bias[$0] * doublings }
    if values["reciprocityCompensate"]?.boolValue ?? true {
      let green = stops[1]
      stops = stops.map { $0 - green }
    }
    let mono = FilmInfo.category(film) == .bw
    let gamma = 1 + (mono ? 0.04 : 0.02) * base
    return (stops, min(gamma, 1.4))
  }
}
