// PhotoEmul - native editor for spektrafilm (GPL-3.0-or-later)
// Darkroom test strip: the photo split into bands, each printed at a different exposure.
//
// One composition serves both uses: the strip shown as a tool (click a band to take its exposure)
// and the strip kept as an effect (testStripEffect, saved and exported). Each band is rendered
// only over its own area when the look allows region renders, so a strip costs about one frame.

import AppKit
import Foundation

enum TestStrip {
  static let counts = [3, 5, 7, 9]
  static let steps = [1.0 / 3.0, 0.5, 1.0]

  /// Where the lightest band sits; the bands get darker away from it.
  enum Direction: Int {
    case leftToRight, rightToLeft, topToBottom, bottomToTop
    var vertical: Bool { self == .topToBottom || self == .bottomToTop }
    var reversed: Bool { self == .rightToLeft || self == .bottomToTop }
  }

  /// What the bands vary: the print exposure, or one of the two split-grade exposures.
  enum Target: Int { case exposure, soft, hard }

  /// The strip is part of the picture: the effect is on and the image is printed.
  static func effectOn(_ v: [String: ParamValue]) -> Bool {
    v["testStripEffect"]?.boolValue == true && Darkroom.isPrinting(v)
  }

  /// Split-grade strips only exist while split grade is on black-and-white paper.
  static func splitAvailable(_ v: [String: ParamValue]) -> Bool {
    Darkroom.onGradedPaper(v) && v["printSplitGrade"]?.boolValue == true
  }

  struct Config {
    let count: Int, step: Double, direction: Direction, target: Target, labels: Bool

    init(_ v: [String: ParamValue]) {
      func pick(_ name: String) -> Int {
        v[name]?.intValue ?? Catalog.byName[name]?.defaultParamValue.intValue ?? 0
      }
      count = TestStrip.counts[safe: pick("testStripCount")] ?? 5
      step = TestStrip.steps[safe: pick("testStripStep")] ?? 1.0 / 3.0
      direction = Direction(rawValue: pick("testStripDirection")) ?? .leftToRight
      let t = Target(rawValue: pick("testStripTarget")) ?? .exposure
      target = TestStrip.splitAvailable(v) ? t : .exposure
      labels = v["testStripLabels"]?.boolValue ?? true
    }

    /// Print exposure offsets of the bands, lighter to darker.
    var offsets: [Double] { (0..<count).map { (Double($0) - Double(count - 1) / 2) * step } }

    var param: String {
      switch target {
      case .exposure: "printExposureEv"
      case .soft: "printSoftSeconds"
      case .hard: "printHardSeconds"
      }
    }

    /// Value of band `index`: the exposure in EV, or the split time scaled by 2^offset
    /// (a strip starting from 0 s would stay at 0, so it starts from at least 1 s).
    func value(_ index: Int, _ v: [String: ParamValue]) -> Double {
      let base = v[param]?.doubleValue ?? Catalog.byName[param]?.defaultParamValue.doubleValue ?? 0
      let offset = offsets[safe: index] ?? 0
      return target == .exposure ? base + offset : min(max(base, 1) * pow(2, offset), 40)
    }

    /// Exposure time of band `index` in seconds (10 s reference for the print exposure).
    func seconds(_ index: Int, _ v: [String: ParamValue]) -> Double {
      let x = value(index, v)
      return target == .exposure ? Darkroom.referenceSeconds * pow(2, x) : x
    }

    func label(_ index: Int, _ v: [String: ParamValue]) -> String {
      TestStrip.offsetLabel(offsets[safe: index] ?? 0) + " · " + TestStrip.secondsLabel(seconds(index, v))
    }

    /// The values band `index` renders with; the strip itself is off in them.
    func bandValues(_ index: Int, _ v: [String: ParamValue]) -> [String: ParamValue] {
      var b = v
      b["testStripEffect"] = .bool(false)
      b[param] = .double(value(index, v))
      return b
    }

    /// The band under a point given as fractions of the image (x from the left, y from the top).
    func band(x: Double, y: Double) -> Int {
      let slot = min(count - 1, max(0, Int((direction.vertical ? y : x) * Double(count))))
      return direction.reversed ? count - 1 - slot : slot
    }

