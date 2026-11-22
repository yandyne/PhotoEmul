// PhotoEmul - native editor for spektrafilm (GPL-3.0-or-later)
// Thin Swift wrapper around the SpektraAppBridge C API.

import CSpektra
import Foundation

/// Interleaved RGBA pixels, 16-bit half or 32-bit float per component.
final class PixelBuffer: @unchecked Sendable {
  let width: Int
  let height: Int
  let bytesPerComponent: Int
  let data: UnsafeMutableRawPointer
  /// Rounded up to whole pages so Metal can wrap the memory without copying.
  let allocatedBytes: Int

  init(width: Int, height: Int, bytesPerComponent: Int = 4) {
    self.width = width
    self.height = height
    self.bytesPerComponent = bytesPerComponent
    let page = Int(getpagesize())
    allocatedBytes = max(page, (width * height * 4 * bytesPerComponent + page - 1) / page * page)
    data = UnsafeMutableRawPointer.allocate(byteCount: allocatedBytes, alignment: page)
    data.initializeMemory(as: UInt8.self, repeating: 0, count: allocatedBytes)
  }

  deinit { data.deallocate() }

  var rowBytes: Int { width * 4 * bytesPerComponent }
  var floats: UnsafeMutablePointer<Float> { data.assumingMemoryBound(to: Float.self) }

  var bridgeView: SpektraImageBuffer {
    SpektraImageBuffer(
      data: data, width: Int32(width), height: Int32(height), rowBytes: Int32(rowBytes),
      components: 4, bytesPerComponent: Int32(bytesPerComponent))
  }

  /// Copy of `rect` (pixels, y down), or nil when it falls outside.
  func cropped(to rect: CGRect) -> PixelBuffer? {
    let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: width, height: height))
    guard !r.isEmpty else { return nil }
    let out = PixelBuffer(width: Int(r.width), height: Int(r.height), bytesPerComponent: bytesPerComponent)
    let px = 4 * bytesPerComponent
    for y in 0..<out.height {
      memcpy(out.data + y * out.rowBytes, data + (Int(r.minY) + y) * rowBytes + Int(r.minX) * px, out.rowBytes)
    }
    return out
  }
}

enum ColorSpaceIndex {
  static let linearRec2020: Int32 = 14
  static let displayP3: Int32 = 18
  static let proPhoto: Int32 = 19
}

/// One renderer instance. Not thread safe: use it from a single serial queue.
final class SpektraEngine: @unchecked Sendable {
  private let ref: SpektraRendererRef?

  /// Picks the GPU duty cycle from the performance setting before each render.
  var role: Performance.Role = .preview

  init() { ref = SpektraRendererCreate() }
  deinit { SpektraRendererDestroy(ref) }

  var isAvailable: Bool { ref != nil && SpektraRendererIsAvailable(ref) != 0 }

  var lastError: String {
    guard let c = SpektraRendererLastError(ref) else { return "" }
    return String(cString: c)
  }

  var diagnostics: SpektraAppDiagnostics { SpektraRendererLastDiagnostics(ref) }

  func render(_ source: PixelBuffer, into destination: PixelBuffer, params: SpektraAppRenderParams) -> Bool {
    var src = source.bridgeView
    var dst = destination.bridgeView
    var p = params
    SpektraRendererSetGpuDutyCycle(ref, Performance.gpuDuty(for: role))
    return SpektraRendererRender(ref, &src, &dst, &p, 0) != 0
  }

  /// Renders the part of the full-frame result whose top-left is (`x`, `y`) into `destination`,
  /// which sets the region size. Pixels match the same crop of a full render.
  func render(_ source: PixelBuffer, into destination: PixelBuffer, x: Int, y: Int, params: SpektraAppRenderParams) -> Bool {
    var src = source.bridgeView
    var dst = destination.bridgeView
    var p = params
    SpektraRendererSetGpuDutyCycle(ref, Performance.gpuDuty(for: role))
    return SpektraRendererRenderRegion(ref, &src, &dst, Int32(x), Int32(y), &p, 0) != 0
  }

  /// Caps the GPU scratch memory; 0 picks a budget from the machine's RAM.
  func setMemoryBudget(_ bytes: UInt64) { SpektraRendererSetMemoryBudget(ref, bytes) }

