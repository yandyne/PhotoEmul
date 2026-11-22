// PhotoEmul - native editor for spektrafilm (GPL-3.0-or-later)
// On-screen display over the photo: the Lightroom-style photo info box (items picked in
// Settings › 화면 정보, toggled with I) and the opacity of every label drawn on the photo
// (Original/Current tags, the sharpening pill, the info box).

import ImageIO
import SwiftUI

enum OSD {
  static let infoOnKey = "osdInfoOn"
  static let itemsKey = "osdInfoItems"
  static let backgroundKey = "osdBackgroundOpacity"
  static let opacityKey = "osdOpacity"
  static let keys = [infoOnKey, itemsKey, backgroundKey, opacityKey]

  static let defaultItems = [Item.fileName, .captureDate, .camera, .lens, .exposure, .focalLength].map(\.rawValue).joined(separator: ",")
  static let defaultBackground = 0.6
  static let defaultOpacity = 1.0

  /// The colour profile macOS converts the photo to on this screen (System Settings › 디스플레이).
  static func monitorProfile(_ screen: NSScreen?) -> String? {
    (screen ?? NSScreen.main)?.colorSpace?.localizedName
  }

  static func items(_ raw: String) -> [Item] {
    raw.split(separator: ",").compactMap { Item(rawValue: String($0)) }
  }

  enum Item: String, CaseIterable, Identifiable {
    case fileName, folder, dimensions, fileSize, captureDate, camera, lens, exposure, focalLength,
         exposureBias, flash, recipe, zoom, monitor
    var id: String { rawValue }

    var title: String {
      switch self {
      case .fileName: return tr("파일 이름", "File Name")
      case .folder: return tr("폴더", "Folder")
      case .dimensions: return tr("크기 (픽셀)", "Dimensions")
      case .fileSize: return tr("파일 크기", "File Size")
      case .captureDate: return tr("촬영 일시", "Capture Date & Time")
      case .camera: return tr("카메라", "Camera")
      case .lens: return tr("렌즈", "Lens")
      case .exposure: return tr("노출 (셔터 · 조리개 · ISO)", "Exposure (Shutter · Aperture · ISO)")
      case .focalLength: return tr("초점 거리", "Focal Length")
      case .exposureBias: return tr("노출 보정", "Exposure Bias")
      case .flash: return tr("플래시", "Flash")
      case .recipe: return tr("필름 → 인화지", "Film → Paper")
      case .zoom: return tr("확대 비율", "Zoom")
      case .monitor: return tr("모니터 프로파일", "Monitor Profile")
      }
    }
  }

