// PhotoEmul - native editor for spektrafilm (GPL-3.0-or-later)
// Developer adjacency (edge) effects for black-and-white film.
//
// Developing silver releases bromide and uses up developer. Both diffuse through the gelatin
// and the still layer of developer on the film, so a dense area slows development beside it: a
// thin area next to a dense one comes out thinner (Eberhard border), the dense edge comes out
// denser (fringe), and very fine dense detail develops further than a big patch (Kostinsky).
// Weak or dilute developer with little agitation makes the effect strong (Rodinal 1+100 stand
// development); strong developer with constant agitation all but removes it. The developer and its
// dilution come from Developer (Development.swift).
//
// The engine's DIR-coupler pass is the same reaction-diffusion model: an inhibitor made in
// proportion to developed silver, spread by a diffusion kernel, holds back development, and the
// curve is re-fitted so a uniform area keeps its density. Black-and-white film has no couplers, so
// the pass is free to stand in for the developer: dilution sets how much inhibitor each unit of
// silver makes, agitation sets how far it spreads before it is washed away. Directional bromide
// drag (streaks below edges from a tank left upright) is its own module, BromideDrag.swift.

import CSpektra
import Foundation

enum Adjacency {
  static let params = ["adjacencyEnabled", "adjacencyDeveloper", "adjacencyAgitation", "adjacencyStrength"]

  /// Hidden since 0.1.88 (kept so old presets load): replaced by the developer and dilution
  /// (Developer in Development.swift), see Presets.migrated.
  static let developers = ["Stock (D-76)", "Diluted 1+1 (D-76 1+1)", "Acutance (Rodinal 1+50)", "Compensating (Rodinal 1+100)"]

  static let agitations = ["Continuous (rotary)", "Every 30 s", "Every minute", "Every 3 minutes", "Stand (none)"]
  private static let agitationGain: [Double] = [0.35, 0.8, 1.0, 1.3, 1.5]
  private static let agitationSpread: [Double] = [0.6, 0.9, 1.0, 1.3, 1.8]
  /// Long-range part from developer exhaustion in the still layer (stand development halos).
  private static let tailWeight: [Double] = [0.0, 0.03, 0.05, 0.10, 0.12]
  private static let tailUm: [Double] = [300, 400, 500, 700, 1000]
  /// Colour negatives without DIR couplers: how much of the strength the stand-in pass gets.
  private static let standIn = 0.8

  static let defaultDeveloper = 0
  static let defaultAgitation = 2

  static func applies(_ values: [String: ParamValue], film: String) -> Bool {
    guard values["adjacencyEnabled"]?.boolValue == true else { return false }
    return FilmInfo.category(film) == .bw || isColorNegative(film)
  }

  private static func isColorNegative(_ film: String) -> Bool {
    let c = FilmInfo.category(film)
    return c != .bw && c != .slide && c != .instant && !FilmInfo.isPositive(film)
  }

  private static func agitation(_ values: [String: ParamValue]) -> Int {
    min(max(values["adjacencyAgitation"]?.intValue ?? defaultAgitation, 0), agitations.count - 1)
  }

  /// Diffusion length the DIR pass uses for black-and-white film (µm), for the panel caption.
  static func diffusionUm(_ values: [String: ParamValue]) -> Double? {
    guard let film = Catalog.films[safe: values["film"]?.intValue ?? -1], FilmInfo.category(film) == .bw,
          let um = Developer.character(values, film: film).adjacencyUm else { return nil }
    return um * agitationSpread[agitation(values)]
  }

  /// Inhibition the DIR pass uses for black-and-white film times the strength, for the edge graph.
  static func edgeGain(_ values: [String: ParamValue]) -> Double? {
    guard values["adjacencyEnabled"]?.boolValue == true,
          let film = Catalog.films[safe: values["film"]?.intValue ?? -1], FilmInfo.category(film) == .bw,
          let g = Developer.character(values, film: film).adjacencyGamma else { return nil }
    return g * agitationGain[agitation(values)] * max(values["adjacencyStrength"]?.doubleValue ?? 1, 0)
  }

  /// What makes the edge effect on the chosen film, for the edge graph.
  enum EdgeSource { case developer, couplers, standIn }
  struct Edge { var gain: Double; var um: Double; var source: EdgeSource }