  /// Stops the render running on the engine's queue early (it returns false); callable from any thread.
  func cancel() { SpektraRendererCancel(ref) }

  /// Frees cached scratch buffers until the next render.
  func releaseMemory() { SpektraRendererReleaseMemory(ref) }
}

// MARK: - Descriptor tables

enum ParamKind: Int32 {
  case int = 0, bool, double, double2, double3, choice, filmStock, printPaper
}

struct ParamDescriptor: Identifiable, Hashable {
  let name: String
  let label: String
  let group: String
  let optionSet: String?
  let kind: ParamKind
  let tier: Int32
  let defaultInt: Int32
  let defaultValue: [Double]
  let minimum: Double
  let maximum: Double
  /// Choice labels for app-side parameters, which have no bridge option set.
  var fixedOptions: [String] = []

  var id: String { name }

  var options: [String] {
    if !fixedOptions.isEmpty { return fixedOptions }
    guard let set = optionSet else { return [] }
    return (0..<SpektraAppOptionCount(set)).map { String(cString: SpektraAppOptionLabel(set, $0)) }
  }

  var defaultParamValue: ParamValue {
    switch kind {
    case .bool: return .bool(defaultInt != 0)
    case .int, .choice, .filmStock, .printPaper: return .int(Int(defaultInt))
    case .double: return .double(defaultValue[0])
    case .double2: return .vector([defaultValue[0], defaultValue[1]])
    case .double3: return .vector(defaultValue)
    }
  }
}

enum ParamValue: Codable, Hashable {
  case bool(Bool)
  case int(Int)
  case double(Double)
  case vector([Double])

  var boolValue: Bool { if case .bool(let b) = self { return b }; return false }
  var intValue: Int { if case .int(let i) = self { return i }; return 0 }
  var doubleValue: Double { if case .double(let d) = self { return d }; return 0 }
  var vectorValue: [Double] { if case .vector(let v) = self { return v }; return [0, 0, 0] }
}

enum Catalog {
  /// Engine descriptors followed by the app-side effect parameters.
  static let params: [ParamDescriptor] = engineParams + AppParams.all

  static let engineParams: [ParamDescriptor] = (0..<SpektraAppParamCount()).compactMap { i in
    guard let d = SpektraAppParamAt(i)?.pointee, let kind = ParamKind(rawValue: d.kind) else { return nil }
    return ParamDescriptor(
      name: String(cString: d.name), label: String(cString: d.label), group: String(cString: d.group),
      optionSet: d.optionSet.map { String(cString: $0) }, kind: kind, tier: d.visibilityTier,
      defaultInt: d.defaultInt,
      defaultValue: [d.defaultValue.0, d.defaultValue.1, d.defaultValue.2],
      minimum: d.minimum, maximum: d.maximum)
  }

  static let byName: [String: ParamDescriptor] = Dictionary(uniqueKeysWithValues: params.map { ($0.name, $0) })

  static let films: [String] = (0..<SpektraAppFilmCount()).map { String(cString: SpektraAppFilmName($0)) }
  static let papers: [String] = (0..<SpektraAppPaperCount()).map { String(cString: SpektraAppPaperName($0)) }

  /// Builds bridge params from the editor's value store. Names the bridge
  /// does not know (the RAW group) are ignored.
  static let positiveDirGammas: [(String, [Double])] = [
    ("dirGammaSameLayerRgb", [0.12, 0.08, 0.06]), ("dirGammaRToGb", [0.12, 0.06]),
    ("dirGammaGToRb", [0.08, 0.06]), ("dirGammaBToRg", [0.06, 0.06]),
  ]

