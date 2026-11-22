// PhotoEmul - native editor for spektrafilm (GPL-3.0-or-later)
// App-side effects around the film engine, on the GPU:
//   before the engine (linear scene light, i.e. what the lens does):
//     chromatic aberration -> lens blur -> vignetting
//   after the engine (the finished print or scan):
//     black-and-white collapse + toning -> dust and scratches -> film frame / border
// Sizes are relative to the image so the proxy, the detail view and the
// saved file look the same.

import Foundation
import Metal

// MARK: - Parameters (stored next to the engine values, ignored by the bridge)

enum AppParams {
  static let all: [ParamDescriptor] = [
    d("devTempDelta", "Temperature vs. Standard (°C)", "devProcess", .double, def: 0, -10, 10),
    d("devTimePercent", "Development Time (%)", "devProcess", .double, def: 100, 50, 200),
    d("devDeveloper", "Developer", "develop", .choice, def: 0, options: Developer.names),
    d("devDilution", "Dilution", "develop", .choice, def: 0, options: Developer.dilutions),
    d("devHighlightCompression", "Highlight Compression", "develop", .double, tier: 1, def: 0, 0, 1),
    d("devBromideDrag", "Bromide Drag", "develop", .bool, tier: 1, def: 0),
    d("adjacencyEnabled", "Adjacency Effects", "adjacency", .bool, def: 0),
    d("adjacencyDeveloper", "Developer", "adjacency", .choice, def: Double(Adjacency.defaultDeveloper), options: Adjacency.developers),
    d("adjacencyAgitation", "Agitation", "adjacency", .choice, def: Double(Adjacency.defaultAgitation), options: Adjacency.agitations),
    d("adjacencyStrength", "Strength", "adjacency", .double, def: 1, 0, 2),
    d("unevenEnabled", "Uneven Development", "uneven", .bool, def: 0),
    d("unevenMottle", "Mottling (%)", "uneven", .double, def: 30, 0, 100),
    d("unevenEdge", "Edge Overdevelopment (%)", "uneven", .double, def: 0, 0, 100),
    d("unevenSurge", "Surge Marks (%)", "uneven", .double, def: 0, 0, 100),
    d("unevenAirBells", "Air Bells (%)", "uneven", .double, def: 0, 0, 100),
    d("unevenLowLevel", "Low Developer Level (%)", "uneven", .double, def: 0, 0, 100),
    d("unevenSeed", "Pattern", "uneven", .int, tier: 1, def: 1, 0, 999),
    d("bromideDragEnabled", "Bromide Drag", "bromideDrag", .bool, def: 0),
    d("bromideDragAmount", "Strength (%)", "bromideDrag", .double, def: 50, 0, 100),
    d("bromideDragLength", "Tail Length (mm)", "bromideDrag", .double, def: 3, 0.5, 10),
    d("bromideDragAngle", "Direction (°)", "bromideDrag", .double, def: 0, -180, 180),
    d("agingYears", "Years Past Expiry", "aging", .double, def: 0, 0, 30),
    d("agingStorage", "Storage Temperature", "aging", .choice, def: 2, options: ["Freezer (-18 °C)", "Refrigerator (4 °C)", "Room temperature (21 °C)", "Hot (30 °C)"]),
    d("agingHumidity", "Relative Humidity (%)", "aging", .double, def: 50, 20, 90),

    d("shutterSpeed", "Shutter Speed", "film", .choice, def: Double(Reciprocity.defaultSpeedIndex), options: Reciprocity.speedLabels),
    d("reciprocityCompensate", "Reciprocity Compensated", "film", .bool, def: 1),

    d("enlargerLightSource", "Enlarger Light", "darkroom", .choice, def: 0, options: Darkroom.lightSources),
    d("paperGradeHalf", "Paper Grade (Multigrade)", "darkroom", .choice, def: Double(Darkroom.defaultGrade), options: Darkroom.gradeLabels),
    d("printSplitGrade", "Split-Grade Printing", "darkroom", .bool, def: 0),
    d("printSoftSeconds", "Soft (00) Seconds", "darkroom", .double, def: 5, 0, 40),
    d("printHardSeconds", "Hard (5) Seconds", "darkroom", .double, def: 5, 0, 40),
    d("testStripEffect", "Use as Effect", "testStrip", .bool, def: 0),
    d("testStripCount", "Bands", "testStrip", .choice, def: 1, options: ["3", "5", "7", "9"]),
    d("testStripStep", "Exposure Step", "testStrip", .choice, def: 0, options: ["1/3 stop", "1/2 stop", "1 stop"]),
    d("testStripDirection", "Direction", "testStrip", .choice, def: 0,
      options: ["Left → right", "Right → left", "Top → bottom", "Bottom → top"]),
    d("testStripTarget", "Exposure to Vary", "testStrip", .choice, def: 0, options: ["Exposure", "Soft (00)", "Hard (5)"]),
    d("testStripLabels", "Band Labels", "testStrip", .bool, def: 1),

    d("lensProfileEnabled", "Lens Profile", "lensProfile", .bool, def: 0),
    d("lensProfileId", "Lens", "lensProfile", .int, def: 0, 0, 2_147_483_647),
    d("lensFocalMm", "Focal Length (mm)", "lensProfile", .double, def: 50, 1, 2000),
    d("lensAperture", "Aperture", "lensProfile", .choice, def: 0, options: LensProfile.apertureLabels),
    d("lensFocusDistance", "Focus Distance", "lensProfile", .choice, def: 3, options: LensProfile.distanceLabels),
    d("lensProfileStrength", "Strength", "lensProfile", .double, def: 1, 0, 2),
    d("lensApplyDistortion", "Distortion", "lensProfile", .bool, tier: 1, def: 1),
    d("lensApplyTca", "Color Fringing (TCA)", "lensProfile", .bool, tier: 1, def: 1),
    d("lensApplyVignette", "Vignetting", "lensProfile", .bool, tier: 1, def: 1),

    d("lensBlurEnabled", "Lens Blur", "lensBlur", .bool, def: 0),
    d("lensBlurShape", "Focus Shape", "lensBlur", .choice, def: 0, options: ["Circle (center focus)", "Horizontal band (tilt)", "Whole frame (soft)"]),
    d("lensBlurAmount", "Blur Size", "lensBlur", .double, def: 1, 0, 4),
    d("lensBlurFocusSize", "Focus Area", "lensBlur", .double, def: 0.35, 0, 1),
    d("lensBlurTransition", "Transition", "lensBlur", .double, def: 0.4, 0.02, 1),
    d("lensBlurFocusX", "Focus X", "lensBlur", .double, tier: 1, def: 0, -1, 1),
    d("lensBlurFocusY", "Focus Y", "lensBlur", .double, tier: 1, def: 0, -1, 1),
    d("lensBlurBokehBoost", "Bokeh Highlights", "lensBlur", .double, tier: 1, def: 0.5, 0, 2),

    d("vignetteEnabled", "Vignette", "vignette", .bool, def: 0),
    d("vignetteAmount", "Amount (EV)", "vignette", .double, def: -1, -3, 1),
    d("vignetteMidpoint", "Midpoint", "vignette", .double, def: 0.5, 0, 1),
    d("vignetteFeather", "Feather", "vignette", .double, def: 0.6, 0, 1),
    d("vignetteRoundness", "Roundness", "vignette", .double, tier: 1, def: 1, 0, 1),

    d("aberrationEnabled", "Chromatic Aberration", "aberration", .bool, def: 0),
    d("aberrationRedCyan", "Red ↔ Cyan", "aberration", .double, def: 0.6, -2, 2),
    d("aberrationBlueYellow", "Blue ↔ Yellow", "aberration", .double, def: -0.4, -2, 2),

    d("dustEnabled", "Dust & Scratches", "dust", .bool, def: 0),
    d("dustModel", "Dust Model", "dust", .choice, def: 0, options: ["Real scan statistics", "Classic"]),
    d("dustAmount", "Dust Amount", "dust", .double, def: 0.3, 0, 1),
    d("dustSize", "Dust Size", "dust", .double, def: 1, 0.2, 3),
    d("dustScratches", "Scratches", "dust", .double, def: 0.2, 0, 1),
    d("dustPolarity", "Dust Color", "dust", .choice, def: 2, options: ["White (negative print)", "Black (slide / scan)", "Auto (by film)"]),
    d("dustSeed", "Pattern", "dust", .int, tier: 1, def: 1, 0, 999),
    d("dustTypeDust", "Dust", "dust", .bool, def: 1),
    d("dustTypeHair", "Hairs & Fibres", "dust", .bool, def: 1),
    d("dustTypeScratch", "Scratches (transport)", "dust", .bool, def: 1),
    d("dustTypeStain", "Stains & Water Marks", "dust", .bool, tier: 1, def: 1),
    d("dustTypeFingerprint", "Fingerprint", "dust", .bool, tier: 1, def: 0),
    d("dustFormat", "Film Format", "dust", .choice, def: 0, options: ["35mm", "120 (6×7)", "4×5"]),
    d("dustEdgeBias", "Edge Bias", "dust", .double, tier: 1, def: 0.4, 0, 1),

    d("bwToning", "Toning", "toning", .choice, def: 0,
      options: ["None", "Selenium", "Sepia", "Gold (blue)", "Split (sepia / selenium)"]),
    d("bwToningAmount", "Toning Amount", "toning", .double, def: 0.5, 0, 1),

    d("frameStyle", "Frame", "frame", .choice, def: 0,
      options: ["None", "White print border", "Filed carrier (black)", "35mm film strip", "Instant film"]),
    d("frameSize", "Border Width", "frame", .double, def: 0.3, 0, 1),
    d("frameRoughness", "Edge Roughness", "frame", .double, def: 0.5, 0, 1),
  ]