    /// Pixels of band `index` in a w × h frame.
    func rect(_ index: Int, width w: Int, height h: Int) -> CGRect {
      let slot = direction.reversed ? count - 1 - index : index
      if direction.vertical {
        let y0 = h * slot / count, y1 = h * (slot + 1) / count
        return CGRect(x: 0, y: y0, width: w, height: y1 - y0)
      }
      let x0 = w * slot / count, x1 = w * (slot + 1) / count
      return CGRect(x: x0, y: 0, width: x1 - x0, height: h)
    }
  }

  // MARK: Rendering

  /// The whole frame with the strip in it.
  static func render(
    _ engine: SpektraEngine, source: PixelBuffer, values: [String: ParamValue], output: Int32, bytesPerComponent: Int
  ) -> PixelBuffer? {
    let c = Config(values), w = source.width, h = source.height
    var plain = values
    plain["testStripEffect"] = .bool(false)
    let out = PixelBuffer(width: w, height: h, bytesPerComponent: bytesPerComponent)
    let pre = RenderPipeline.supportsRegion(plain) ? RenderPipeline.preEffects(source, values: plain) : nil
    for i in 0..<c.count {
      let r = c.rect(i, width: w, height: h)
      guard !r.isEmpty else { continue }
      let b = c.bandValues(i, values)
      if let pre {
        guard let band = RenderPipeline.render(
          engine, source: source, region: r, values: b, output: output, bytesPerComponent: bytesPerComponent, preApplied: pre)
        else { return nil }
        blit(band, into: out, at: r.origin)
      } else {
        // Frame-wide looks (dust, frame, ...) cannot render a band alone: render it all, keep the band.
        guard let full = RenderPipeline.render(engine, source: source, values: b, output: output, bytesPerComponent: bytesPerComponent),
              let band = full.cropped(to: r)
        else { return nil }
        blit(band, into: out, at: r.origin)
      }
    }
    if c.labels { drawLabels(out, origin: .zero, frame: (w, h), config: c, values: plain) }
    return out
  }

  /// Only `region` of the frame with the strip in it (detail tiles, tiled export).
  static func render(
    _ engine: SpektraEngine, source: PixelBuffer, region r: CGRect, values: [String: ParamValue], output: Int32,
    bytesPerComponent: Int, preApplied: PixelBuffer?
  ) -> PixelBuffer? {
    let c = Config(values), w = source.width, h = source.height
    var plain = values
    plain["testStripEffect"] = .bool(false)
    let pre = preApplied ?? RenderPipeline.preEffects(source, values: plain)
    let out = PixelBuffer(width: Int(r.width), height: Int(r.height), bytesPerComponent: bytesPerComponent)
    for i in 0..<c.count {
      let part = c.rect(i, width: w, height: h).intersection(r)
      guard !part.isEmpty else { continue }
      guard let band = RenderPipeline.render(
        engine, source: source, region: part, values: c.bandValues(i, values), output: output,
        bytesPerComponent: bytesPerComponent, preApplied: pre)
      else { return nil }
      blit(band, into: out, at: CGPoint(x: part.minX - r.minX, y: part.minY - r.minY))
    }
    if c.labels { drawLabels(out, origin: r.origin, frame: (w, h), config: c, values: plain) }
    return out
  }

  private static func blit(_ src: PixelBuffer, into dst: PixelBuffer, at o: CGPoint) {
    guard src.bytesPerComponent == dst.bytesPerComponent else { return }
    let px = 4 * dst.bytesPerComponent, x = Int(o.x), y0 = Int(o.y)
    let cols = min(src.width, dst.width - x)
    guard cols > 0, x >= 0, y0 >= 0 else { return }
    for y in 0..<min(src.height, dst.height - y0) {
      memcpy(dst.data + (y0 + y) * dst.rowBytes + x * px, src.data + y * src.rowBytes, cols * px)
    }
  }

  // MARK: Labels

  /// Band offset as photographers write it: ±0, +1/3, −1/2, +1.
  static func offsetLabel(_ offset: Double) -> String {
    if abs(offset) < 1e-6 { return "±0" }
    let thirds = offset * 3
    let text: String
    if abs(thirds - thirds.rounded()) < 1e-6, abs(offset - offset.rounded()) > 1e-6 {
      text = "\(Int(abs(thirds.rounded())))/3"
    } else if abs(offset * 2 - (offset * 2).rounded()) < 1e-6, abs(offset - offset.rounded()) > 1e-6 {
      text = "\(Int(abs((offset * 2).rounded())))/2"
    } else {
      text = "\(Int(abs(offset.rounded())))"
    }
    return (offset > 0 ? "+" : "−") + text
  }

