// PhotoEmul - native editor for spektrafilm (GPL-3.0-or-later)
// Real lens profiles: distortion, lateral chromatic aberration (TCA) and vignetting
// from the lensfun database (https://lensfun.github.io, data CC BY-SA 3.0).
// The bundled LensProfiles.json is made by tools/lensfun_convert.py (our own parser; no lensfun code).
//
// Models (radius r as lensfun normalises it):
//   distortion  rd = ru * (c0 + c1 r + c2 r^2 + c3 r^3 + c4 r^4)   r = 1 at half the calibration frame height
//   TCA         rd = ru * (v + c r + b r^2)  per red / blue channel  same r as distortion
//   vignetting  observed = scene * (1 + k1 r^2 + k2 r^4 + k3 r^6)  r = 1 at the calibration frame corner

import Foundation

struct LensEntry: Decodable, Identifiable {
  let m: String          // maker
  let n: String          // model
  let mt: [String]       // mounts
  let c: Double          // calibration crop factor
  let f: [Double]        // focal range
  let a: Double          // widest aperture
  let d: [[Double]]      // [focal, c0..c4]
  let t: [[Double]]      // [focal, vr, cr, br, vb, cb, bb]
  let v: [[Double]]      // [focal, aperture, distance, k1, k2, k3]

  var id: Int { LensProfile.stableId(m, n) }
  var maker: String { m }
  var model: String { n }
  var isZoom: Bool { f.count == 2 && f[1] - f[0] > 0.5 }
  var displayName: String { n.lowercased().hasPrefix(m.lowercased()) ? n : "\(m) \(n)" }
}

private struct LensDB: Decodable { let lenses: [LensEntry] }

enum LensProfile {
  static let apertures: [Double] = [0, 1.0, 1.2, 1.4, 1.8, 2, 2.8, 4, 5.6, 8, 11, 16, 22]
  static let apertureLabels = ["Wide open", "f/1", "f/1.2", "f/1.4", "f/1.8", "f/2", "f/2.8", "f/4", "f/5.6", "f/8", "f/11", "f/16", "f/22"]
  static let distances: [Double] = [0.5, 1, 3, 10, 1000]
  static let distanceLabels = ["0.5 m", "1 m", "3 m", "10 m", "Infinity"]
  /// Long edge of each engine film format (filmFormat choice order), in mm.
  static let formatMm: [Double] = [4.8, 5.79, 10.26, 12.52, 35, 24.89, 52.48, 70.41]

  static let lenses: [LensEntry] = {
    guard let url = Bundle.main.url(forResource: "LensProfiles", withExtension: "json"),
          let data = try? Data(contentsOf: url),
          let db = try? JSONDecoder().decode(LensDB.self, from: data)
    else { return [] }
    return db.lenses
  }()
  private static let index: [Int: Int] = {
    var m: [Int: Int] = [:]
    for (i, e) in lenses.enumerated() where m[e.id] == nil { m[e.id] = i }
    return m
  }()

  static func lens(_ id: Int) -> LensEntry? { index[id].map { lenses[$0] } }

  /// FNV-1a over "maker|model", 31 bits: survives database updates and reordering.
  static func stableId(_ maker: String, _ model: String) -> Int {
    var h: UInt32 = 2166136261
    for b in "\(maker.lowercased())|\(model.lowercased())".utf8 { h = (h ^ UInt32(b)) &* 16777619 }
    return Int(h & 0x7fff_ffff) | 1
  }

  static func isActive(_ v: [String: ParamValue]) -> Bool {
    v["lensProfileEnabled"]?.boolValue == true && lens(v["lensProfileId"]?.intValue ?? 0) != nil
  }

  struct Coefficients {
    var dist: [Double] = [1, 0, 0, 0, 0]
    var tcaR: [Double] = [1, 0, 0]
    var tcaB: [Double] = [1, 0, 0]
    var vig: [Double] = [0, 0, 0]
    var crop: Double = 1
  }

  /// Linear interpolation over focal length between the two nearest calibrated rows.
  private static func byFocal(_ rows: [[Double]], _ focal: Double) -> [Double]? {
    guard !rows.isEmpty else { return nil }
    let s = rows.sorted { $0[0] < $1[0] }
    if focal <= s[0][0] { return Array(s[0].dropFirst()) }
    if focal >= s[s.count - 1][0] { return Array(s[s.count - 1].dropFirst()) }
    for i in 1..<s.count where focal <= s[i][0] {
      let a = s[i - 1], b = s[i]
      let t = b[0] > a[0] ? (focal - a[0]) / (b[0] - a[0]) : 0
      return (1..<a.count).map { a[$0] + (b[$0] - a[$0]) * t }
    }
    return Array(s[s.count - 1].dropFirst())
  }