  static let names: Set<String> = Set(all.map(\.name))

  private static func d(
    _ name: String, _ label: String, _ group: String, _ kind: ParamKind, tier: Int32 = 0,
    def: Double, _ minimum: Double = 0, _ maximum: Double = 1, options: [String] = []
  ) -> ParamDescriptor {
    ParamDescriptor(
      name: name, label: label, group: group, optionSet: nil, kind: kind, tier: tier,
      defaultInt: Int32(def), defaultValue: [def, 0, 0],
      minimum: kind == .choice ? 0 : minimum, maximum: kind == .choice ? Double(options.count - 1) : maximum,
      fixedOptions: options)
  }
}

// MARK: - GPU uniforms (all 4-byte fields; layout matches the Metal structs)

private struct PreUniforms {
  var w: UInt32 = 0, h: UInt32 = 0
  var caR: Float = 0, caB: Float = 0
  var vigOn: Int32 = 0, vigAmount: Float = 0, vigMid: Float = 0, vigFeather: Float = 0, vigRound: Float = 1
  var blurRadius: Float = 0, blurShape: Int32 = 0, focusSize: Float = 0, transition: Float = 0
  var focusX: Float = 0, focusY: Float = 0, bokehBoost: Float = 0, taps: Int32 = 0
  var lensOn: Int32 = 0, pxToDist: Float = 0, pxToVig: Float = 0, fillScale: Float = 1, rClampDist: Float = 2, rClampVig: Float = 1.1
  var d0: Float = 1, d1: Float = 0, d2: Float = 0, d3: Float = 0, d4: Float = 0
  var tr0: Float = 1, tr1: Float = 0, tr2: Float = 0, tb0: Float = 1, tb1: Float = 0, tb2: Float = 0
  var k1: Float = 0, k2: Float = 0, k3: Float = 0
}

