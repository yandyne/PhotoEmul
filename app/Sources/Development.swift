// PhotoEmul - native editor for spektrafilm (GPL-3.0-or-later)
// Development temperature / time and film aging, mapped onto the engine's per-channel
// development modifiers (speed shift, contrast, density scale, fog).
//
// These are rules of thumb, not measured data:
//   - developer activity roughly follows exp(k ΔT): ~9 %/°C for black-and-white, ~10 %/°C for
//     colour chemistry; a longer or hotter development raises contrast (gamma ~ t^0.35..0.45),
//     a little speed and a little fog;
//   - in multilayer film the bottom (red-sensitive, cyan-dye) layer is reached last by the
//     developer and reacts most to a short or cold development, the top (yellow) layer least;
//   - instant film (dye diffusion) prints lighter, flatter and cooler when cold, denser and
//     warmer when hot;
//   - expired colour negative loses about one stop per decade at room temperature and fogs,
//     the blue-sensitive (yellow-dye) layer first; reversal and instant film lose maximum density
//     instead (muddy blacks), with yellow and cyan fading before magenta;
//   - storage temperature follows Arrhenius kinetics with an activation energy near 80 kJ/mol
//     (dark fading and fog of colour materials, as used by the IPI storage guides): the rate
//     about doubles every 7 °C, so -18 / 4 / 21 / 30 °C age at about 0.02 / 0.19 / 1 / 2.4 x;
//   - relative humidity scales the rate roughly as (RH / 50 %)^1.3; above ~60 % RH the extra
//     moisture also fogs negatives (blue layer first) and stains instant prints yellow.

import CSpektra
import Foundation

enum Development {
  static let params: [String] = ["devTempDelta", "devTimePercent", "agingYears", "agingStorage", "agingHumidity"]

  /// Storage temperatures (°C) of the "agingStorage" choices.
  private static let storageTemperature: [Double] = [-18, 4, 21, 30]

  /// Years at 21 °C and 50 % RH per year of storage.
  private static func agingRate(temperature: Double, humidity: Double) -> Double {
    pow(2, (temperature - 21) / 7) * pow(max(humidity, 5) / 50, 1.3)
  }

  private enum Kind { case negative, positive, instant, mono, monoPositive }

  private static func kind(_ film: String) -> Kind {
    let category = FilmInfo.category(film)
    if category == .bw { return FilmInfo.isPositive(film) ? .monoPositive : .mono }
    if category == .instant { return .instant }
    return category == .slide ? .positive : .negative
  }

  private struct Modifiers {
    var shift = [0.0, 0.0, 0.0], gamma = [1.0, 1.0, 1.0], fog = [0.0, 0.0, 0.0], dmax = [1.0, 1.0, 1.0]
    var isNeutral: Bool { shift == [0, 0, 0] && gamma == [1, 1, 1] && fog == [0, 0, 0] && dmax == [1, 1, 1] }
  }

