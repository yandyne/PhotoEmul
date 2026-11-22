// PhotoEmul - native editor for spektrafilm (GPL-3.0-or-later)
// Film damage drawn from statistics of real scanned damage.
//
// The per-type counts, sizes, shapes, angles and placement follow the annotated scans and the
// generator of FilmDamageSimulator (MIT, Copyright (c) 2022 Daniela Ivanova):
//   D. Ivanova, J. Williamson, P. Henderson, "Simulating Analogue Film Damage to Analyse and
//   Improve Artefact Restoration on High-resolution Scans", Eurographics 2023.
//   https://github.com/daniela997/FilmDamageSimulator
// The tables below were measured from its annotation files (35 mm frames, about 7 µm per pixel)
// and converted to µm; no code or images from it are bundled.
//
// Damage is laid out in millimetres on the film frame, so the proxy, the detail view and the
// saved file get the same specks; the GPU draws them from a coarse grid of item lists.

import Foundation

/// One drawable item, in pixels. Layout matches `DustItem` in Effects.metal (48 bytes).
struct DustItem {
  var a: SIMD2<Float> = .zero      // centre, or segment start
  var b: SIMD2<Float> = .zero      // semi-major axis vector, or segment end
  var r: Float = 0                 // minor/major ratio, half width, or radius
  var opacity: Float = 0
  var t0: Float = 0, t1: Float = 0 // position along a scratch (px), for its fading
  var kind: UInt32 = 0
  var seed: UInt32 = 0
  var aux: Float = 0
  var pad: Float = 0
}

enum DustKind: UInt32 {
  case speck = 0, fibre = 1, scratch = 2, dirt = 3, waterMark = 4, fingerprint = 5
}

struct DustLayout {
  var items: [DustItem] = []
  var cellStart: [UInt32] = [0]
  var cellItems: [UInt32] = []
  var cellPx: Float = 32
  var gridW: UInt32 = 1, gridH: UInt32 = 1
}

enum DustModel {
  struct Settings: Hashable {
    var amount: Double = 0.3
    var size: Double = 1
    var scratches: Double = 0.2
    var seed: Int = 1
    var dust = true, hair = true, scratch = true, stain = true, fingerprint = false
    var format = 0
    var edgeBias = 0.4

    init(_ v: [String: ParamValue]) {
      amount = v["dustAmount"]?.doubleValue ?? 0.3
      size = v["dustSize"]?.doubleValue ?? 1
      scratches = v["dustScratches"]?.doubleValue ?? 0.2
      seed = max(0, v["dustSeed"]?.intValue ?? 1)
      dust = v["dustTypeDust"]?.boolValue ?? true
      hair = v["dustTypeHair"]?.boolValue ?? true
      scratch = v["dustTypeScratch"]?.boolValue ?? true
      stain = v["dustTypeStain"]?.boolValue ?? true
      fingerprint = v["dustTypeFingerprint"]?.boolValue ?? false
      format = v["dustFormat"]?.intValue ?? 0
      edgeBias = v["dustEdgeBias"]?.doubleValue ?? 0.4
    }
  }

  /// Long side of the image area in mm: 35 mm, 120 (6×7), 4×5 sheet.
  static let formatLongMM: [Double] = [36, 70, 120]
  /// Area of the 35 mm reference frame the counts were measured on (mm²).
  static let referenceAreaMM2 = 36.0 * 24.0

  /// Gamma (shape k, scale θ) in µm, measured per damage class.
  struct Shape { var count: Double; var lenK, lenT, widK, widT: Double }
  static let dustShape = Shape(count: 763, lenK: 12.97, lenT: 5.86, widK: 26.8, widT: 1.055)
  static let dirtShape = Shape(count: 270, lenK: 5.26, lenT: 24.3, widK: 13.4, widT: 3.01)
  static let shortHair = Shape(count: 134, lenK: 3.29, lenT: 93.35, widK: 17.2, widT: 2.31)
  static let longHair = Shape(count: 40, lenK: 5.26, lenT: 169.8, widK: 18.6, widT: 2.33)
  static let scratchShape = Shape(count: 6.5, lenK: 1.217, lenT: 2348, widK: 5.3, widT: 10.5)

