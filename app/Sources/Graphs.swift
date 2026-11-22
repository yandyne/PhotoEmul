// PhotoEmul - native editor for spektrafilm (GPL-3.0-or-later)
// Small explanatory graphs in the module stack: paper grade curve, developer edge profile,
// lens vignetting falloff, scene light spectrum. Each is computed in the view (60 points at
// most). When its module does not apply, the graph stays in place, dimmed, with a typical curve
// and the reason, so the feature is visible before it is in use.

import SwiftUI

/// One curve: points in data units, drawn solid in the accent colour, dashed in grey, or dotted
/// and fainter for a second reference.
struct GraphCurve {
  var points: [CGPoint]
  var highlighted = false
  var faint = false
}

/// A short label inside the graph. `anchor` is the side of the text that sits on the point
/// (.trailing: the text ends at the point).
struct GraphLabel {
  var text: String
  var at: CGPoint
  var anchor: Alignment = .center
  var offset: CGSize = .zero
  var highlighted = false
}

struct MiniGraph: View {
  let curves: [GraphCurve]
  let x: ClosedRange<Double>
  let y: ClosedRange<Double>
  var labels: [GraphLabel] = []
  var caption: String?
  /// Dims the graph and marks the caption as the reason it does not apply.
  var inactive = false
  var height: CGFloat = 64

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      GeometryReader { geo in
        let w = geo.size.width, h = geo.size.height
        let map = { (p: CGPoint) -> CGPoint in
          let px = (p.x - x.lowerBound) / (x.upperBound - x.lowerBound)
          let py = (min(max(p.y, y.lowerBound), y.upperBound) - y.lowerBound) / (y.upperBound - y.lowerBound)
          return CGPoint(x: px * w, y: h - py * h)
        }
        ZStack {
          RoundedRectangle(cornerRadius: 4).strokeBorder(Color.secondary.opacity(0.25))
          Group {
            ForEach(Array(curves.enumerated()), id: \.offset) { _, c in
              Path { path in
                guard let first = c.points.first else { return }
                path.move(to: map(first))
                for p in c.points.dropFirst() { path.addLine(to: map(p)) }
              }
              .stroke(c.highlighted ? Color.accentColor : Color.secondary.opacity(c.faint ? 0.45 : 0.7),
                      style: StrokeStyle(lineWidth: c.highlighted ? 1.6 : 1, lineCap: .round, lineJoin: .round,
                                         dash: c.highlighted ? [] : c.faint ? [1, 2.5] : [3, 2]))
            }
            ForEach(Array(labels.enumerated()), id: \.offset) { _, l in
              Text(l.text)
                .font(.system(size: 9))
                .foregroundStyle(l.highlighted ? Color.accentColor : Color.secondary)
                .padding(.horizontal, 2)
                .background(Color(nsColor: .windowBackgroundColor).opacity(0.75), in: RoundedRectangle(cornerRadius: 2))
                .fixedSize()
                .frame(width: 0, height: 0, alignment: l.anchor)
                .position(map(l.at))
                .offset(l.offset)
            }
          }
          .opacity(inactive ? 0.4 : 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
      }
      .frame(height: height)
      if let caption {
        HStack(alignment: .firstTextBaseline, spacing: 3) {
          if inactive { Image(systemName: "info.circle") }
          Text(caption).lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .font(.caption2).foregroundStyle(.secondary)
      }
    }
  }
}

private func sample(_ range: ClosedRange<Double>, count: Int = 48, _ f: (Double) -> Double) -> [CGPoint] {
  (0..<count).map { i in
    let x = range.lowerBound + (range.upperBound - range.lowerBound) * Double(i) / Double(count - 1)
    return CGPoint(x: x, y: f(x))
  }
}

// MARK: Paper grade

/// Characteristic curve of the chosen grade between grade 00 and grade 5 (black-and-white
/// variable-contrast paper only). Split grade shows the two exposures added together.
struct GradeCurveGraph: View {
  let values: [String: ParamValue]
  private static let dmax = 2.1, x0 = -0.5

  /// Exposure through one filter as odds of blackening, so two exposures can be added.
  private static func odds(_ x: Double, gamma: Double, offset: Double = 0) -> Double {
    pow(10, 2 * gamma * (x + offset - x0))
  }
  private static func density(_ odds: Double) -> Double { dmax * odds / (1 + odds) }