  /// One line of the info box, or nil when the photo does not carry it.
  static func value(_ item: Item, source: SourceImage, recipe: String, zoom: Double, monitor: String? = nil) -> String? {
    let props = source.properties
    let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
    let aux = props[kCGImagePropertyExifAuxDictionary] as? [CFString: Any] ?? [:]
    let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
    func number(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }
    func trimmed(_ v: Any?) -> String? {
      guard let s = (v as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
      return s
    }
    switch item {
    case .fileName:
      return source.url.lastPathComponent
    case .folder:
      return (source.url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
    case .dimensions:
      return "\(source.width) × \(source.height)"
    case .fileSize:
      guard let bytes = (try? source.url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize else { return nil }
      return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    case .captureDate:
      guard let raw = trimmed(exif[kCGImagePropertyExifDateTimeOriginal]) ?? trimmed(tiff[kCGImagePropertyTIFFDateTime]) else { return nil }
      // EXIF writes "2024:05:01 12:34:56".
      let parts = raw.split(separator: " ", maxSplits: 1)
      guard let day = parts.first else { return raw }
      return day.replacingOccurrences(of: ":", with: "-") + (parts.count > 1 ? " " + parts[1] : "")
    case .camera:
      let make = trimmed(tiff[kCGImagePropertyTIFFMake]), model = trimmed(tiff[kCGImagePropertyTIFFModel])
      guard let model else { return make }
      guard let make, !model.lowercased().hasPrefix(make.lowercased().split(separator: " ").first.map(String.init) ?? "") else { return model }
      return make + " " + model
    case .lens:
      return trimmed(exif[kCGImagePropertyExifLensModel]) ?? trimmed(aux[kCGImagePropertyExifAuxLensModel])
    case .exposure:
      var parts: [String] = []
      if let t = number(exif[kCGImagePropertyExifExposureTime]), t > 0 {
        parts.append(t < 0.3 ? "1/\(Int((1 / t).rounded())) s" : String(format: t < 10 ? "%.1f s" : "%.0f s", t))
      }
      if let f = number(exif[kCGImagePropertyExifFNumber]), f > 0 { parts.append(String(format: "f/%g", (f * 10).rounded() / 10)) }
      if let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first { parts.append("ISO \(iso.intValue)") }
      return parts.isEmpty ? nil : parts.joined(separator: " · ")
    case .focalLength:
      guard let f = number(exif[kCGImagePropertyExifFocalLength]), f > 0 else { return nil }
      var s = String(format: "%g mm", (f * 10).rounded() / 10)
      if let f35 = number(exif[kCGImagePropertyExifFocalLenIn35mmFilm]), f35 > 0, abs(f35 - f) > 0.5 {
        s += tr(" (35mm 환산 \(Int(f35)) mm)", " (\(Int(f35)) mm equiv.)")
      }
      return s
    case .exposureBias:
      guard let ev = number(exif[kCGImagePropertyExifExposureBiasValue]) else { return nil }
      return abs(ev) < 0.005 ? "0 EV" : String(format: "%+.1f EV", ev)
    case .flash:
      guard let v = (exif[kCGImagePropertyExifFlash] as? NSNumber)?.intValue else { return nil }
      return v & 1 == 1 ? tr("플래시 터짐", "Flash fired") : tr("플래시 안 터짐", "No flash")
    case .recipe:
      return recipe
    case .zoom:
      return "\(Int((zoom * 100).rounded()))%"
    case .monitor:
      return monitor
    }
  }
}

/// The info box in the photo's top-left corner.
struct PhotoInfoBox: View {
  let source: SourceImage
  let recipe: String
  let zoom: Double
  @AppStorage(OSD.itemsKey) private var itemsRaw = OSD.defaultItems
  @AppStorage(OSD.backgroundKey) private var background = OSD.defaultBackground
  /// Follows the window to another screen and profile changes in System Settings.
  @State private var monitor = OSD.monitorProfile(NSApp.mainWindow?.screen)

  /// Long values (a deep folder path) are cut in the middle so the box stays narrow.
  static func clipped(_ s: String, max: Int = 52) -> String {
    guard s.count > max else { return s }
    return String(s.prefix(max / 2 - 1)) + "…" + String(s.suffix(max / 2 - 1))
  }

  var body: some View {
    let lines = OSD.items(itemsRaw).compactMap { item in
      OSD.value(item, source: source, recipe: recipe, zoom: zoom, monitor: monitor).map { (item, $0) }
    }
    if !lines.isEmpty {
      VStack(alignment: .leading, spacing: 2) {
        ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
          Text(Self.clipped(line.1))
            .font(i == 0 ? .callout.weight(.semibold) : .caption)
            .foregroundStyle(i == 0 ? .white : .white.opacity(0.85))
            .lineLimit(1).truncationMode(.middle)
            .help(line.0.title)
        }
      }
      .monospacedDigit()
      .shadow(color: .black.opacity(background < 0.3 ? 0.8 : 0), radius: 1.5)
      .padding(.horizontal, 10).padding(.vertical, 7)
      .background(.black.opacity(background), in: RoundedRectangle(cornerRadius: 8))
      .allowsHitTesting(false)
      .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification)
        .merge(with: NotificationCenter.default.publisher(for: NSWindow.didChangeScreenProfileNotification))) { note in
        if let w = note.object as? NSWindow, w == NSApp.mainWindow { monitor = OSD.monitorProfile(w.screen) }
      }
    }
  }
}