  // MARK: Generation (mm on the frame)

  private struct MMItem {
    var kind: DustKind
    var a: SIMD2<Double>, b: SIMD2<Double>
    var r: Double, opacity: Double
    var t0 = 0.0, t1 = 0.0, aux = 0.0
    var seed: UInt32
  }

  private struct Frame {
    var w: Double, h: Double    // mm
    var noise: [Double]         // 4×4 clumping lattice
    var edgeBias: Double
    var area: Double { w * h }
  }

  /// Items for one image of `width`×`height` px, binned for the GPU.
  static func layout(_ s: Settings, width: Int, height: Int) -> DustLayout {
    let longPx = Double(max(width, height))
    let longMM = formatLongMM[min(max(s.format, 0), formatLongMM.count - 1)]
    let mmPerPx = longMM / longPx
    let landscape = width >= height
    let frame = Frame(
      w: Double(width) * mmPerPx, h: Double(height) * mmPerPx,
      noise: (0..<16).map { i in var r = Rng(s.seed, 90, UInt64(i)); return r.uniform() }, edgeBias: s.edgeBias)
    let items = generate(s, frame, transportHorizontal: landscape)
    return bin(items, pxPerMM: 1 / mmPerPx, width: width, height: height)
  }

  private static func generate(_ s: Settings, _ f: Frame, transportHorizontal: Bool) -> [MMItem] {
    var out: [MMItem] = []
    let areaRatio = f.area / referenceAreaMM2
    // amount 1 = the (very dirty) reference film; squared so the low end stays usable.
    let level = s.amount * s.amount
    let sizeK = s.size
    let um = 0.001

    func count(_ mean: Double, _ stream: UInt64) -> Int {
      var r = Rng(s.seed, stream, 0)
      // frame-to-frame variation of the reference scans, then Poisson
      let spread = r.gamma(4, 0.25)
      return r.poisson(mean * spread)
    }

    // Dust specks and dirt blobs.
    func blobs(_ shape: Shape, _ kind: DustKind, _ stream: UInt64) {
      let n = count(shape.count * level * areaRatio, stream)
      for i in 0..<n {
        var r = Rng(s.seed, stream, UInt64(i) + 1)
        let p = position(&r, f)
        var len = r.gamma(shape.lenK, shape.lenT), wid = r.gamma(shape.widK, shape.widT)
        if wid > len { swap(&len, &wid) }
        let ang = r.uniform() * .pi
        let major = len * 0.5 * um * sizeK
        let axis = SIMD2(cos(ang), sin(ang)) * major
        let opacity = kind == .speck ? 0.8 + 0.2 * r.uniform() : 0.3 + 0.45 * r.uniform()
        out.append(MMItem(kind: kind, a: p, b: axis, r: max(0.25, wid / len), opacity: opacity, seed: r.u32()))
      }
    }

    // Hairs and fibres: a bent polyline split into capsules.
    func hairs(_ shape: Shape, _ stream: UInt64) {
      let n = count(shape.count * level * areaRatio, stream)
      for i in 0..<n {
        var r = Rng(s.seed, stream, UInt64(i) + 1)
        let p = position(&r, f)
        let len = r.gamma(shape.lenK, shape.lenT) * um * sizeK
        let halfW = r.gamma(shape.widK, shape.widT) * 0.5 * um * sizeK
        // total turning so the path / chord ratio matches the scans (median 1.25, p90 1.7)
        let turn = 2.1 * exp(0.33 * r.normal()) * (r.uniform() < 0.5 ? -1 : 1)
        let wiggle = turn * 0.3 * r.normal(), freq = 1 + 2 * r.uniform(), phase = r.uniform() * 2 * .pi
        let segs = max(4, min(40, Int(len / (40 * um))))
        let ds = len / Double(segs)
        var th = r.uniform() * 2 * .pi
        // start so the hair is centred on p
        var pts: [SIMD2<Double>] = [.zero]
        for k in 0..<segs {
          let t = (Double(k) + 0.5) / Double(segs)
          pts.append(pts.last! + SIMD2(cos(th), sin(th)) * ds)
          th += (turn + wiggle * sin(2 * .pi * freq * t + phase)) / Double(segs)
        }
        let mid = pts.reduce(SIMD2<Double>.zero, +) / Double(pts.count)
        let opacity = 0.75 + 0.25 * r.uniform()
        let seed = r.u32()
        for k in 0..<segs {
          out.append(MMItem(kind: .fibre, a: pts[k] - mid + p, b: pts[k + 1] - mid + p, r: halfW, opacity: opacity,
                            t0: Double(k) / Double(segs), t1: Double(k + 1) / Double(segs), seed: seed))
        }
      }
    }

    // Scratches: lines along the film transport, cut into pieces that keep one fading curve.
    func scratchLine(_ a: SIMD2<Double>, _ b: SIMD2<Double>, halfW: Double, opacity: Double, seed: UInt32) {
      let len = simd_len(b - a)
      let pieces = max(1, Int(len / 0.8))
      for k in 0..<pieces {
        let u0 = Double(k) / Double(pieces), u1 = Double(k + 1) / Double(pieces)
        out.append(MMItem(kind: .scratch, a: a + (b - a) * u0, b: a + (b - a) * u1, r: halfW, opacity: opacity,
                          t0: len * u0, t1: len * u1, seed: seed))
      }
    }

    if s.dust { blobs(dustShape, .speck, 1) }
    if s.stain { blobs(dirtShape, .dirt, 2) }
    if s.hair {
      hairs(shortHair, 3)
      hairs(longHair, 4)
    }
    if s.scratch, s.scratches > 0 {
      let sheet = s.format == 2
      let along: SIMD2<Double> = transportHorizontal ? SIMD2(1, 0) : SIMD2(0, 1)
      let k = s.scratches / 0.2 * 0.5  // default 0.2 → half the reference rate
      let n = count(scratchShape.count * k * areaRatio, 5)
      for i in 0..<n {
        var r = Rng(s.seed, 5, UInt64(i) + 1)
        let p = position(&r, f)
        let len = r.gamma(scratchShape.lenK, scratchShape.lenT) * um
        let halfW = r.gamma(scratchShape.widK, scratchShape.widT) * 0.25 * um * sizeK
        // 7 of 10 annotated scratches run within 30° of the transport direction
        let base = atan2(along.y, along.x)
        let ang = sheet || r.uniform() > 0.7 ? r.uniform() * .pi : base + 0.25 * r.normal()
        let d = SIMD2(cos(ang), sin(ang)) * len * 0.5
        scratchLine(p - d, p + d, halfW: halfW, opacity: 0.45 + 0.4 * r.uniform(), seed: r.u32())
      }
      // Half of the simulated frames also get a set of long thin lines in one direction (roll film only).
      var r = Rng(s.seed, 6, 0)
      if !sheet, r.uniform() < min(1, s.scratches * 2.5) {
        let lines = max(1, Int((r.gamma(6, 2) * min(1, s.scratches * 2.5) * 0.5).rounded()))
        let across = transportHorizontal ? f.h : f.w, alongLen = transportHorizontal ? f.w : f.h
        for i in 0..<lines {
          var q = Rng(s.seed, 6, UInt64(i) + 1)
          let c = q.uniform() * across
          let len = (0.2 + 0.8 * q.uniform()) * alongLen
          let start = q.uniform() * (alongLen - len)
          let a = transportHorizontal ? SIMD2(start, c) : SIMD2(c, start)
          let tilt = 0.004 * q.normal() * len
          let b = transportHorizontal ? SIMD2(start + len, c + tilt) : SIMD2(c + tilt, start + len)
          scratchLine(a, b, halfW: (4 + 5 * q.uniform()) * um * sizeK, opacity: 0.35 + 0.4 * q.uniform(), seed: q.u32())
        }
      }
    }
    if s.stain, s.amount > 0 {
      // drying marks: faint discs with a darker rim, a few mm across
      let n = count(1.2 * s.amount * areaRatio.squareRoot(), 7)
      for i in 0..<n {
        var r = Rng(s.seed, 7, UInt64(i) + 1)
        let p = position(&r, f)
        let radius = min(4, max(0.3, r.gamma(3, 0.4))) * sizeK
        out.append(MMItem(kind: .waterMark, a: p, b: .zero, r: radius, opacity: 0.18 + 0.2 * r.uniform(),
                          aux: 0.06 + 0.08 * r.uniform(), seed: r.u32()))
      }
    }
    if s.fingerprint, s.amount > 0 {
      // one print, held at the frame edge
      var r = Rng(s.seed, 8, 1)
      let side = Int(r.uniform() * 4)
      let t = 0.15 + 0.7 * r.uniform(), inset = 1 + 3 * r.uniform()
      let p: SIMD2<Double> = switch side {
      case 0: SIMD2(t * f.w, inset)
      case 1: SIMD2(t * f.w, f.h - inset)
      case 2: SIMD2(inset, t * f.h)
      default: SIMD2(f.w - inset, t * f.h)
      }
      let ang = r.uniform() * .pi
      let major = 7.5 * (0.85 + 0.3 * r.uniform())
      out.append(MMItem(kind: .fingerprint, a: p, b: SIMD2(cos(ang), sin(ang)) * major, r: 0.72,
                        opacity: 0.06 + 0.08 * s.amount, aux: 0.46, seed: r.u32()))
    }
    return out
  }

