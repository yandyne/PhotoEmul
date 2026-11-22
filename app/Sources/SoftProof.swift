import CoreGraphics
import Foundation

/// Settings › 색 관리 › 소프트 프루프 (off unless turned on): the canvas shows the photo as it
/// would come out in another colour space or on a printer (ICC file), optionally marking the
/// colours that fall outside it.
enum SoftProof {
  static let onKey = "softProof", targetKey = "softProofTarget", iccKey = "softProofICC"
  static let intentKey = "softProofIntent", gamutKey = "softProofGamut"
  static let keys = [onKey, targetKey, iccKey, intentKey, gamutKey]
  /// Grid points per axis of the lookup table.
  static let size = 33

  /// The proof colour space from the settings, nil while proofing is off.
  static var space: CGColorSpace? {
    let d = UserDefaults.standard
    guard d.bool(forKey: onKey) else { return nil }
    switch d.string(forKey: targetKey) {
    case "adobe": return CGColorSpace(name: CGColorSpace.adobeRGB1998)
    case "icc": return d.string(forKey: iccKey).flatMap(iccSpace)
    default: return CGColorSpace(name: CGColorSpace.sRGB)
    }
  }

  static func iccSpace(_ path: String) -> CGColorSpace? {
    (try? Data(contentsOf: URL(fileURLWithPath: path))).flatMap { CGColorSpace(iccData: $0 as CFData) }
  }

  /// Short name for the photo's corner tag.
  static var name: String {
    let d = UserDefaults.standard
    switch d.string(forKey: targetKey) {
    case "adobe": return "Adobe RGB"
    case "icc": return d.string(forKey: iccKey).map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? "sRGB"
    default: return "sRGB"
    }
  }

  static var intent: CGColorRenderingIntent {
    UserDefaults.standard.integer(forKey: intentKey) == 1 ? .relativeColorimetric : .perceptual
  }
  static var gamutWarning: Bool { UserDefaults.standard.bool(forKey: gamutKey) }

  /// RGBA 16-bit grid over Display P3 values: each colour after a trip through `space` and back,
  /// alpha full where the colour is outside `space` (judged colorimetrically, as Photoshop does).
  static func lut(_ space: CGColorSpace, intent: CGColorRenderingIntent) -> [UInt16] {
    let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
    let n = size, step = CGFloat(n - 1)
    func trip(_ c: [CGFloat], _ intent: CGColorRenderingIntent) -> [CGFloat] {
      CGColor(colorSpace: p3, components: c + [1])?.converted(to: space, intent: intent, options: nil)?
        .converted(to: p3, intent: .relativeColorimetric, options: nil)?.components ?? c
    }
    var out = [UInt16](repeating: 0, count: n * n * n * 4)
    for b in 0..<n { for g in 0..<n { for r in 0..<n {
      let c = [CGFloat(r) / step, CGFloat(g) / step, CGFloat(b) / step]
      let shown = trip(c, intent)
      let exact = intent == .relativeColorimetric ? shown : trip(c, .relativeColorimetric)
      let i = ((b * n + g) * n + r) * 4
      for k in 0..<3 { out[i + k] = UInt16((min(max(shown[k], 0), 1) * 65535).rounded()) }
      out[i + 3] = (0..<3).contains { abs(min(max(exact[$0], 0), 1) - c[$0]) > 0.02 } ? 65535 : 0
    }}}
    return out
  }
}
