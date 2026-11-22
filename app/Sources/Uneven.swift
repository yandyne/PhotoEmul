// PhotoEmul - native editor for spektrafilm (GPL-3.0-or-later)
// Uneven development: process defects offered as looks.
//
// The engine scales developed film density per position (spektra_uneven_development in
// SpektraFilm.metal), from film millimetres so the pattern holds across proxies, tiles and exports.
// Five kinds, each with its own amount:
//   mottling        cloudy patches from tired developer or too little agitation
//   edge            more development along the strip edges, where fresh developer arrives first
//   surge marks     dense streaks running in from the perforations (rotary or vigorous agitation)
//   air bells       bubbles on the emulsion keep developer off small round spots (thin on the negative)
//   low level       one long side stayed above too little developer (an undeveloped band)
// The midgray reference stays even, so the print exposure does not shift with the pattern.

import CSpektra
import Foundation

enum Uneven {
  static let amounts = ["unevenMottle", "unevenEdge", "unevenSurge", "unevenAirBells", "unevenLowLevel"]

  static func apply(_ values: [String: ParamValue], to p: inout SpektraAppRenderParams) {
    guard values["unevenEnabled"]?.boolValue == true else { return }
    for name in amounts {
      let def = Catalog.byName[name]?.defaultParamValue.doubleValue ?? 0
      SpektraAppSetDoubleParam(&p, name, max(values[name]?.doubleValue ?? def, 0) / 100)
    }
    SpektraAppSetDoubleParam(&p, "unevenSeed", Double(max(0, values["unevenSeed"]?.intValue ?? 1)))
  }
}