private struct DragUniforms {
  var w: UInt32 = 0, h: UInt32 = 0, sw: UInt32 = 0, sh: UInt32 = 0, cell: UInt32 = 1
  var k: Float = 0, dx: Float = 0, dy: Float = 1, lenCells: Float = 1, steps: Int32 = 1
}

private struct DustUniforms {
  var w: UInt32, h: UInt32, cellPx: Float, gridW: UInt32, gridH: UInt32, white: Int32, gain: Float, pad1: Float
}

private struct PostUniforms {
  var w: UInt32 = 0, h: UInt32 = 0
  var dustAmount: Float = 0, dustSize: Float = 0, scratches: Float = 0, dustWhite: Int32 = 0, seed: UInt32 = 0
  var frameStyle: Int32 = 0, frameSize: Float = 0, frameRough: Float = 0
  var tone: Int32 = 0, toneAmount: Float = 0
}

final class EffectsProcessor: @unchecked Sendable {
  static let shared = EffectsProcessor()

  private let device: MTLDevice?
  private let queue: MTLCommandQueue?
  private var pipelines: [String: MTLComputePipelineState] = [:]
  private let sampler: MTLSamplerState?

  private init() {
    device = MTLCreateSystemDefaultDevice()
    queue = device?.makeCommandQueue()
    let s = MTLSamplerDescriptor()
    s.minFilter = .linear
    s.magFilter = .linear
    s.mipFilter = .linear
    s.sAddressMode = .clampToEdge
    s.tAddressMode = .clampToEdge
    sampler = device?.makeSamplerState(descriptor: s)
    guard let device else { return }
    // build.sh compiles Shaders/Effects.metal ahead of time; the source is only a fallback
    // for a bundle built without the Metal toolchain.
    let lib: MTLLibrary
    do {
      if let url = Bundle.main.url(forResource: "Effects", withExtension: "metallib"),
         let pre = try? device.makeLibrary(URL: url) {
        lib = pre
      } else if let url = Bundle.main.url(forResource: "Effects", withExtension: "metal") {
        lib = try device.makeLibrary(source: String(contentsOf: url, encoding: .utf8), options: nil)
      } else {
        FileHandle.standardError.write("effects shader: missing from the bundle\n".data(using: .utf8)!)
        return
      }
    } catch {
      FileHandle.standardError.write("effects shader: \(error)\n".data(using: .utf8)!)
      return
    }
    for half in [false, true] {
      let constants = MTLFunctionConstantValues()
      var flag = half
      constants.setConstantValue(&flag, type: .bool, index: 0)
      for name in ["lensPrep", "lensBlur", "mono", "dust", "dustStat", "frame", "dragDown", "dragShift", "dragApply"] {
        do {
          let f = try lib.makeFunction(name: name, constantValues: constants)
          pipelines[name + (half ? "_h" : "_f")] = try device.makeComputePipelineState(function: f)
        } catch {
          FileHandle.standardError.write("effects pipeline \(name): \(error)\n".data(using: .utf8)!)
        }
      }
    }
  }

