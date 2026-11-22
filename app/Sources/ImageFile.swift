// PhotoEmul - native editor for spektrafilm (GPL-3.0-or-later)
// TIFF in/out through ImageIO. The engine works in linear Rec.2020; the
// Lightroom round trip expects a 16-bit ProPhoto TIFF back.

import CSpektra
import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import UniformTypeIdentifiers
import Accelerate

enum ImageFileError: LocalizedError {
  case unreadable(String)
  case unwritable(String)

  var errorDescription: String? {
    switch self {
    case .unreadable(let p): return tr("이미지를 읽을 수 없습니다: ", "Cannot read image: ") + p
    case .unwritable(let p): return tr("이미지를 쓸 수 없습니다: ", "Cannot write image: ") + p
    }
  }
}

struct SourceImage {
  let url: URL
  let image: CGImage
  let properties: [CFString: Any]
  var width: Int { image.width }
  var height: Int { image.height }

  static func load(_ url: URL) throws -> SourceImage {
    guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(src, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    else { throw ImageFileError.unreadable(url.path) }
    var props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
    // Camera files are often stored sideways with an EXIF orientation; bake it in so the
    // editor and the exported file show the photo upright.
    let orientation = (props[kCGImagePropertyOrientation] as? NSNumber)?.uint32Value ?? 1
    if orientation != 1, let o = CGImagePropertyOrientation(rawValue: orientation), let upright = Self.orient(image, o) {
      props[kCGImagePropertyOrientation] = 1
      if var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
        tiff[kCGImagePropertyTIFFOrientation] = 1
        props[kCGImagePropertyTIFFDictionary] = tiff
      }
      return SourceImage(url: url, image: upright, properties: props)
    }
    return SourceImage(url: url, image: image, properties: props)
  }

  private static func orient(_ image: CGImage, _ o: CGImagePropertyOrientation) -> CGImage? {
    let space = image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
    let ci = CIImage(cgImage: image).oriented(o)
    let ctx = CIContext(options: [.workingColorSpace: NSNull(), .outputColorSpace: NSNull()])
    return ctx.createCGImage(ci, from: ci.extent, format: .RGBAh, colorSpace: space)
  }

  /// Linear Rec.2020 float RGBA, optionally downscaled so the long edge is at most `maxEdge`.
  func linearPixels(maxEdge: Int? = nil) -> PixelBuffer? {
    let (w, h) = fittedSize(maxEdge)
    return draw(width: w, height: h, space: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!, bytesPerComponent: 4)
  }

  /// sRGB-encoded float pixels clipped to 0...1 (what a LUT sees).
  func srgbPixels(maxEdge: Int? = nil) -> PixelBuffer? {
    let (w, h) = fittedSize(maxEdge)
    return draw(width: w, height: h, space: CGColorSpace(name: CGColorSpace.sRGB)!, bytesPerComponent: 4)
  }

  /// Display P3 half-float pixels of the untouched photo, for the before view.
  func displayPixels(maxEdge: Int) -> PixelBuffer? {
    let (w, h) = fittedSize(maxEdge)
    return draw(width: w, height: h, space: CGColorSpace(name: CGColorSpace.displayP3)!, bytesPerComponent: 2)
  }

  /// The editor's working copies. The photo is resampled and colour converted once, at the
  /// proxy size; the smaller copies are scaled down from that and the before view is a
  /// same-size conversion of it, instead of four full decodes.
  struct Previews {
    let proxy: PixelBuffer
    let before: PixelBuffer
    let draft: PixelBuffer
    let thumb: PixelBuffer
  }

  func previews(proxyEdge: Int, draftEdge: Int, thumbEdge: Int) -> Previews? {
    guard let proxy = linearPixels(maxEdge: proxyEdge) else { return nil }
    let (dw, dh) = fittedSize(draftEdge), (tw, th) = fittedSize(thumbEdge)
    guard let before = Self.displayCopy(of: proxy),
          let draft = Self.scaled(proxy, width: dw, height: dh),
          let thumb = Self.scaled(proxy, width: tw, height: th)
    else { return nil }
    return Previews(proxy: proxy, before: before, draft: draft, thumb: thumb)
  }