  /// The selected curve (summed under split grade) and its caption.
  private func selected(_ range: ClosedRange<Double>, soft: Double, hard: Double) -> ([CGPoint], String) {
    if values["printSplitGrade"]?.boolValue == true {
      func offset(_ name: String) -> Double {
        let t = values[name]?.doubleValue ?? 5
        return t > 0.01 ? log10(t / Darkroom.referenceSeconds) : -30
      }
      let os = offset("printSoftSeconds"), oh = offset("printHardSeconds")
      return (sample(range) { Self.density(Self.odds($0, gamma: soft, offset: os) + Self.odds($0, gamma: hard, offset: oh)) },
              tr("분할 등급: 00 + 5 노출 합", "Split grade: 00 + 5 exposures added"))
    }
    let grade = min(max(values["paperGradeHalf"]?.intValue ?? Darkroom.defaultGrade, 0), Darkroom.gradeLabels.count - 1)
    let g = Darkroom.gamma(grade: grade), label = Darkroom.gradeLabels[grade]
    return (sample(range) { Self.density(Self.odds($0, gamma: g)) },
            tr("등급 \(label) · 점선 00 / 5", "Grade \(label) · dashed 00 / 5"))
  }

  /// Why grades do not apply right now.
  private var reason: String {
    Darkroom.isPrinting(values)
      ? tr("흑백 다계조 인화지에서만 · 지금은 컬러 인화지", "Black-and-white multigrade paper only · now colour paper")
      : tr("흑백 다계조 인화지에서만 · 지금은 인화하지 않음", "Black-and-white multigrade paper only · not printing now")
  }

  var body: some View {
    let range = -1.5...0.5
    let soft = Darkroom.gamma(grade: 0), hard = Darkroom.gamma(grade: Darkroom.isoR.count - 1)
    let active = Darkroom.onGradedPaper(values)
    let (curve, caption) = active
      ? selected(range, soft: soft, hard: hard)
      : (sample(range) { Self.density(Self.odds($0, gamma: Darkroom.gamma(grade: Darkroom.defaultGrade))) }, reason)
    MiniGraph(curves: [
      GraphCurve(points: sample(range) { Self.density(Self.odds($0, gamma: soft)) }),
      GraphCurve(points: sample(range) { Self.density(Self.odds($0, gamma: hard)) }),
      GraphCurve(points: curve, highlighted: true),
    ], x: range, y: 0...2.2,
    labels: [
      GraphLabel(text: tr("반사 농도", "Density"), at: CGPoint(x: range.lowerBound, y: 2.2), anchor: .topLeading,
                 offset: CGSize(width: 4, height: 3)),
      GraphLabel(text: tr("log 노출 →", "log exposure →"), at: CGPoint(x: range.upperBound, y: 0), anchor: .bottomTrailing,
                 offset: CGSize(width: -4, height: -3)),
    ],
    caption: caption, inactive: !active)
  }
}

// MARK: Edge effect

/// Density across a step edge: the exposure (dashed) and the developed result (solid) with
/// the Eberhard dip on the thin side and the fringe on the dense side. Black-and-white film draws
/// the developer's effect, colour film its DIR couplers'.
struct EdgeProfileGraph: View {
  let values: [String: ParamValue]