/// Settings › 화면 정보.
struct OSDSettings: View {
  @AppStorage(OSD.infoOnKey) private var infoOn = false
  @AppStorage(OSD.itemsKey) private var itemsRaw = OSD.defaultItems
  @AppStorage(OSD.backgroundKey) private var background = OSD.defaultBackground
  @AppStorage(OSD.opacityKey) private var opacity = OSD.defaultOpacity

  private var items: [OSD.Item] { OSD.items(itemsRaw) }

  private func binding(_ item: OSD.Item) -> Binding<Bool> {
    Binding(get: { items.contains(item) }, set: { on in
      // Keep the order of the list below, whatever order they were ticked in.
      let set = Set(items).union(on ? [item] : []).subtracting(on ? [] : [item])
      itemsRaw = OSD.Item.allCases.filter(set.contains).map(\.rawValue).joined(separator: ",")
    })
  }

  var body: some View {
    Form {
      Section {
        Toggle(tr("사진 정보 표시", "Show Photo Info"), isOn: $infoOn)
        Text(tr("Lightroom의 정보 오버레이처럼 사진 왼쪽 위에 메타데이터를 보여 줍니다. 편집 화면에서 I 키로 켜고 끕니다.",
                "Shows the photo's metadata in its top-left corner, like Lightroom's info overlay. Press I in the editor to toggle it."))
          .font(.caption).foregroundStyle(.secondary)
      }
      Section(tr("표시할 항목", "Items")) {
        ForEach(OSD.Item.allCases) { item in
          Toggle(item.title, isOn: binding(item))
        }
        HStack {
          Button(tr("기본 항목으로", "Default Items")) { itemsRaw = OSD.defaultItems }
          Spacer()
        }
        Text(tr("첫 번째 항목은 굵게 표시됩니다. 사진에 없는 정보는 건너뜁니다.",
                "The first item is shown in bold. Items the photo does not carry are skipped."))
          .font(.caption).foregroundStyle(.secondary)
      }
      Section(tr("투명도", "Opacity")) {
        LabeledContent(tr("배경 불투명도", "Background Opacity")) {
          HStack {
            Slider(value: $background, in: 0...1, step: 0.05)
            Text("\(Int((background * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
          }
        }
        LabeledContent(tr("전체 불투명도", "Overall Opacity")) {
          HStack {
            Slider(value: $opacity, in: 0.2...1, step: 0.05)
            Text("\(Int((opacity * 100).rounded()))%").monospacedDigit().frame(width: 44, alignment: .trailing)
          }
        }
        Text(tr("원본 · 현재 · 미리보기 표시, 선명하게 만드는 중 표시, 사진 정보에 함께 적용됩니다. 배경을 0%로 하면 글자만 그림자와 함께 보입니다.",
                "Applies to the Original, Current and Preview tags, the sharpening indicator and the photo info. At 0% background only the text shows, with a shadow."))
          .font(.caption).foregroundStyle(.secondary)
        HStack {
          Spacer()
          HStack(spacing: 8) {
            Tag(text: tr("원본", "Original"))
            Tag(text: tr("현재", "Current"))
          }
          .opacity(opacity)
          .padding(14)
          .frame(maxWidth: .infinity)
          .background(LinearGradient(colors: [.orange, .teal, .indigo], startPoint: .leading, endPoint: .trailing),
                      in: RoundedRectangle(cornerRadius: 6))
          Spacer()
        }
        HStack {
          Button(tr("기본값", "Defaults")) { background = OSD.defaultBackground; opacity = OSD.defaultOpacity }
          Spacer()
        }
      }
    }
    .formStyle(.grouped)
  }
}