  static func apply(_ values: [String: ParamValue], film: String, to p: inout SpektraAppRenderParams) {
    let deltaT = values["devTempDelta"]?.doubleValue ?? 0
    let timeFactor = (values["devTimePercent"]?.doubleValue ?? 100) / 100
    let years = values["agingYears"]?.doubleValue ?? 0
    let temperature = storageTemperature[min(max(values["agingStorage"]?.intValue ?? 2, 0), storageTemperature.count - 1)]
    let humidity = values["agingHumidity"]?.doubleValue ?? 50
    let storage = agingRate(temperature: temperature, humidity: humidity)
    // Moisture beyond what the rate already covers (fog / stain), 0 at 60 % RH, 1 at 90 %.
    let damp = years > 0 ? max(min((humidity - 60) / 30, 1), 0) : 0
    let kind = kind(film)
    var m = Modifiers()

    // Development: equivalent time at the standard temperature, in doublings.
    let mono = kind == .mono || kind == .monoPositive
    let k = mono ? 0.09 : (kind == .instant ? 0.08 : 0.10)
    let doublings = log2(max(timeFactor, 0.05)) + k * deltaT / log(2)
    if doublings != 0 {
      switch kind {
      case .instant:
        // More dye transfers: denser, contrastier; colour follows the temperature.
        let warm = max(min(deltaT / 10, 1), -1)
        for c in 0..<3 {
          m.gamma[c] = pow(2, 0.25 * doublings)
          m.dmax[c] = pow(2, 0.12 * doublings)
        }
        m.shift = [0.06 * doublings - 0.04 * warm, 0.06 * doublings, 0.06 * doublings + 0.06 * warm]
        m.dmax[2] *= 1 + 0.10 * warm
        m.dmax[0] *= 1 - 0.04 * warm
      default:
        // Bottom layer reacts most, top layer least (no layers in black-and-white).
        let layer = mono ? [1.0, 1.0, 1.0] : [1.15, 1.0, 0.85]
        let exponent = mono ? 0.45 : 0.35
        for c in 0..<3 {
          m.gamma[c] = pow(2, exponent * layer[c] * doublings)
          // Negative and reversal both read more development as more exposure.
          m.shift[c] = -0.10 * layer[c] * doublings
        }
        if kind == .negative || kind == .mono {
          let fog = max(doublings, 0) * (mono ? 0.03 : 0.025)
          m.fog = mono ? [fog, fog, fog] : [fog * 0.8, fog, fog * 1.4]
        }
      }
    }

    // Aging: effective years at room temperature.
    let age = min(years * storage, 40)
    if age > 0 {
      switch kind {
      case .negative, .mono:
        let w = kind == .mono ? [1.0, 1.0, 1.0] : [0.85, 1.0, 1.2]
        for c in 0..<3 {
          m.shift[c] += min(0.03 * age * w[c], 0.6)
          m.fog[c] += min(0.008 * age * w[c], 0.45)
          m.gamma[c] *= 1 / (1 + 0.012 * age * w[c])
        }
        if damp > 0 {
          let fog = 0.04 * damp * min(age / 5, 1)
          m.fog[0] += fog * (kind == .mono ? 1 : 0.6)
          m.fog[1] += fog * (kind == .mono ? 1 : 0.8)
          m.fog[2] += fog * (kind == .mono ? 1 : 1.3)
        }
      case .positive, .instant, .monoPositive:
        let w = kind == .monoPositive ? [1.0, 1.0, 1.0] : [1.0, 0.7, 1.3]
        let rate = kind == .instant ? 0.016 : 0.010
        for c in 0..<3 {
          m.dmax[c] *= max(1 - rate * age * w[c], 0.45)
          m.gamma[c] *= 1 / (1 + 0.010 * age * w[c])
          m.shift[c] -= min(0.01 * age * w[c], 0.3)
        }
        if damp > 0 && kind == .instant {
          // Yellow stain: the blue-absorbing density rises in the highlights.
          m.fog[2] += 0.05 * damp * min(age / 5, 1)
        }
      }
    }

    // Long exposures: reciprocity failure (see Reciprocity.swift). A lost stop is a log10(2)
    // shift towards less exposure; layers that fail faster tint the image.
    if let r = Reciprocity.effect(values, film: film) {
      for c in 0..<3 {
        m.shift[c] += r.stops[c] * log10(2.0)
        m.gamma[c] *= r.gamma
      }
    }

    // Developer (black-and-white): contrast, and highlight compression as a lower density ceiling
    // and a little less contrast, since the engine has no shoulder of its own.
    let dev = Developer.character(values, film: film)
    if dev.gamma != 1 || dev.compression > 0 {
      let c = min(dev.compression, 2)
      for i in 0..<3 {
        m.gamma[i] *= dev.gamma * (1 - 0.1 * c)
        m.dmax[i] *= 1 - 0.25 * c
      }
    }

    guard !m.isNeutral else { return }
    for c in 0..<3 { m.gamma[c] = min(max(m.gamma[c], 0.4), 2.0) }
    SpektraAppSetDouble3Param(&p, "filmDevLogShift", m.shift[0], m.shift[1], m.shift[2])
    SpektraAppSetDouble3Param(&p, "filmDevGamma", m.gamma[0], m.gamma[1], m.gamma[2])
    SpektraAppSetDouble3Param(&p, "filmDevFog", m.fog[0], m.fog[1], m.fog[2])
    SpektraAppSetDouble3Param(&p, "filmDevDmax", m.dmax[0], m.dmax[1], m.dmax[2])
  }
}