  var body: some View {
    let (edge, reason) = Adjacency.edge(values)
    // Not in use: a typical colour-negative edge (couplers at their default strength).
    let gain = edge?.gain ?? 0.3, um = max(edge?.um ?? 30, 5)
    let span = max(um * 3, 60), lo = 0.4, hi = 1.4
    let amp = min(gain, 0.8) * 0.75 * (hi - lo)
    let step = { (x: Double) -> Double in x < 0 ? lo : hi }
    let developed = { (x: Double) -> Double in
      let u = x / um
      return step(x) + amp * u * exp(0.5 - 0.5 * u * u)
    }
    let width = "±\(Int(span.rounded())) µm"
    let caption: String = {
      switch edge?.source {
      case .developer?: return tr("현상액 가장자리 효과 · 폭 \(width)", "Developer edge effect · \(width)")
      case .couplers?: return tr("필름 DIR 커플러 가장자리 효과 · 폭 \(width)", "Film DIR coupler edge effect · \(width)")
      case .standIn?: return tr("인접 효과 (DIR 커플러 대신) · 폭 \(width)", "Adjacency (standing in for DIR) · \(width)")
      case nil: return reason
      }
    }()
    MiniGraph(curves: [
      GraphCurve(points: sample(-span...span, count: 59, step)),
      GraphCurve(points: sample(-span...span, count: 59, developed), highlighted: true),
    ], x: -span...span, y: 0...2,
    labels: [
      // Level names outside the two levels, the swings named between them, so nothing runs off.
      GraphLabel(text: tr("그림자", "Shadow"), at: CGPoint(x: -span, y: lo), anchor: .topLeading,
                 offset: CGSize(width: 4, height: 3)),
      GraphLabel(text: tr("하이라이트", "Highlight"), at: CGPoint(x: span, y: hi), anchor: .bottomTrailing,
                 offset: CGSize(width: -4, height: -3)),
      GraphLabel(text: tr("언더슈트", "Undershoot"), at: CGPoint(x: -um, y: lo), anchor: .bottom,
                 offset: CGSize(width: 0, height: -3), highlighted: true),
      GraphLabel(text: tr("오버슈트", "Overshoot"), at: CGPoint(x: um, y: hi), anchor: .top,
                 offset: CGSize(width: 0, height: 3), highlighted: true),
      GraphLabel(text: "D", at: CGPoint(x: -span, y: 2), anchor: .topLeading, offset: CGSize(width: 4, height: 3)),
    ],
    caption: caption, inactive: edge == nil, height: 72)
  }
}

// MARK: Vignetting

/// Light falloff from the centre (r = 0) to the corner (r = 1) at f/2, f/4 and f/8, or two stops
/// apart from wide open when the lens is slower than f/2; the aperture in use is solid.
struct VignetteProfileGraph: View {
  let values: [String: ParamValue]

  private func curve(_ apertureIndex: Int) -> [CGPoint]? {
    var v = values
    v["lensAperture"] = .int(apertureIndex)
    guard let k = LensProfile.coefficients(v)?.vig, k.contains(where: { $0 != 0 }) else { return nil }
    return Self.falloff(k)
  }

  private static func falloff(_ k: [Double]) -> [CGPoint] {
    sample(0...1, count: 40) { r in
      let r2 = r * r
      return 1 + k[0] * r2 + k[1] * r2 * r2 + k[2] * r2 * r2 * r2
    }
  }

  /// Index in LensProfile.apertures nearest to an f-number.
  private func nearest(_ f: Double) -> Int {
    (1..<LensProfile.apertures.count).min { abs(log2(LensProfile.apertures[$0] / f)) < abs(log2(LensProfile.apertures[$1] / f)) } ?? 1
  }

  private static let axisLabels = [
    GraphLabel(text: tr("중심", "Centre"), at: CGPoint(x: 0, y: 0), anchor: .bottomLeading, offset: CGSize(width: 4, height: -3)),
    GraphLabel(text: tr("모서리", "Corner"), at: CGPoint(x: 1, y: 0), anchor: .bottomTrailing, offset: CGSize(width: -4, height: -3)),
  ]

  /// The measured curves, or nil with the reason there are none.
  private var measured: (curves: [GraphCurve], caption: String)? {
    guard LensProfile.isActive(values), values["lensApplyVignette"]?.boolValue ?? true,
          let lens = LensProfile.lens(values["lensProfileId"]?.intValue ?? 0), !lens.v.isEmpty else { return nil }
    let wide = max(lens.a, 2)
    let stops = [wide, wide * 2, wide * 4].map(nearest)
    let current = values["lensAperture"]?.intValue ?? 0
    let shown = stops.compactMap { curve($0).map { GraphCurve(points: $0) } }
    guard !shown.isEmpty, let now = curve(current) else { return nil }
    return (shown + [GraphCurve(points: now, highlighted: true)],
            tr("주변부 감광 · 점선 ", "Vignetting · dashed ")
              + stops.map { LensProfile.apertureLabels[$0] }.joined(separator: " / ")
              + " · " + LensProfile.apertureLabels[min(max(current, 0), LensProfile.apertureLabels.count - 1)])
  }

  private var reason: String {
    guard LensProfile.isActive(values) else {
      return tr("렌즈 프로파일을 고르면 그 렌즈의 측정값이 나타납니다", "Pick a lens profile to see its measured falloff")
    }
    guard values["lensApplyVignette"]?.boolValue ?? true else {
      return tr("프로파일 비네팅 적용이 꺼져 있음", "Profile vignetting is off")
    }
    return tr("이 렌즈는 이 조리개의 비네팅 측정값이 없음", "No vignetting data for this lens at this aperture")
  }