  /// Placement: low-frequency clumping (the generator's coarse Perlin density) and a pull
  /// toward the frame edges, where handling and the film gate leave more.
  private static func position(_ r: inout Rng, _ f: Frame) -> SIMD2<Double> {
    for _ in 0..<32 {
      let p = SIMD2(r.uniform() * f.w, r.uniform() * f.h)
      let u = p.x / f.w * 3, v = p.y / f.h * 3
      let ix = min(2, Int(u)), iy = min(2, Int(v))
      let fx = smooth(u - Double(ix)), fy = smooth(v - Double(iy))
      let n00 = f.noise[iy * 4 + ix], n10 = f.noise[iy * 4 + ix + 1]
      let n01 = f.noise[(iy + 1) * 4 + ix], n11 = f.noise[(iy + 1) * 4 + ix + 1]
      let clump = (n00 * (1 - fx) + n10 * fx) * (1 - fy) + (n01 * (1 - fx) + n11 * fx) * fy
      let d = min(min(p.x, f.w - p.x), min(p.y, f.h - p.y)) / (min(f.w, f.h) * 0.5)
      let edge = 0.25 + 2.25 * (1 - d) * (1 - d)
      let weight = (0.35 + 0.65 * clump) * (1 + f.edgeBias * (edge - 1))
      let maxWeight = 1 + f.edgeBias * 1.5
      if r.uniform() * maxWeight <= weight { return p }
    }
    return SIMD2(r.uniform() * f.w, r.uniform() * f.h)
  }