  static func secondsLabel(_ t: Double) -> String {
    t < 10 ? String(format: tr("%.1f초", "%.1f s"), t) : String(format: tr("%.0f초", "%.0f s"), t)
  }

  /// Writes each band's offset and time in its corner, as on a real strip. `out` holds the frame
  /// area starting at `origin`; the labels are laid out on the whole frame, so tiles agree.
  private static func drawLabels(
    _ out: PixelBuffer, origin: CGPoint, frame: (Int, Int), config c: Config, values: [String: ParamValue]
  ) {
    let (w, h) = frame
    let size = CGFloat(max(9, min(w, h))) / 34
    let font = NSFont.monospacedDigitSystemFont(ofSize: size, weight: .semibold)
    for i in 0..<c.count {
      let band = c.rect(i, width: w, height: h)
      let str = NSAttributedString(string: c.label(i, values), attributes: [.font: font, .foregroundColor: NSColor.white])
      let box = CGRect(origin: CGPoint(x: band.minX + size * 0.4, y: band.minY + size * 0.4), size: str.size())
        .insetBy(dx: -size * 0.3, dy: -size * 0.12).integral
      // Only the part of the box inside this buffer.
      let local = box.offsetBy(dx: -origin.x, dy: -origin.y)
        .intersection(CGRect(x: 0, y: 0, width: out.width, height: out.height))
      guard !local.isEmpty else { continue }
      // Drawn into an 8-bit mask the size of the box, then blended into the half or float pixels.
      let bw = Int(box.width), bh = Int(box.height)
      guard let cg = CGContext(data: nil, width: bw, height: bh, bitsPerComponent: 8, bytesPerRow: bw * 4,
                               space: CGColorSpaceCreateDeviceRGB(),
                               bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
            let mask = cg.data
      else { continue }
      NSGraphicsContext.saveGraphicsState()
      NSGraphicsContext.current = NSGraphicsContext(cgContext: cg, flipped: true)
      cg.translateBy(x: 0, y: CGFloat(bh))
      cg.scaleBy(x: 1, y: -1)
      let r = CGRect(x: 0, y: 0, width: bw, height: bh)
      NSColor(white: 0, alpha: 0.55).setFill()
      NSBezierPath(roundedRect: r, xRadius: size * 0.25, yRadius: size * 0.25).fill()
      str.draw(at: CGPoint(x: size * 0.3, y: size * 0.12))
      NSGraphicsContext.restoreGraphicsState()
      blend(mask.assumingMemoryBound(to: UInt8.self), maskOrigin: CGPoint(x: box.minX - origin.x, y: box.minY - origin.y),
            maskWidth: bw, rect: local, into: out)
    }
  }

  /// out = out × (1 − a) + c, with c the premultiplied mask colour (the mask rows run top down).
  private static func blend(_ m: UnsafeMutablePointer<UInt8>, maskOrigin o: CGPoint, maskWidth mw: Int, rect: CGRect,
                            into out: PixelBuffer) {
    let half = out.bytesPerComponent == 2
    for y in Int(rect.minY)..<Int(rect.maxY) {
      let my = y - Int(o.y)
      for x in Int(rect.minX)..<Int(rect.maxX) {
        let mi = (my * mw + x - Int(o.x)) * 4
        let a = Float(m[mi + 3]) / 255
        guard a > 0 else { continue }
        let p = y * out.width * 4 + x * 4
        for k in 0..<3 {
          let cv = Float(m[mi + k]) / 255
          if half {
            let h = out.data.assumingMemoryBound(to: UInt16.self)
            h[p + k] = floatToHalf(halfToFloat(h[p + k]) * (1 - a) + cv)
          } else {
            out.floats[p + k] = out.floats[p + k] * (1 - a) + cv
          }
        }
      }
    }
  }

  /// Float to IEEE half, rounded to nearest; enough for pixel values.
  private static func floatToHalf(_ f: Float) -> UInt16 {
    let bits = f.bitPattern
    let sign = UInt16((bits >> 16) & 0x8000)
    let v = abs(f)
    if v.isNaN { return 0x7e00 }
    if v >= 65520 { return sign | 0x7c00 }
    if v < 0x1p-14 { return sign | UInt16((v * 0x1p24).rounded()) }
    var e = UInt32(Int((bits >> 23) & 0xff) - 127 + 15)
    var mant = ((bits & 0x7f_ffff) + 0x1000) >> 13
    if mant == 0x400 { e += 1; mant = 0 }
    return sign | UInt16(e << 10 | mant)
  }
}