  /// Float RGBA scaled with vImage's high-quality (Lanczos) filter.
  static func scaled(_ src: PixelBuffer, width w: Int, height h: Int) -> PixelBuffer? {
    if w == src.width && h == src.height {
      let copy = PixelBuffer(width: w, height: h)
      copy.data.copyMemory(from: src.data, byteCount: src.rowBytes * h)
      return copy
    }
    let dst = PixelBuffer(width: w, height: h)
    var s = vImage_Buffer(data: src.data, height: vImagePixelCount(src.height), width: vImagePixelCount(src.width), rowBytes: src.rowBytes)
    var d = vImage_Buffer(data: dst.data, height: vImagePixelCount(h), width: vImagePixelCount(w), rowBytes: dst.rowBytes)
    guard vImageScale_ARGBFFFF(&s, &d, nil, vImage_Flags(kvImageHighQualityResampling)) == kvImageNoError else { return nil }
    let f = dst.floats, n = w * 4
    // Lanczos rings slightly below zero at hard edges; the engine expects non-negative light.
    DispatchQueue.concurrentPerform(iterations: h) { y in
      let row = f + y * n
      for i in 0..<n where row[i] < 0 { row[i] = 0 }
    }
    return dst
  }

  /// Display P3 half-float copy of linear Rec.2020 float pixels, at the same size.
  static func displayCopy(of src: PixelBuffer) -> PixelBuffer? {
    let w = src.width, h = src.height
    let data = Data(bytesNoCopy: src.data, count: src.rowBytes * h, deallocator: .none)
    let floatInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
    guard let provider = CGDataProvider(data: data as CFData),
          let image = CGImage(
            width: w, height: h, bitsPerComponent: 32, bitsPerPixel: 128, bytesPerRow: src.rowBytes,
            space: CGColorSpace(name: CGColorSpace.extendedLinearITUR_2020)!,
            bitmapInfo: CGBitmapInfo(rawValue: floatInfo | CGBitmapInfo.byteOrder32Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    else { return nil }
    let dst = PixelBuffer(width: w, height: h, bytesPerComponent: 2)
    guard let ctx = CGContext(
      data: dst.data, width: w, height: h, bitsPerComponent: 16, bytesPerRow: dst.rowBytes,
      space: CGColorSpace(name: CGColorSpace.displayP3)!, bitmapInfo: floatInfo | CGBitmapInfo.byteOrder16Little.rawValue)
    else { return nil }
    ctx.interpolationQuality = .none
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    return dst
  }

  func fittedSize(_ maxEdge: Int?) -> (Int, Int) {
    guard let maxEdge, max(width, height) > maxEdge else { return (width, height) }
    let s = Double(maxEdge) / Double(max(width, height))
    return (max(1, Int((Double(width) * s).rounded())), max(1, Int((Double(height) * s).rounded())))
  }

  /// CoreGraphics' float resampling can leave NaN or huge values; they wreck auto exposure.
  private func sanitize(_ buffer: PixelBuffer) {
    let f = buffer.floats, n = buffer.width * 4
    DispatchQueue.concurrentPerform(iterations: buffer.height) { y in
      let row = f + y * n
      for i in 0..<n where !(row[i].isFinite && abs(row[i]) < 1e4) { row[i] = 0 }
    }
  }

  private func draw(width w: Int, height h: Int, space: CGColorSpace, bytesPerComponent bpc: Int) -> PixelBuffer? {
    let buffer = PixelBuffer(width: w, height: h, bytesPerComponent: bpc)
    let order: CGBitmapInfo = bpc == 4 ? .byteOrder32Little : .byteOrder16Little
    let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | order.rawValue
    guard let ctx = CGContext(
      data: buffer.data, width: w, height: h, bitsPerComponent: bpc * 8, bytesPerRow: buffer.rowBytes,
      space: space, bitmapInfo: info)
    else { return nil }
    ctx.interpolationQuality = .high
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    if bpc == 4 { sanitize(buffer) }
    return buffer
  }
}

enum TiffWriter {
  /// Writes ProPhoto-encoded float RGBA as a 16-bit RGB TIFF, keeping the source metadata.
  static func writeProPhoto16(_ pixels: PixelBuffer, to url: URL, properties: [CFString: Any]) throws {
    let w = pixels.width, h = pixels.height
    let rowBytes = w * 3 * 2
    let out = UnsafeMutablePointer<UInt16>.allocate(capacity: w * h * 3)
    defer { out.deallocate() }
    let src = pixels.floats
    DispatchQueue.concurrentPerform(iterations: h) { y in
      let s = src + y * w * 4
      let d = out + y * w * 3
      for x in 0..<w {
        for c in 0..<3 {
          let v = min(max(s[x * 4 + c], 0), 1)
          d[x * 3 + c] = UInt16(v * 65535 + 0.5)
        }
      }
    }
    let data = Data(bytesNoCopy: out, count: rowBytes * h, deallocator: .none)
    // Write beside the target and move it into place, so Lightroom never imports a half-written file.
    let partial = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).partial")
    defer { try? FileManager.default.removeItem(at: partial) }
    guard let provider = CGDataProvider(data: data as CFData),
          let image = CGImage(
            width: w, height: h, bitsPerComponent: 16, bitsPerPixel: 48, bytesPerRow: rowBytes,
            space: CGColorSpace(name: CGColorSpace.rommrgb)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue | CGBitmapInfo.byteOrder16Little.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let dest = CGImageDestinationCreateWithURL(partial as CFURL, UTType.tiff.identifier as CFString, 1, nil)
    else { throw ImageFileError.unwritable(url.path) }

    var props = properties
    for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth,
                kCGImagePropertyColorModel, kCGImagePropertyProfileName, kCGImagePropertyHasAlpha] {
      props.removeValue(forKey: key)
    }
    var tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
    tiff[kCGImagePropertyTIFFCompression] = 5  // LZW
    tiff[kCGImagePropertyTIFFSoftware] = "PhotoEmul (spektrafilm)"
    props[kCGImagePropertyTIFFDictionary] = tiff
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw ImageFileError.unwritable(url.path) }
    if FileManager.default.fileExists(atPath: url.path) {
      _ = try FileManager.default.replaceItemAt(url, withItemAt: partial)
    } else {
      try FileManager.default.moveItem(at: partial, to: url)
    }
  }
}