  private static func smooth(_ x: Double) -> Double { x * x * (3 - 2 * x) }

  // MARK: Pixels and binning

  private static func bin(_ mm: [MMItem], pxPerMM k: Double, width: Int, height: Int) -> DustLayout {
    var L = DustLayout()
    let cell: Double = 32
    L.cellPx = Float(cell)
    let gw = max(1, Int((Double(width) / cell).rounded(.up))), gh = max(1, Int((Double(height) / cell).rounded(.up)))
    L.gridW = UInt32(gw)
    L.gridH = UInt32(gh)
    var lists = [[UInt32]](repeating: [], count: gw * gh)
    for m in mm {
      var it = DustItem()
      it.kind = m.kind.rawValue
      it.seed = m.seed
      it.opacity = Float(m.opacity)
      it.a = SIMD2(Float(m.a.x * k), Float(m.a.y * k))
      var lo: SIMD2<Double>, hi: SIMD2<Double>
      switch m.kind {
      case .speck, .dirt, .fingerprint:
        it.b = SIMD2(Float(m.b.x * k), Float(m.b.y * k))
        it.r = Float(m.r)
        it.aux = Float(m.aux * k)
        let ext = simd_len(m.b) * k * 1.4 + 2
        lo = m.a * k - ext
        hi = m.a * k + ext
      case .fibre, .scratch:
        it.b = SIMD2(Float(m.b.x * k), Float(m.b.y * k))
        it.r = Float(m.r * k)
        it.t0 = Float(m.kind == .scratch ? m.t0 * k : m.t0)
        it.t1 = Float(m.kind == .scratch ? m.t1 * k : m.t1)
        let ext = m.r * k + 2
        lo = SIMD2(min(m.a.x, m.b.x), min(m.a.y, m.b.y)) * k - ext
        hi = SIMD2(max(m.a.x, m.b.x), max(m.a.y, m.b.y)) * k + ext
      case .waterMark:
        it.r = Float(m.r * k)
        it.aux = Float(m.aux)
        let ext = m.r * k * 1.3 + 2
        lo = m.a * k - ext
        hi = m.a * k + ext
      }
      let x0 = max(0, Int(lo.x / cell)), y0 = max(0, Int(lo.y / cell))
      let x1 = min(gw - 1, Int(hi.x / cell)), y1 = min(gh - 1, Int(hi.y / cell))
      guard x0 <= x1, y0 <= y1 else { continue }
      let index = UInt32(L.items.count)
      L.items.append(it)
      for y in y0...y1 { for x in x0...x1 { lists[y * gw + x].append(index) } }
    }
    L.cellStart.reserveCapacity(gw * gh + 1)
    for list in lists {
      L.cellItems.append(contentsOf: list)
      L.cellStart.append(UInt32(L.cellItems.count))
    }
    return L
  }
}