  // MARK: Before the engine

  static func needsPre(_ v: [String: ParamValue]) -> Bool {
    v["lensBlurEnabled"]?.boolValue == true || v["vignetteEnabled"]?.boolValue == true
      || v["aberrationEnabled"]?.boolValue == true || LensProfile.isActive(v)
      || v["bromideDragEnabled"]?.boolValue == true
  }

  /// Returns `source` untouched when no pre effect is on (or the GPU is unavailable).
  func applyPre(_ source: PixelBuffer, _ v: [String: ParamValue]) -> PixelBuffer {
    applyDrag(applyLens(source, v), v)
  }

  private func applyLens(_ source: PixelBuffer, _ v: [String: ParamValue]) -> PixelBuffer {
    guard v["lensBlurEnabled"]?.boolValue == true || v["vignetteEnabled"]?.boolValue == true
            || v["aberrationEnabled"]?.boolValue == true || LensProfile.isActive(v),
          source.bytesPerComponent == 4, let device, let queue,
          let prep = pipelines["lensPrep_f"], let blur = pipelines["lensBlur_f"],
          let cmd = queue.makeCommandBuffer()
    else { return source }
    let w = source.width, h = source.height
    var u = PreUniforms()
    u.w = UInt32(w)
    u.h = UInt32(h)
    if v["aberrationEnabled"]?.boolValue == true {
      u.caR = Float(v["aberrationRedCyan"]?.doubleValue ?? 0)
      u.caB = Float(v["aberrationBlueYellow"]?.doubleValue ?? 0)
    }
    if v["vignetteEnabled"]?.boolValue == true {
      u.vigOn = 1
      u.vigAmount = Float(v["vignetteAmount"]?.doubleValue ?? -1)
      u.vigMid = Float(v["vignetteMidpoint"]?.doubleValue ?? 0.5)
      u.vigFeather = Float(v["vignetteFeather"]?.doubleValue ?? 0.6)
      u.vigRound = Float(v["vignetteRoundness"]?.doubleValue ?? 1)
    }
    if let lc = LensProfile.coefficients(v) {
      let toDist = LensProfile.pxToDist(v, crop: lc.crop, longEdgePx: max(w, h))
      u.lensOn = 1
      u.pxToDist = Float(toDist)
      u.pxToVig = Float(LensProfile.pxToVig(v, crop: lc.crop, longEdgePx: max(w, h)))
      u.rClampDist = Float(LensProfile.clampDist)
      u.rClampVig = Float(LensProfile.clampVig)
      u.fillScale = Float(LensProfile.fillScale(lc.dist, halfW: Double(w) / 2, halfH: Double(h) / 2,
                                                pxToDist: toDist, clamp: LensProfile.clampDist))
      (u.d0, u.d1, u.d2, u.d3, u.d4) = (Float(lc.dist[0]), Float(lc.dist[1]), Float(lc.dist[2]), Float(lc.dist[3]), Float(lc.dist[4]))
      (u.tr0, u.tr1, u.tr2) = (Float(lc.tcaR[0]), Float(lc.tcaR[1]), Float(lc.tcaR[2]))
      (u.tb0, u.tb1, u.tb2) = (Float(lc.tcaB[0]), Float(lc.tcaB[1]), Float(lc.tcaB[2]))
      (u.k1, u.k2, u.k3) = (Float(lc.vig[0]), Float(lc.vig[1]), Float(lc.vig[2]))
    }
    let longEdge = Float(max(w, h))
    let wantsBlur = v["lensBlurEnabled"]?.boolValue == true && (v["lensBlurAmount"]?.doubleValue ?? 0) > 0
    if wantsBlur {
      u.blurRadius = Float(v["lensBlurAmount"]?.doubleValue ?? 1) * 0.005 * longEdge
      u.blurShape = Int32(v["lensBlurShape"]?.intValue ?? 0)
      u.focusSize = Float(v["lensBlurFocusSize"]?.doubleValue ?? 0.35)
      u.transition = Float(v["lensBlurTransition"]?.doubleValue ?? 0.4)
      u.focusX = Float(v["lensBlurFocusX"]?.doubleValue ?? 0)
      u.focusY = Float(v["lensBlurFocusY"]?.doubleValue ?? 0)
      u.bokehBoost = Float(v["lensBlurBokehBoost"]?.doubleValue ?? 0.5)
      u.taps = 96
    }

    let out = PixelBuffer(width: w, height: h, bytesPerComponent: 4)
    guard let srcBuf = wrap(source, device), let outBuf = wrap(out, device) else { return source }

    if wantsBlur {
      // CA into a temporary, then blur (sampling a mipmapped copy) + vignette into `out`.
      let tmp = PixelBuffer(width: w, height: h, bytesPerComponent: 4)
      // Textures stop at 16384 px; a bigger photo blurs from a smaller copy (focus pixels come from the buffer).
      let k = min(1, 16384 / Double(max(w, h)))
      let desc = MTLTextureDescriptor.texture2DDescriptor(
        pixelFormat: .rgba16Float, width: max(1, Int(Double(w) * k)), height: max(1, Int(Double(h) * k)), mipmapped: true)
      desc.usage = [.shaderRead, .shaderWrite]
      desc.storageMode = .private
      guard let tmpBuf = wrap(tmp, device), let tex = device.makeTexture(descriptor: desc),
            let e1 = cmd.makeComputeCommandEncoder()
      else { return source }
      var u1 = u
      u1.vigOn = 0
      e1.setComputePipelineState(prep)
      e1.setBuffer(srcBuf, offset: 0, index: 0)
      e1.setBuffer(tmpBuf, offset: 0, index: 1)
      e1.setBytes(&u1, length: MemoryLayout<PreUniforms>.stride, index: 2)
      e1.setTexture(tex, index: 0)
      dispatch(e1, prep, w, h)
      e1.endEncoding()
      guard let blit = cmd.makeBlitCommandEncoder() else { return source }
      blit.generateMipmaps(for: tex)
      blit.endEncoding()
      guard let e2 = cmd.makeComputeCommandEncoder() else { return source }
      e2.setComputePipelineState(blur)
      e2.setBuffer(tmpBuf, offset: 0, index: 0)
      e2.setBuffer(outBuf, offset: 0, index: 1)
      e2.setBytes(&u, length: MemoryLayout<PreUniforms>.stride, index: 2)
      e2.setTexture(tex, index: 0)
      e2.setSamplerState(sampler, index: 0)
      dispatch(e2, blur, w, h)
      e2.endEncoding()
      cmd.commit()
      cmd.waitUntilCompleted()
      _ = tmp  // keep alive until the GPU is done
    } else {
      guard let e = cmd.makeComputeCommandEncoder() else { return source }
      e.setComputePipelineState(prep)
      e.setBuffer(srcBuf, offset: 0, index: 0)
      e.setBuffer(outBuf, offset: 0, index: 1)
      e.setBytes(&u, length: MemoryLayout<PreUniforms>.stride, index: 2)
      dispatch(e, prep, w, h)
      e.endEncoding()
      cmd.commit()
      cmd.waitUntilCompleted()
    }
    return cmd.status == .completed ? out : source
  }