  /// Inhibition strength and spread of the edge effect, or why there is none. Black-and-white film
  /// gets it from the developer; colour film from its own DIR couplers (same-layer gamma times the
  /// coupler amount), or from this module standing in while they are off.
  static func edge(_ values: [String: ParamValue]) -> (edge: Edge?, reason: String) {
    guard let film = Catalog.films[safe: values["film"]?.intValue ?? -1] else {
      return (nil, tr("필름을 고르면 나타납니다", "Pick a film stock"))
    }
    if FilmInfo.category(film) == .bw {
      guard values["adjacencyEnabled"]?.boolValue == true else {
        return (nil, tr("인접 효과가 꺼져 있음 · 켜면 현상액 값으로 그립니다", "Adjacency effects are off"))
      }
      guard let g = edgeGain(values), let um = diffusionUm(values) else {
        return (nil, tr("이 현상액은 가장자리 효과가 거의 없음", "This developer makes almost no edge effect"))
      }
      return (Edge(gain: g, um: um, source: .developer), "")
    }
    func number(_ name: String) -> Double {
      values[name]?.doubleValue ?? Catalog.byName[name]?.defaultParamValue.doubleValue ?? 0
    }
    var same = (values["dirGammaSameLayerRgb"] ?? Catalog.byName["dirGammaSameLayerRgb"]?.defaultParamValue)?.vectorValue ?? [0, 0, 0]
    if FilmInfo.isPositive(film), values["dirGammaSameLayerRgb"] == nil
        || values["dirGammaSameLayerRgb"] == Catalog.byName["dirGammaSameLayerRgb"]?.defaultParamValue {
      same = Catalog.positiveDirGammas[0].1
    }
    let gamma = same.reduce(0, +) / Double(max(same.count, 1))
    let couplers = number("dirCouplersAmount")
    if couplers > 0 {
      return (Edge(gain: couplers * gamma * number("dirCouplersInhibitionSameLayer"), um: number("dirCouplersDiffusionUm"),
                   source: .couplers), "")
    }
    if applies(values, film: film) {
      let strength = max(values["adjacencyStrength"]?.doubleValue ?? 1, 0)
      return (Edge(gain: strength * standIn * gamma, um: number("dirCouplersDiffusionUm"), source: .standIn), "")
    }
    return (nil, isColorNegative(film)
            ? tr("DIR 커플러와 인접 효과가 모두 꺼져 있음", "DIR couplers and adjacency effects are both off")
            : tr("DIR 커플러가 꺼져 있음", "DIR couplers are off"))
  }

  static func apply(_ values: [String: ParamValue], film: String, to p: inout SpektraAppRenderParams) {
    guard applies(values, film: film) else { return }
    let agi = agitation(values)
    let strength = max(values["adjacencyStrength"]?.doubleValue ?? 1, 0)
    guard FilmInfo.category(film) == .bw else {
      // Colour negative: the film's own DIR couplers already make this edge effect, so the pass is
      // neither overridden nor added to while they are on. With them off it stands in, with a
      // touch of interlayer inhibition (saturation).
      let couplers = values["dirCouplersAmount"]?.doubleValue ?? Catalog.byName["dirCouplersAmount"]?.defaultParamValue.doubleValue ?? 0
      guard couplers <= 0 else { return }
      SpektraAppSetDoubleParam(&p, "dirCouplersAmount", strength * standIn)
      SpektraAppSetDoubleParam(&p, "dirCouplersInhibitionInterlayer", 0.04)
      return
    }
    let dev = Developer.character(values, film: film)
    let g = (dev.adjacencyGamma ?? 0.10) * agitationGain[agi]
    SpektraAppSetDoubleParam(&p, "dirCouplersAmount", strength)
    SpektraAppSetDoubleParam(&p, "dirCouplersInhibitionSameLayer", 1)
    SpektraAppSetDoubleParam(&p, "dirCouplersInhibitionInterlayer", 0)
    SpektraAppSetDouble3Param(&p, "dirGammaSameLayerRgb", g, g, g)
    SpektraAppSetDoubleParam(&p, "dirCouplersDiffusionUm", (dev.adjacencyUm ?? 50) * agitationSpread[agi])
    SpektraAppSetDoubleParam(&p, "dirCouplersDiffusionTailUm", tailUm[agi])
    SpektraAppSetDoubleParam(&p, "dirCouplersDiffusionTailWeight", tailWeight[agi])
  }
}
