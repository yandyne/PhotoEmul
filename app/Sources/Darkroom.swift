// PhotoEmul - native editor for spektrafilm (GPL-3.0-or-later)
// The black-and-white darkroom: enlarger light source, paper grade, split-grade printing.
//
// Paper grades follow the ISO R (exposure range) of a variable-contrast paper such as Ilford
// Multigrade: grade 2 is R 110, the stock's own curve. A grade scales the print gamma about
// mid-grey by 110 / R. Split grade exposes the paper twice, through the softest (00) and the
// hardest (5) filter; the two exposures add as light, so the soft one sets the highlights and the
// hard one the shadows. Times are seconds against a 10 s reference, so 5 s + 5 s prints mid-grey
// a little lighter than one 10 s exposure.
//
// The light source changes the Callier Q of the silver image: a condenser's collimated light is
// scattered out of the lens by the silver grains, so the negative prints with more contrast, and
// dust and scratches print sharper and darker. Dye images scatter little, so colour negatives
// keep their contrast.

import CSpektra
import Foundation

enum Darkroom {
  static let params = ["enlargerLightSource", "paperGradeHalf", "printSplitGrade", "printSoftSeconds", "printHardSeconds"]

  static let gradeLabels = ["00", "0", "½", "1", "1½", "2", "2½", "3", "3½", "4", "4½", "5"]
  /// ISO R of each grade (Ilford Multigrade datasheet values, rounded); half grades sit midway
  /// between the whole grades. There is no half grade between 00 and 0.
  static let isoR: [Double] = [180, 160, 145, 130, 120, 110, 100, 90, 80, 70, 60, 50]
  static let defaultGrade = 5          // grade 2
  /// 0.1.82–0.1.86 stored whole grades 00…5 as 0…6 under "paperGrade".
  static let legacyGradeMap = [0, 1, 3, 5, 7, 9, 11]
  static let referenceSeconds = 10.0

  static let lightSources = ["Diffuser", "Condenser", "Cold light (cathode)", "Point source"]
  /// Callier Q relative to the diffuse density the film curves were measured with.
  static let callierQ: [Double] = [1.0, 1.3, 0.95, 1.5]
  /// How much more of a dust speck's shadow reaches the paper.
  static let dustGain: [Float] = [1.0, 1.3, 0.85, 1.5]
  /// The condenser's collimated light also prints the silver grains' shadows more crisply:
  /// the same direction as dust, a smaller spread.
  static let grainGain: [Double] = [1.0, 1.25, 0.9, 1.4]

  static func gamma(grade: Int) -> Double { 110 / isoR[min(max(grade, 0), isoR.count - 1)] }

  /// The image goes through the enlarger (a print of a negative, simulated or given), not a scan.
  static func isPrinting(_ values: [String: ParamValue]) -> Bool {
    Catalog.films[safe: values["film"]?.intValue ?? -1] != nil && ProcessScope.mode(values) != 1
  }

  /// Printed onto a black-and-white (graded or variable-contrast) paper.
  static func onGradedPaper(_ values: [String: ParamValue]) -> Bool {
    guard isPrinting(values), let paper = Catalog.papers[safe: values["paper"]?.intValue ?? -1] else { return false }
    return FilmInfo.monoPapers.contains(paper)
  }

  /// Printing a black-and-white negative: the light source matters (Callier effect).
  static func isBwPrinting(_ values: [String: ParamValue]) -> Bool {
    guard isPrinting(values), let film = Catalog.films[safe: values["film"]?.intValue ?? -1] else { return false }
    return FilmInfo.category(film) == .bw
  }

  static func source(_ values: [String: ParamValue]) -> Int {
    min(max(values["enlargerLightSource"]?.intValue ?? 0, 0), lightSources.count - 1)
  }

  static func dustVisibility(_ values: [String: ParamValue]) -> Float {
    isPrinting(values) ? dustGain[source(values)] : 1
  }

  static func grainVisibility(_ values: [String: ParamValue]) -> Double {
    isBwPrinting(values) ? grainGain[source(values)] : 1
  }

  static func apply(_ values: [String: ParamValue], to p: inout SpektraAppRenderParams) {
    guard isPrinting(values), let film = Catalog.films[safe: values["film"]?.intValue ?? -1] else { return }
    if FilmInfo.category(film) == .bw {
      SpektraAppSetDoubleParam(&p, "printCallierQ", callierQ[source(values)])
      // The light source's grain gain is written with the developer's in Engine.renderParams.
    }
    guard onGradedPaper(values) else { return }
    if values["printSplitGrade"]?.boolValue == true {
      func offset(_ name: String) -> Double {
        let t = values[name]?.doubleValue ?? 5
        return t > 0.01 ? log10(t / referenceSeconds) : -30
      }
      SpektraAppSetIntParam(&p, "printSplitGrade", 1)
      SpektraAppSetDoubleParam(&p, "printSoftGamma", gamma(grade: 0))
      SpektraAppSetDoubleParam(&p, "printHardGamma", gamma(grade: isoR.count - 1))
      SpektraAppSetDoubleParam(&p, "printSoftLogOffset", offset("printSoftSeconds"))
      SpektraAppSetDoubleParam(&p, "printHardLogOffset", offset("printHardSeconds"))
    } else {
      let grade = values["paperGradeHalf"]?.intValue ?? defaultGrade
      SpektraAppSetDoubleParam(&p, "printGamma", (values["printGamma"]?.doubleValue ?? 1) * gamma(grade: grade))
    }
  }
}
