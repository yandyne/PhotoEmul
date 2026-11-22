// PhotoEmul - native editor for spektrafilm (GPL-3.0-or-later)
// Scene light spectra for the "sceneIlluminant" choices, for the panel graph.
//
// The same analytic models the engine renders with (sceneIlluminantSpectrum in
// SpektraMetalRenderer.mm): Planck's law for the incandescent and daylight-like sources (their
// colour temperatures follow the CIE definitions of illuminant A and the D series), Gaussian
// phosphor bands plus mercury lines for the fluorescent tubes, broadened D lines for sodium.
// Keep the two in step; the graph shows what the render uses, not a measured table.

import Foundation

enum Illuminants {
  /// Planck radiance relative to its value at 560 nm.
  static func planck(_ wl: Double, kelvin: Double) -> Double {
    let c2 = 1.4388e7
    let value = pow(wl / 560, -5) / expm1(c2 / (wl * kelvin))
    return value / (1 / expm1(c2 / (560 * kelvin)))
  }

  private static func band(_ wl: Double, _ centre: Double, _ sigma: Double) -> Double {
    let d = (wl - centre) / sigma
    return exp(-0.5 * d * d)
  }

  /// Relative spectral power of "sceneIlluminant" choice `kind` (0 = film balance).
  static func spectrum(_ kind: Int, _ wl: Double) -> Double {
    switch kind {
    case 1: return planck(wl, kelvin: 5500)
    case 2: return planck(wl, kelvin: 7500)
    case 3: return planck(wl, kelvin: 12000)
    case 4: return planck(wl, kelvin: 3200)
    case 5: return planck(wl, kelvin: 2700)
    case 6: return planck(wl, kelvin: 1900)
    case 7:
      return band(wl, 562, 40) + 0.30 * band(wl, 470, 30) + 0.30 * band(wl, 405, 3) + 0.70 * band(wl, 436, 3)
        + 0.90 * band(wl, 546, 3) + 0.45 * band(wl, 578, 3) + 0.03
    case 8:
      return 0.06 + 0.55 * band(wl, 436, 4) + 0.15 * band(wl, 487, 6) + 1.00 * band(wl, 545, 5) + 0.90 * band(wl, 611, 6)
    case 9:
      return 0.02 + band(wl, 589, 8) + 0.35 * band(wl, 595, 30) + 0.05 * band(wl, 470, 8) + 0.08 * band(wl, 819, 6)
    case 10:
      return 0.01 + 1.35 * band(wl, 450, 10) + band(wl, 560, 50) + 0.20 * band(wl, 620, 35)
    case 11:
      return planck(wl, kelvin: 6000) + 0.10 * band(wl, 467, 2) + 0.08 * band(wl, 473, 2)
        + 0.60 * band(wl, 823, 3) + 0.70 * band(wl, 881, 4)
    case 12:
      return 0.04 + 0.40 * band(wl, 405, 3) + 0.85 * band(wl, 436, 3) + 1.00 * band(wl, 546, 4)
        + 0.75 * band(wl, 578, 4) + 0.05 * band(wl, 615, 30)
    default: return 1
    }
  }

  /// Colour temperature the film is balanced for: motion-picture "T" stocks are tungsten.
  static func balanceKelvin(film: String) -> Double {
    if film.contains("eterna") && !film.contains("3513") { return 3200 }
    if film.range(of: #"\d+t(_|$)"#, options: .regularExpression) != nil { return 3200 }
    return 5500
  }
}