  /// Inverse-distance weighting in (log focal, stops, 1/distance); an exact row wins outright.
  private static func vignetting(_ rows: [[Double]], focal: Double, aperture: Double, distance: Double) -> [Double]? {
    guard !rows.isEmpty else { return nil }
    let fl = log2(max(focal, 1)), st = 2 * log2(max(aperture, 0.5)), dd = 1 / max(distance, 0.1)
    var sum = [0.0, 0, 0], wsum = 0.0
    for r in rows {
      let df = (log2(max(r[0], 1)) - fl) * 3, da = 2 * log2(max(r[1], 0.5)) - st, dz = (1 / max(r[2], 0.1) - dd) * 0.5
      let d2 = df * df + da * da + dz * dz
      if d2 < 1e-10 { return Array(r[3...5]) }
      let w = 1 / (d2 * d2)
      for k in 0..<3 { sum[k] += r[3 + k] * w }
      wsum += w
    }
    return sum.map { $0 / wsum }
  }

  static func coefficients(_ v: [String: ParamValue]) -> Coefficients? {
    guard isActive(v), let e = lens(v["lensProfileId"]?.intValue ?? 0) else { return nil }
    let focal = clampedFocal(e, v["lensFocalMm"]?.doubleValue ?? 50)
    let ai = max(0, min(apertures.count - 1, v["lensAperture"]?.intValue ?? 0))
    let aperture = ai == 0 ? max(e.a, 0.7) : max(apertures[ai], e.a)
    let di = max(0, min(distances.count - 1, v["lensFocusDistance"]?.intValue ?? 3))
    let s = v["lensProfileStrength"]?.doubleValue ?? 1
    var c = Coefficients()
    c.crop = e.c
    if v["lensApplyDistortion"]?.boolValue ?? true, let d = byFocal(e.d, focal) {
      c.dist = [1 + (d[0] - 1) * s, d[1] * s, d[2] * s, d[3] * s, d[4] * s]
    }
    if v["lensApplyTca"]?.boolValue ?? true, let t = byFocal(e.t, focal) {
      c.tcaR = [1 + (t[0] - 1) * s, t[1] * s, t[2] * s]
      c.tcaB = [1 + (t[3] - 1) * s, t[4] * s, t[5] * s]
    }
    if v["lensApplyVignette"]?.boolValue ?? true,
       let k = vignetting(e.v, focal: focal, aperture: aperture, distance: distances[di]) {
      c.vig = k.map { $0 * s }
    }
    return c
  }

  static func clampedFocal(_ e: LensEntry, _ focal: Double) -> Double {
    guard e.f.count == 2 else { return focal }
    return min(max(focal, e.f[0]), e.f[1])
  }

  // MARK: Image geometry

  /// Distortion radius (r = 1 at half the calibration frame height) per output pixel.
  static func pxToDist(_ v: [String: ParamValue], crop: Double, longEdgePx: Int) -> Double {
    mmPerPx(v, crop, longEdgePx) / (12 / crop)
  }
  /// Vignetting radius (r = 1 at the calibration frame corner) per output pixel.
  static func pxToVig(_ v: [String: ParamValue], crop: Double, longEdgePx: Int) -> Double {
    mmPerPx(v, crop, longEdgePx) / (21.633 / crop)
  }
  /// Frames larger than the calibration frame (65 mm, IMAX with a 35 mm lens) are fitted to it:
  /// the polynomials are only valid inside the calibrated circle, so we treat it as a lens of the
  /// same character made for the bigger format instead of extrapolating into a black ring.
  private static func mmPerPx(_ v: [String: ParamValue], _ crop: Double, _ longEdgePx: Int) -> Double {
    let f = max(0, min(formatMm.count - 1, v["filmFormat"]?.intValue ?? 4))
    let mm = min(formatMm[f], 36 / max(crop, 0.1))
    return mm / Double(max(longEdgePx, 1))
  }

  /// Undistorted radius for a distorted radius (Newton on rd = ru * poly(ru)).
  static func undistort(_ c: [Double], _ rd: Double) -> Double {
    var x = rd
    for _ in 0..<6 {
      let p = c[0] + x * (c[1] + x * (c[2] + x * (c[3] + x * c[4])))
      let dp = c[0] + x * (2 * c[1] + x * (3 * c[2] + x * (4 * c[3] + x * 5 * c[4])))
      guard abs(dp) > 1e-6 else { break }
      x -= (x * p - rd) / dp
    }
    return x
  }

  /// Source scale so a barrel lens never pulls in pixels from outside the frame.
  static func fillScale(_ c: [Double], halfW: Double, halfH: Double, pxToDist: Double, clamp: Double) -> Double {
    var fill = 1.0
    for r in [halfW, halfH, (halfW * halfW + halfH * halfH).squareRoot()] where r > 0 {
      let rd = min(r * pxToDist, clamp)
      guard rd > 1e-6 else { continue }
      let ratio = undistort(c, rd) / rd
      if ratio.isFinite { fill = max(fill, ratio) }
    }
    return min(fill, 1.6)
  }

  /// Calibrated corner of the 3:2 calibration frame, plus a little margin.
  static let clampDist = 1.803 * 1.1
  static let clampVig = 1.1
}