  var body: some View {
    if let m = measured {
      MiniGraph(curves: m.curves, x: 0...1, y: 0...1.05, labels: Self.axisLabels, caption: m.caption)
    } else {
      // A typical fast normal lens at f/2, f/4 and f/8.
      MiniGraph(curves: [
        GraphCurve(points: Self.falloff([-0.9, 0.3, 0])),
        GraphCurve(points: Self.falloff([-0.15, 0, 0])),
        GraphCurve(points: Self.falloff([-0.45, 0.1, 0]), highlighted: true),
      ], x: 0...1, y: 0...1.05, labels: Self.axisLabels, caption: reason, inactive: true)
    }
  }
}

// MARK: Scene light

/// Spectrum of the scene light (solid) against the light the film is balanced for (dashed) and the
/// other film balance (dotted), all 1 at 560 nm, each named at its right end.
struct IlluminantSpdGraph: View {
  let values: [String: ParamValue]
  private static let range = 400.0...695.0

  private static func name(_ kind: Int) -> String {
    Labels.option(Catalog.byName["sceneIlluminant"]?.options[safe: kind] ?? "")
  }

  var body: some View {
    let kind = values["sceneIlluminant"]?.intValue ?? 0
    let film = Catalog.films[safe: values["film"]?.intValue ?? -1]
    let kelvin = film.map(Illuminants.balanceKelvin(film:)) ?? 5500
    let other = kelvin < 4000 ? 5500.0 : 3200.0
    let active = kind > 0 && film != nil
    // 1 at 560 nm, unless a line source (mercury) would run its peaks far off the top.
    let raw = sample(Self.range, count: 240) { Illuminants.spectrum(kind, $0) }  // fine enough for 3 nm lines
    let norm = max(Illuminants.spectrum(kind, 560), (raw.map(\.y).max() ?? 1) / 7, 1e-6)
    let light = raw.map { CGPoint(x: $0.x, y: $0.y / norm) }
    let balance = sample(Self.range, count: 60) { Illuminants.planck($0, kelvin: kelvin) }
    let second = sample(Self.range, count: 60) { Illuminants.planck($0, kelvin: other) }
    let shown = active ? light + balance + second : balance + second
    let top = min(max(shown.map(\.y).max() ?? 1, 1.2) * 1.05, 8)

    // The scene light already is the other reference (daylight 5500K, tungsten 3200K): drawn once.
    let repeats = active && ((kind == 1 && other == 5500) || (kind == 4 && other == 3200))
    var curves = [GraphCurve(points: balance)]
    var ends: [(String, Double, Bool)] = [(tr("필름 기준 \(Int(kelvin))K", "Film \(Int(kelvin))K"), balance.last!.y, false)]
    if !repeats {
      curves.insert(GraphCurve(points: second, faint: true), at: 0)
      ends.append(((other < 4000 ? tr("텅스텐", "Tungsten") : tr("일광", "Daylight")) + " \(Int(other))K", second.last!.y, false))
    }
    if active {
      curves.append(GraphCurve(points: light, highlighted: true))
      ends.append((Self.name(kind), light.last!.y, true))
    }
    // Name each curve at its right end, pushed apart so the names do not overlap: down from the
    // top first, then back up from the bottom.
    let gap = top * 0.17, sorted = ends.sorted { $0.1 > $1.1 }
    var at: [Double] = []
    for (_, y, _) in sorted { at.append(min(y, (at.last ?? top * 0.93 + gap) - gap)) }
    for i in at.indices.reversed() { at[i] = max(at[i], i == at.count - 1 ? top * 0.1 : at[i + 1] + gap) }
    let placed = zip(sorted, at).map { e, y in
      GraphLabel(text: e.0, at: CGPoint(x: Self.range.upperBound, y: y), anchor: .trailing,
                 offset: CGSize(width: -4, height: 0), highlighted: e.2)
    }

    return MiniGraph(curves: curves, x: Self.range, y: 0...top, labels: placed,
                     caption: active
                       ? tr("400–700 nm · 1 = 560 nm", "400–700 nm · 1 = 560 nm")
                       : tr("필름 기준광 · 다른 광원을 고르면 그 차이가 보입니다", "Film balance · pick another light to see the difference"),
                     inactive: !active, height: 72)
  }
}