  /// Bromide drag (BromideDrag.swift) on a grid of about 1024 cells along the long edge, so a proxy
  /// and the full-size image get the same tail.
  private func applyDrag(_ source: PixelBuffer, _ v: [String: ParamValue]) -> PixelBuffer {
    let w = source.width, h = source.height
    guard source.bytesPerComponent == 4, let s = BromideDrag.setup(v, longEdgePx: max(w, h)),
          let device, let queue, let down = pipelines["dragDown_f"], let shiftP = pipelines["dragShift_f"],
          let apply = pipelines["dragApply_f"], let cmd = queue.makeCommandBuffer()
    else { return source }
    let cell = max(1, Int((Double(max(w, h)) / 1024).rounded(.up)))
    var u = DragUniforms()
    u.w = UInt32(w)
    u.h = UInt32(h)
    u.sw = UInt32((w + cell - 1) / cell)
    u.sh = UInt32((h + cell - 1) / cell)
    u.cell = UInt32(cell)
    u.k = Float(s.strength)
    let a = s.angleDeg * .pi / 180  // 0 = flows down the picture, 90 = to the right
    u.dx = Float(sin(a))
    u.dy = Float(cos(a))
    u.lenCells = Float(s.lengthPx / Double(cell))
    u.steps = Int32(min(512, max(4, Int(u.lenCells.rounded(.up)))))
    let cells = Int(u.sw) * Int(u.sh) * MemoryLayout<Float>.stride
    let out = PixelBuffer(width: w, height: h, bytesPerComponent: 4)
    guard let srcBuf = wrap(source, device), let outBuf = wrap(out, device),
          let grid = device.makeBuffer(length: cells, options: .storageModePrivate),
          let shift = device.makeBuffer(length: cells, options: .storageModePrivate),
          let e = cmd.makeComputeCommandEncoder()
    else { return source }
    e.setComputePipelineState(down)
    e.setBuffer(srcBuf, offset: 0, index: 0)
    e.setBuffer(grid, offset: 0, index: 1)
    e.setBytes(&u, length: MemoryLayout<DragUniforms>.stride, index: 2)
    dispatch(e, down, Int(u.sw), Int(u.sh))
    e.setComputePipelineState(shiftP)
    e.setBuffer(grid, offset: 0, index: 0)
    e.setBuffer(shift, offset: 0, index: 1)
    dispatch(e, shiftP, Int(u.sw), Int(u.sh))
    e.setComputePipelineState(apply)
    e.setBuffer(srcBuf, offset: 0, index: 0)
    e.setBuffer(outBuf, offset: 0, index: 1)
    e.setBuffer(shift, offset: 0, index: 2)
    e.setBytes(&u, length: MemoryLayout<DragUniforms>.stride, index: 3)
    dispatch(e, apply, w, h)
    e.endEncoding()
    cmd.commit()
    cmd.waitUntilCompleted()
    return cmd.status == .completed ? out : source
  }