private func simd_len(_ v: SIMD2<Double>) -> Double { (v * v).sum().squareRoot() }

/// Small deterministic generator: one stream per (seed, damage type, item).
struct Rng {
  private var state: UInt64

  init(_ seed: Int, _ stream: UInt64, _ index: UInt64) {
    state = UInt64(truncatingIfNeeded: seed) &* 0x9E37_79B9_7F4A_7C15 ^ stream &* 0xD1B5_4A32_D192_ED03 ^ index &* 0x94D0_49BB_1331_11EB
    _ = next()
  }

  mutating func next() -> UInt64 {
    state &+= 0x9E37_79B9_7F4A_7C15
    var z = state
    z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
    z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
    return z ^ (z >> 31)
  }

  mutating func u32() -> UInt32 { UInt32(truncatingIfNeeded: next() >> 32) }
  mutating func uniform() -> Double { Double(next() >> 11) / Double(1 << 53) }

  mutating func normal() -> Double {
    let u = max(uniform(), 1e-12), v = uniform()
    return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
  }

  /// Marsaglia–Tsang; shape below 1 by the usual boost.
  mutating func gamma(_ k: Double, _ theta: Double) -> Double {
    if k < 1 { return gamma(k + 1, theta) * pow(max(uniform(), 1e-12), 1 / k) }
    let d = k - 1.0 / 3, c = 1 / (9 * d).squareRoot()
    while true {
      var x: Double, v: Double
      repeat { x = normal(); v = 1 + c * x } while v <= 0
      v = v * v * v
      let u = uniform()
      if u < 1 - 0.0331 * x * x * x * x || log(max(u, 1e-300)) < 0.5 * x * x + d * (1 - v + log(v)) { return d * v * theta }
    }
  }

  mutating func poisson(_ mean: Double) -> Int {
    guard mean > 0 else { return 0 }
    if mean > 40 { return max(0, Int((mean + mean.squareRoot() * normal()).rounded())) }
    let l = exp(-mean)
    var k = 0, p = 1.0
    repeat { k += 1; p *= uniform() } while p > l
    return k - 1
  }
}
