// PhotoEmul - native editor for spektrafilm (GPL-3.0-or-later)
// Bakes the colour part of the current look into a 3D LUT (.cube, sRGB in / sRGB out).
// Spatial and random effects (grain, halation, diffusion, DIR diffusion, sharpening,
// app effects) cannot live in a LUT, so they are switched off for the bake.

import CSpektra
import Foundation

enum LutExport {
  static let size = 33
  /// Each lattice point is rendered as a small block and read at its centre, so any
  /// leftover neighbourhood filtering in the engine cannot mix lattice entries.
  private static let block = 4

  /// Values with everything that is not a per-pixel colour transform disabled.
  static func colourOnly(_ values: [String: ParamValue]) -> [String: ParamValue] {
    var v = values
    for name in ["grainEnabled", "halationEnabled", "cameraDiffusionEnabled", "printDiffusionEnabled", "autoExposure"] {
      v[name] = .bool(false)
    }
    v["dirCouplersDiffusionUm"] = .double(0)
    v["dirCouplersDiffusionTailWeight"] = .double(0)
    v["glarePercent"] = .double(0)
    v["scannerMtf50LpMm"] = .double(0)
    v["scannerUnsharpAmount"] = .double(0)
    return v
  }

  static func export(values: [String: ParamValue], to url: URL, title: String) throws {
    try table(values: values).write(to: url, title: title)
  }

  /// A baked n³ table, red fastest.
  struct Table {
    let n: Int
    let rgb: [Float]