  // MARK: After the engine

  static func needsPost(_ v: [String: ParamValue]) -> Bool {
    v["dustEnabled"]?.boolValue == true || (v["frameStyle"]?.intValue ?? 0) != 0 || FilmInfo.isMono(v)
  }

  /// Dust is drawn in place; a frame needs a fresh buffer because the photo is resampled into it.
  func applyPost(_ image: PixelBuffer, _ v: [String: ParamValue]) -> PixelBuffer {
    guard Self.needsPost(v), let device, let queue, let cmd = queue.makeCommandBuffer() else { return image }
    let suffix = image.bytesPerComponent == 2 ? "_h" : "_f"
    guard let monoP = pipelines["mono" + suffix], let dustP = pipelines["dust" + suffix], let frameP = pipelines["frame" + suffix],
          let buf = wrap(image, device)
    else { return image }
    var u = PostUniforms()
    u.w = UInt32(image.width)
    u.h = UInt32(image.height)
    u.dustAmount = Float(v["dustAmount"]?.doubleValue ?? 0.3)
    u.dustSize = Float(v["dustSize"]?.doubleValue ?? 1)
    u.scratches = Float(v["dustScratches"]?.doubleValue ?? 0.2)
    u.dustWhite = Self.dustIsWhite(v) ? 1 : 0
    u.seed = UInt32(max(0, v["dustSeed"]?.intValue ?? 1))
    u.frameStyle = Int32(v["frameStyle"]?.intValue ?? 0)
    u.frameSize = Float(v["frameSize"]?.doubleValue ?? 0.3)
    u.frameRough = Float(v["frameRoughness"]?.doubleValue ?? 0.5)
    u.tone = Int32(v["bwToning"]?.intValue ?? 0)
    u.toneAmount = Float(v["bwToningAmount"]?.doubleValue ?? 0.5)

    var result = image
    if FilmInfo.isMono(v), let e = cmd.makeComputeCommandEncoder() {
      e.setComputePipelineState(monoP)
      e.setBuffer(buf, offset: 0, index: 0)
      e.setBytes(&u, length: MemoryLayout<PostUniforms>.stride, index: 1)
      dispatch(e, monoP, image.width, image.height)
      e.endEncoding()
    }
    let statistical = (v["dustModel"]?.intValue ?? 0) == 0
    if v["dustEnabled"]?.boolValue == true, statistical, let statP = pipelines["dustStat" + suffix] {
      let layout = DustModel.layout(DustModel.Settings(v), width: image.width, height: image.height)
      if !layout.items.isEmpty,
         let items = makeBuffer(layout.items, device), let starts = makeBuffer(layout.cellStart, device),
         let cells = makeBuffer(layout.cellItems, device), let e = cmd.makeComputeCommandEncoder() {
        var du = DustUniforms(w: u.w, h: u.h, cellPx: layout.cellPx, gridW: layout.gridW, gridH: layout.gridH,
                              white: u.dustWhite, gain: Darkroom.dustVisibility(v), pad1: 0)
        e.setComputePipelineState(statP)
        e.setBuffer(buf, offset: 0, index: 0)
        e.setBytes(&du, length: MemoryLayout<DustUniforms>.stride, index: 1)
        e.setBuffer(items, offset: 0, index: 2)
        e.setBuffer(starts, offset: 0, index: 3)
        e.setBuffer(cells, offset: 0, index: 4)
        dispatch(e, statP, image.width, image.height)
        e.endEncoding()
      }
    } else if v["dustEnabled"]?.boolValue == true, let e = cmd.makeComputeCommandEncoder() {
      e.setComputePipelineState(dustP)
      e.setBuffer(buf, offset: 0, index: 0)
      e.setBytes(&u, length: MemoryLayout<PostUniforms>.stride, index: 1)
      dispatch(e, dustP, image.width, image.height)
      e.endEncoding()
    }
    if u.frameStyle != 0 {
      let framed = PixelBuffer(width: image.width, height: image.height, bytesPerComponent: image.bytesPerComponent)
      if let out = wrap(framed, device), let e = cmd.makeComputeCommandEncoder() {
        e.setComputePipelineState(frameP)
        e.setBuffer(buf, offset: 0, index: 0)
        e.setBytes(&u, length: MemoryLayout<PostUniforms>.stride, index: 1)
        e.setBuffer(out, offset: 0, index: 2)
        dispatch(e, frameP, image.width, image.height)
        e.endEncoding()
        result = framed
      }
    }
    cmd.commit()
    cmd.waitUntilCompleted()
    return cmd.status == .completed ? result : image
  }