/// What a standalone export writes.
enum ExportFormat: String, CaseIterable, Identifiable {
  case tiff16, jpeg
  var id: String { rawValue }
  var title: String {
    switch self {
    case .tiff16: return tr("TIFF 16비트 (ProPhoto RGB)", "TIFF 16-bit (ProPhoto RGB)")
    case .jpeg: return tr("JPEG (sRGB)", "JPEG (sRGB)")
    }
  }
  var type: UTType { self == .tiff16 ? .tiff : .jpeg }
  var fileExtension: String { self == .tiff16 ? "tif" : "jpg" }
  /// Engine output colour space for this format.
  var colorSpace: Int32 { self == .tiff16 ? ColorSpaceIndex.proPhoto : SpektraAppSrgbColorSpace() }

  func write(_ pixels: PixelBuffer, to url: URL, properties: [CFString: Any]) throws {
    switch self {
    case .tiff16: try TiffWriter.writeProPhoto16(pixels, to: url, properties: properties)
    case .jpeg: try JpegWriter.writeSRGB8(pixels, to: url, properties: properties)
    }
  }
}

enum JpegWriter {
  /// Writes sRGB-encoded float RGBA as an 8-bit JPEG, keeping the source metadata.
  static func writeSRGB8(_ pixels: PixelBuffer, to url: URL, properties: [CFString: Any], quality: Double = ExportOptions.jpegQuality) throws {
    let w = pixels.width, h = pixels.height
    let out = UnsafeMutablePointer<UInt8>.allocate(capacity: w * h * 4)
    defer { out.deallocate() }
    let src = pixels.floats
    DispatchQueue.concurrentPerform(iterations: h) { y in
      let s = src + y * w * 4
      let d = out + y * w * 4
      for x in 0..<w {
        for c in 0..<3 { d[x * 4 + c] = UInt8(min(max(s[x * 4 + c], 0), 1) * 255 + 0.5) }
        d[x * 4 + 3] = 255
      }
    }
    let data = Data(bytesNoCopy: out, count: w * h * 4, deallocator: .none)
    guard let provider = CGDataProvider(data: data as CFData),
          let image = CGImage(
            width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent),
          let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil)
    else { throw ImageFileError.unwritable(url.path) }
    var props = properties
    for key in [kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth,
                kCGImagePropertyColorModel, kCGImagePropertyProfileName, kCGImagePropertyHasAlpha,
                kCGImagePropertyTIFFDictionary] {
      props.removeValue(forKey: key)
    }
    props[kCGImageDestinationLossyCompressionQuality] = quality
    CGImageDestinationAddImage(dest, image, props as CFDictionary)
    guard CGImageDestinationFinalize(dest) else { throw ImageFileError.unwritable(url.path) }
  }
}