/// Developer and dilution for black-and-white film. Starting values carry the relative wording of
/// the manufacturers' datasheets (fine grain, high acutance, compensating) as multiples of D-76
/// stock, which is 1.0 everywhere so the default renders as before. Colour processes use their
/// standard developer and stay neutral.
enum Developer {
  static let names = [
    "Standard (D-76 / ID-11)", "Fine grain (XTOL)", "Dilute compensating (HC-110)", "Acutance (Rodinal)",
    "Staining (Pyrocat-HD)", "C-41 standard", "ECN-2", "E-6 first developer",
  ]
  static let dilutions = ["Stock", "1+1", "1+3", "1+50", "1+100"]

  struct Character {
    var grainSize = 1.0, grainAmount = 1.0, gamma = 1.0, compression = 0.0
    /// Adjacency inhibition per unit of density and its diffusion length (µm); nil for colour.
    var adjacencyGamma: Double?, adjacencyUm: Double?
  }

  private static let table: [Character] = [
    Character(grainSize: 1.00, grainAmount: 1.00, gamma: 1.00, compression: 0.00, adjacencyGamma: 0.15, adjacencyUm: 60),
    // Kodak: finer grain than D-76, slightly more speed.
    Character(grainSize: 0.90, grainAmount: 0.90, gamma: 1.00, compression: 0.05, adjacencyGamma: 0.12, adjacencyUm: 55),
    // Kodak: compensating at dilution B.
    Character(grainSize: 1.05, grainAmount: 1.00, gamma: 0.95, compression: 0.15, adjacencyGamma: 0.15, adjacencyUm: 60),
    // Agfa: high acutance, crisp visible grain.
    Character(grainSize: 1.20, grainAmount: 1.10, gamma: 1.00, compression: 0.10, adjacencyGamma: 0.28, adjacencyUm: 75),
    // The stain masks the highlights (its colour is left out: the film is black-and-white).
    Character(grainSize: 0.95, grainAmount: 0.90, gamma: 0.90, compression: 0.25, adjacencyGamma: 0.22, adjacencyUm: 70),
    Character(), Character(), Character(),
  ]
  /// Dilution is how fast the developer exhausts: it scales adjacency strength and compression...
  private static let dilutionGain: [Double] = [1.0, 1.3, 1.6, 2.2, 2.8]
  /// ...and, less, how far the exhausted developer spreads.
  private static let dilutionSpread: [Double] = [1.0, 1.1, 1.2, 1.4, 1.6]

  static func index(_ values: [String: ParamValue]) -> Int { min(max(values["devDeveloper"]?.intValue ?? 0, 0), names.count - 1) }
  static func dilution(_ values: [String: ParamValue]) -> Int { min(max(values["devDilution"]?.intValue ?? 0, 0), dilutions.count - 1) }

  /// The developer's character with its dilution applied (black-and-white film only).
  static func character(_ values: [String: ParamValue], film: String) -> Character {
    guard FilmInfo.category(film) == .bw else { return Character() }
    var c = table[index(values)]
    let d = dilution(values)
    // Any developer compensates more when diluted, even D-76 which has no compression at stock.
    c.compression = c.compression * dilutionGain[d] + 0.05 * (dilutionGain[d] - 1) + max(values["devHighlightCompression"]?.doubleValue ?? 0, 0)
    c.adjacencyGamma = c.adjacencyGamma.map { $0 * dilutionGain[d] }
    c.adjacencyUm = c.adjacencyUm.map { $0 * dilutionSpread[d] }
    return c
  }

  /// Old "adjacencyDeveloper" choices as (developer, dilution).
  static let legacyAdjacency: [(Int, Int)] = [(0, 0), (0, 1), (3, 3), (3, 4)]
}