  // MARK: Helpers

  /// White specks for negatives (dust blocks light in the enlarger or the inverted scan), black for positives.
  static func dustIsWhite(_ v: [String: ParamValue]) -> Bool {
    switch v["dustPolarity"]?.intValue ?? 2 {
    case 0: return true
    case 1: return false
    default:
      guard let film = Catalog.films[safe: v["film"]?.intValue ?? -1] else { return true }
      return !FilmInfo.isPositive(film)
    }
  }

  private func makeBuffer<T>(_ a: [T], _ device: MTLDevice) -> MTLBuffer? {
    guard !a.isEmpty else { return device.makeBuffer(length: 16, options: .storageModeShared) }
    return a.withUnsafeBytes { device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared) }
  }

  /// Zero-copy view of a page-aligned PixelBuffer.
  private func wrap(_ b: PixelBuffer, _ device: MTLDevice) -> MTLBuffer? {
    device.makeBuffer(bytesNoCopy: b.data, length: b.allocatedBytes, options: .storageModeShared, deallocator: nil)
  }

  private func dispatch(_ e: MTLComputeCommandEncoder, _ p: MTLComputePipelineState, _ w: Int, _ h: Int) {
    let tw = p.threadExecutionWidth
    let th = max(1, p.maxTotalThreadsPerThreadgroup / tw)
    e.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
  }
}