    func write(to url: URL, title: String) throws {
      var text = "# Created by PhotoEmul (spektrafilm). Colour only: grain, halation, diffusion, sharpening and auto exposure are not included.\n"
      text += "TITLE \"\(title.replacingOccurrences(of: "\"", with: "'"))\"\nLUT_3D_SIZE \(n)\nDOMAIN_MIN 0.0 0.0 0.0\nDOMAIN_MAX 1.0 1.0 1.0\n"
      text.reserveCapacity(text.count + n * n * n * 28)
      for i in 0..<(n * n * n) {
        text += String(format: "%.6f %.6f %.6f\n", rgb[i * 3], rgb[i * 3 + 1], rgb[i * 3 + 2])
      }
      try text.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Trilinear lookup of an sRGB-encoded colour.
    func apply(_ c: (Float, Float, Float)) -> (Float, Float, Float) {
      let m = Float(n - 1)
      func split(_ v: Float) -> (Int, Float) {
        let x = min(max(v, 0), 1) * m
        let i = min(Int(x), n - 2)
        return (i, x - Float(i))
      }
      let (r0, fr) = split(c.0), (g0, fg) = split(c.1), (b0, fb) = split(c.2)
      var out: (Float, Float, Float) = (0, 0, 0)
      for corner in 0..<8 {
        let dr = corner & 1, dg = (corner >> 1) & 1, db = corner >> 2
        let w = (dr == 1 ? fr : 1 - fr) * (dg == 1 ? fg : 1 - fg) * (db == 1 ? fb : 1 - fb)
        let i = (((b0 + db) * n + (g0 + dg)) * n + (r0 + dr)) * 3
        out.0 += w * rgb[i]; out.1 += w * rgb[i + 1]; out.2 += w * rgb[i + 2]
      }
      return out
    }
  }

  static func table(values: [String: ParamValue]) throws -> Table {
    let n = size, b = block
    let w = n * n * b, h = n * b
    let lattice = PixelBuffer(width: w, height: h, bytesPerComponent: 4)
    // x = (r + n * b_index), y = g; red runs fastest as .cube expects.
    let f = lattice.floats
    for y in 0..<h {
      let g = Float(y / b) / Float(n - 1)
      for x in 0..<w {
        let cell = x / b
        let r = Float(cell % n) / Float(n - 1), bl = Float(cell / n) / Float(n - 1)
        let i = (y * w + x) * 4
        f[i] = r; f[i + 1] = g; f[i + 2] = bl; f[i + 3] = 1
      }
    }
    let engine = SpektraEngine()
    let out = PixelBuffer(width: w, height: h, bytesPerComponent: 4)
    var p = Catalog.renderParams(colourOnly(values), output: SpektraAppSrgbColorSpace())
    p.inputColorSpace = SpektraAppSrgbColorSpace()
    guard engine.render(lattice, into: out, params: p) else {
      throw NSError(domain: "PhotoEmul", code: 2, userInfo: [NSLocalizedDescriptionKey: tr("LUT 렌더 실패: ", "LUT render failed: ") + engine.lastError])
    }
    let o = out.floats
    var rgb = [Float](repeating: 0, count: n * n * n * 3)
    for bi in 0..<n {
      for gi in 0..<n {
        for ri in 0..<n {
          let x = (bi * n + ri) * b + b / 2, y = gi * b + b / 2
          let i = (y * w + x) * 4, j = ((bi * n + gi) * n + ri) * 3
          for c in 0..<3 { rgb[j + c] = min(max(o[i + c], 0), 1) }
        }
      }
    }
    if FilmInfo.isMono(values) {
      let tone = values["bwToning"]?.intValue ?? 0, amount = Float(values["bwToningAmount"]?.doubleValue ?? 0.5)
      for j in stride(from: 0, to: rgb.count, by: 3) {
        let m = MonoTone.apply((rgb[j], rgb[j + 1], rgb[j + 2]), tone: tone, amount: amount)
        rgb[j] = min(max(m.0, 0), 1); rgb[j + 1] = min(max(m.1, 0), 1); rgb[j + 2] = min(max(m.2, 0), 1)
      }
    }
    return Table(n: n, rgb: rgb)
  }

  /// Compares the LUT on a real photo with the engine itself (sRGB in → sRGB out, and the
  /// app's linear Rec.2020 input → sRGB out). Prints 8-bit errors.
  static func verify(values: [String: ParamValue], image url: URL) throws -> String {
    let src = try SourceImage.load(url)
    guard let srgb = src.srgbPixels(maxEdge: 1200), let linear = src.linearPixels(maxEdge: 1200) else {
      throw ImageFileError.unreadable(url.path)
    }
    // Out-of-gamut colours cannot reach a LUT; clip them so both paths see the same input.
    let sf = srgb.floats
    for i in 0..<(srgb.width * srgb.height * 4) { sf[i] = min(max(sf[i], 0), 1) }
    let table = try table(values: values)
    let engine = SpektraEngine()
    let colour = colourOnly(values)
    func render(_ input: PixelBuffer, inputSpace: Int32?) throws -> PixelBuffer {
      let out = PixelBuffer(width: input.width, height: input.height, bytesPerComponent: 4)
      var p = Catalog.renderParams(colour, output: SpektraAppSrgbColorSpace())
      if let inputSpace { p.inputColorSpace = inputSpace }
      guard engine.render(input, into: out, params: p) else {
        throw NSError(domain: "PhotoEmul", code: 2, userInfo: [NSLocalizedDescriptionKey: engine.lastError])
      }
      return out
    }
    let refSrgb = try render(srgb, inputSpace: SpektraAppSrgbColorSpace())
    let refLinear = try render(linear, inputSpace: nil)
    func stats(_ ref: PixelBuffer) -> String {
      var errs: [Float] = []
      errs.reserveCapacity(srgb.width * srgb.height)
      let s = srgb.floats, r = ref.floats
      for p in 0..<(srgb.width * srgb.height) {
        let i = p * 4
        let l = table.apply((s[i], s[i + 1], s[i + 2]))
        let e = max(abs(l.0 - min(max(r[i], 0), 1)), abs(l.1 - min(max(r[i + 1], 0), 1)), abs(l.2 - min(max(r[i + 2], 0), 1)))
        errs.append(e * 255)
      }
      errs.sort()
      let mean = errs.reduce(0, +) / Float(errs.count)
      return String(format: "mean %.2f  p99 %.2f  max %.2f (8-bit levels)", mean, errs[errs.count * 99 / 100], errs.last ?? 0)
    }
    return "LUT vs engine (sRGB input):          " + stats(refSrgb) + "\n"
      + "LUT vs engine (app linear input):    " + stats(refLinear)
  }
}