  static func renderParams(_ values: [String: ParamValue], output: Int32) -> SpektraAppRenderParams {
    var p = SpektraAppMakeDefaultRenderParams()
    for (name, value) in values where !AppParams.names.contains(name) {
      switch value {
      case .bool(let b): SpektraAppSetBoolParam(&p, name, b ? 1 : 0)
      case .int(let i): SpektraAppSetIntParam(&p, name, Int32(i))
      case .double(let d): SpektraAppSetDoubleParam(&p, name, d)
      case .vector(let v): SpektraAppSetDouble3Param(&p, name, v[0], v.count > 1 ? v[1] : 0, v.count > 2 ? v[2] : 0)
      }
    }
    // Academy printer density timing needs SMPTE ST 2065-2 tables that are not shipped (all zeros,
    // blank print), so sessions saved with it render through the filtered enlarger instead.
    SpektraAppSetIntParam(&p, "printTiming", 0)
    // Stocks rated away from their base profile's speed (CineStill 800T is Vision3 500T shot at
    // EI 800) get the difference as less film exposure, on top of the user's own EV.
    if let film = films[safe: values["film"]?.intValue ?? -1], let ei = FilmInfo.exposureIndex[film] {
      SpektraAppSetDoubleParam(&p, "filmExposureEv", (values["filmExposureEv"]?.doubleValue ?? 0) + log2(ei.base / ei.rated))
    }
    // Slide and instant film are positives: printing them onto negative paper inverts them, so view
    // the scan, and use the reference's positive-stock DIR gammas unless the user changed them.
    if let film = films[safe: values["film"]?.intValue ?? -1], FilmInfo.isPositive(film) {
      SpektraAppSetIntParam(&p, "process", Int32(ProcessScope.mode(values)))
      for (name, v) in positiveDirGammas where values[name] == nil || values[name] == byName[name]?.defaultParamValue {
        SpektraAppSetDouble3Param(&p, name, v[0], v[1], v.count > 2 ? v[2] : 0)
      }
    }
    // Black-and-white stocks have no dye couplers and colourless grain.
    if let film = films[safe: values["film"]?.intValue ?? -1], FilmInfo.category(film) == .bw {
      for name in ["dirCouplersAmount", "grainSaturation"] where values[name] == nil || values[name] == byName[name]?.defaultParamValue {
        SpektraAppSetDoubleParam(&p, name, 0)
      }
    }
    if let film = films[safe: values["film"]?.intValue ?? -1], ProcessScope.usesFilm(values) {
      Development.apply(values, film: film, to: &p)
      Adjacency.apply(values, film: film, to: &p)
      Uneven.apply(values, to: &p)
    }
    applyGrainGain(values, to: &p)
    Darkroom.apply(values, to: &p)
    p.inputColorSpace = ColorSpaceIndex.linearRec2020
    p.outputColorSpace = output
    p.outputRole = 0
    return p
  }
}

extension Catalog {
  /// Black-and-white grain: the developer sets its size and amount, the enlarger light how much of
  /// it the print shows (Callier). One write so neither overrides the other.
  static func applyGrainGain(_ values: [String: ParamValue], to p: inout SpektraAppRenderParams) {
    guard let film = films[safe: values["film"]?.intValue ?? -1], FilmInfo.category(film) == .bw,
          values["grainEnabled"]?.boolValue ?? byName["grainEnabled"]?.defaultParamValue.boolValue ?? false
    else { return }
    let dev = ProcessScope.usesFilm(values) ? Developer.character(values, film: film) : Developer.Character()
    let gain = dev.grainAmount * Darkroom.grainVisibility(values)
    if gain != 1, let amount = values["grainAmount"]?.doubleValue ?? byName["grainAmount"]?.defaultParamValue.doubleValue {
      SpektraAppSetDoubleParam(&p, "grainAmount", amount * gain)
    }
    if dev.grainSize != 1,
       let area = values["grainParticleAreaUm2"]?.doubleValue ?? byName["grainParticleAreaUm2"]?.defaultParamValue.doubleValue {
      SpektraAppSetDoubleParam(&p, "grainParticleAreaUm2", min(max(area * dev.grainSize * dev.grainSize, 0.01), 5))
    }
  }
}

/// IEEE half to Float. Swift's Float16 is not available on Intel Macs.
@inline(__always) func halfToFloat(_ h: UInt16) -> Float {
  let sign: Float = h & 0x8000 != 0 ? -1 : 1
  let exp = Int(h >> 10) & 0x1f
  let mant = UInt32(h & 0x3ff)
  if exp == 0 { return sign * Float(mant) * 0x1p-24 }
  let bits = exp == 31 ? 0x7f80_0000 | (mant << 13) : UInt32(exp + 112) << 23 | (mant << 13)
  return sign * Float(bitPattern: bits)
}
