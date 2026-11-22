// PhotoEmul - native editor for spektrafilm (GPL-3.0-or-later)
// Reference matching (AI plan stage 6): plain numbers for how a picture looks, so an AI can
// compare its draft with the user's reference photos and say how far apart they are.
import CoreGraphics
import Foundation
import ImageIO

struct Look {
  /// Channel means and luminance p5 / p50 / p95 (0…1, sRGB).
  var red = 0.0, green = 0.0, blue = 0.0
  var black = 0.0, mid = 0.0, white = 0.0
  /// Mean of max − min per pixel.
  var saturation = 0.0
  /// Mean |luminance − its 4 neighbours| at `edge` pixels: grain and fine texture.
  var grain = 0.0

  var warmth: Double { red - blue }
  var tint: Double { green - (red + blue) / 2 }
  var contrast: Double { white - black }

  static let edge = 512

  init() {}

  /// Measures `image` drawn into a small sRGB bitmap (colour-managed from its own space).
  init?(_ image: CGImage) {
    let scale = min(1, Double(Self.edge) / Double(max(image.width, image.height)))
    let w = max(1, Int(Double(image.width) * scale)), h = max(1, Int(Double(image.height) * scale))
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue), let data = ctx.data else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let px = data.bindMemory(to: UInt8.self, capacity: w * h * 4)
    var y = [Double](repeating: 0, count: w * h)
    var r = 0.0, g = 0.0, b = 0.0, sat = 0.0
    for i in 0..<(w * h) {
      let pr = Double(px[i * 4]) / 255, pg = Double(px[i * 4 + 1]) / 255, pb = Double(px[i * 4 + 2]) / 255
      r += pr; g += pg; b += pb
      sat += max(pr, pg, pb) - min(pr, pg, pb)
      y[i] = 0.2126 * pr + 0.7152 * pg + 0.0722 * pb
    }
    let n = Double(w * h)
    var hf = 0.0, m = 0
    if w > 2, h > 2 {
      for j in 1..<(h - 1) {
        for i in 1..<(w - 1) {
          let k = j * w + i
          hf += abs(y[k] - (y[k - 1] + y[k + 1] + y[k - w] + y[k + w]) / 4)
          m += 1
        }
      }
    }
    let sorted = y.sorted()
    let q = { (p: Double) in sorted[min(sorted.count - 1, Int(p * Double(sorted.count)))] }
    red = r / n; green = g / n; blue = b / n
    black = q(0.05); mid = q(0.5); white = q(0.95)
    saturation = sat / n
    grain = m > 0 ? hf / Double(m) : 0
  }

  /// Numbers by name, rounded for the AI.
  var json: [String: Double] {
    let all = ["warmth": warmth, "tint": tint, "black": black, "mid": mid, "white": white, "contrast": contrast,
               "saturation": saturation, "grain": grain, "red": red, "green": green, "blue": blue]
    return all.mapValues { ($0 * 1000).rounded() / 1000 }
  }

  /// 0 = same look; a plainly visible change in one number is about 0.05–0.1. Grain counts 4×
  /// because its values are small.
  func distance(_ o: Look) -> Double {
    let d = [warmth - o.warmth, tint - o.tint, black - o.black, mid - o.mid, white - o.white,
             saturation - o.saturation, 4 * (grain - o.grain)]
    return d.reduce(0) { $0 + $1 * $1 }.squareRoot()
  }

  static func mean(_ looks: [Look]) -> Look {
    var m = Look()
    let n = Double(max(looks.count, 1))
    for l in looks {
      m.red += l.red / n; m.green += l.green / n; m.blue += l.blue / n
      m.black += l.black / n; m.mid += l.mid / n; m.white += l.white / n
      m.saturation += l.saturation / n; m.grain += l.grain / n
    }
    return m
  }

  /// A reference photo, oriented, at most 1024 px.
  static func load(_ url: URL) -> CGImage? {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    return CGImageSourceCreateThumbnailAtIndex(src, 0, [
      kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: 1024] as CFDictionary)
  }
}