/// Engine render wrapped with the app-side effects; used by preview, detail, save and headless.
enum RenderPipeline {
  static func render(
    _ engine: SpektraEngine, source: PixelBuffer, values: [String: ParamValue],
    output: Int32, bytesPerComponent: Int, effects: Bool = true
  ) -> PixelBuffer? {
    if effects, TestStrip.effectOn(values) {
      return TestStrip.render(engine, source: source, values: values, output: output, bytesPerComponent: bytesPerComponent)
    }
    let fx = EffectsProcessor.shared
    let input = effects ? fx.applyPre(source, values) : source
    let out = PixelBuffer(width: source.width, height: source.height, bytesPerComponent: bytesPerComponent)
    guard engine.render(input, into: out, params: Catalog.renderParams(values, output: output)) else { return nil }
    return effects ? fx.applyPost(out, values) : out
  }

  /// Dust and the frame are laid out over the whole picture, so a crop cannot be rendered alone.
  static func supportsRegion(_ values: [String: ParamValue]) -> Bool {
    values["dustEnabled"]?.boolValue != true && (values["frameStyle"]?.intValue ?? 0) == 0
      // Grain Synthesis seeds its particles per render, so tiles of it never line up with each other.
      && !(values["grainEnabled"]?.boolValue == true && values["grainModel"]?.intValue == 2)
      // The engine renders the whole frame for any region under these (frame-global passes).
      && abs((values["enlargerScale"]?.doubleValue ?? 1) - 1) <= 1e-6
      && (values["halationBoostEv"]?.doubleValue ?? 0) <= 0
  }

  /// The whole-frame pre effects, for several region renders of one source in a row.
  static func preEffects(_ source: PixelBuffer, values: [String: ParamValue]) -> PixelBuffer {
    EffectsProcessor.shared.applyPre(source, values)
  }

  /// Renders only `region` (source pixels) of the full-frame result; same pixels as cropping `render`.
  /// `preApplied` is `preEffects(source)` when the caller already has it.
  static func render(
    _ engine: SpektraEngine, source: PixelBuffer, region: CGRect, values: [String: ParamValue],
    output: Int32, bytesPerComponent: Int, preApplied: PixelBuffer? = nil
  ) -> PixelBuffer? {
    guard supportsRegion(values) else { return nil }
    let r = region.integral.intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
    guard r.width >= 1, r.height >= 1 else { return nil }
    if TestStrip.effectOn(values) {
      return TestStrip.render(
        engine, source: source, region: r, values: values, output: output, bytesPerComponent: bytesPerComponent,
        preApplied: preApplied)
    }
    let fx = EffectsProcessor.shared
    let input = preApplied ?? fx.applyPre(source, values)
    let out = PixelBuffer(width: Int(r.width), height: Int(r.height), bytesPerComponent: bytesPerComponent)
    guard engine.render(input, into: out, x: Int(r.minX), y: Int(r.minY), params: Catalog.renderParams(values, output: output))
    else { return nil }
    return fx.applyPost(out, values)
  }
}

/// CPU copy of the `mono` kernel, for the LUT bake.
enum MonoTone {
  static func apply(_ c: (Float, Float, Float), tone: Int, amount: Float) -> (Float, Float, Float) {
    let l = 0.2126 * c.0 + 0.7152 * c.1 + 0.0722 * c.2
    let t = min(max(l, 0), 1)
    let selenium: (Float, Float, Float) = (1.03, 0.94, 0.98), sepia: (Float, Float, Float) = (1.10, 0.98, 0.80)
    var tint: (Float, Float, Float) = (1, 1, 1)
    var w: Float = 0
    switch tone {
    case 1: tint = selenium; w = pow(1 - t, 1.5)
    case 2: tint = sepia; w = 1 - pow(t, 4)
    case 3: tint = (0.93, 0.98, 1.08); w = 1 - pow(t, 3)
    case 4:
      let x = min(max((t - 0.25) / 0.35, 0), 1), s = x * x * (3 - 2 * x)
      tint = (selenium.0 + (sepia.0 - selenium.0) * s, selenium.1 + (sepia.1 - selenium.1) * s,
              selenium.2 + (sepia.2 - selenium.2) * s)
      w = 1 - pow(t, 4)
    default: break
    }
    let k = amount * w
    return (l * (1 + (tint.0 - 1) * k), l * (1 + (tint.1 - 1) * k), l * (1 + (tint.2 - 1) * k))
  }
}
