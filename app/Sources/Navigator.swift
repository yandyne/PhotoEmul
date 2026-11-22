// PhotoEmul - native editor for spektrafilm (GPL-3.0-or-later)
// Lightroom-style panel folding (edge triangles, F5–F8, Tab) and the zoomed-in bird's-eye view.

import SwiftUI

/// The four panels around the canvas. The left one is `EditModel.pickerOpen`; the others are
/// plain defaults read with @AppStorage. Tab and ⇧Tab hide whatever shows, or bring all back.
enum Panels {
  static let recipeBarKey = "recipeBarOpen"
  static let inspectorKey = "inspectorOpen"

  static func shown(_ key: String) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
  static func flip(_ key: String) { UserDefaults.standard.set(!shown(key), forKey: key) }

  static func sides(_ model: EditModel) {
    let show = !(model.pickerOpen || shown(inspectorKey))
    model.pickerOpen = show
    UserDefaults.standard.set(show, forKey: inspectorKey)
  }

  static func all(_ model: EditModel) {
    let keys = [recipeBarKey, inspectorKey, HistoryTimeline.shownKey]
    let show = !(model.pickerOpen || keys.contains(where: shown))
    model.pickerOpen = show
    keys.forEach { UserDefaults.standard.set(show, forKey: $0) }
  }
}

/// Small triangle at the middle of a canvas edge: points toward the edge while the panel there
/// is open (click folds it away), away from it while folded.
struct PanelToggle: View {
  let edge: Edge
  let open: Bool
  let action: () -> Void
  @State private var hot = false

  var body: some View {
    let across = edge == .leading || edge == .trailing
    let dir = switch edge {
    case .top: open ? "up" : "down"
    case .bottom: open ? "down" : "up"
    case .leading: open ? "left" : "right"
    case .trailing: open ? "right" : "left"
    }
    let place: Alignment = switch edge {
    case .top: .top
    case .bottom: .bottom
    case .leading: .leading
    case .trailing: .trailing
    }
    Button(action: action) {
      Image(systemName: "arrowtriangle.\(dir).fill")
        .font(.system(size: 8))
        .frame(width: across ? 14 : 40, height: across ? 40 : 14)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .foregroundStyle(.white.opacity(hot ? 0.9 : 0.35))
    .shadow(color: .black.opacity(0.6), radius: 1)
    .onHover { hot = $0 }
    .help(open ? tr("패널 접기", "Hide panel") : tr("패널 펴기", "Show panel"))
    // Clear of the side edges' grab area, which reaches over the canvas.
    .padding(Edge.Set(edge), across ? PanelEdge.grab : 1)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: place)
  }
}

/// Bird's-eye view while part of the photo is off screen: the whole photo with the part on
/// screen framed. Drag the frame to pan; a click moves the view to the clicked point.
struct Navigator: View {
  let model: EditModel
  let canvas: CanvasState
  /// Canvas size in points.
  let viewSize: CGSize
  @Environment(\.displayScale) private var displayScale
  @State private var thumb: CGImage?
  /// Pointer offset from the frame centre at the start of a drag (0...1 of the photo).
  @State private var grab: CGPoint?
  @State private var dragged = false

  static let side = 180.0

  var body: some View {
    if let source = model.source, let preview = model.preview, !model.compareMode.isSideBySide {
      let w = Double(source.width), h = Double(source.height)
      let z = canvas.effectiveZoom
      // Part of the photo on screen (0...1 each way).
      let fw = min(viewSize.width * displayScale / (w * z), 1)
      let fh = min(viewSize.height * displayScale / (h * z), 1)
      if fw < 0.999 || fh < 0.999 {
        let size = w >= h ? CGSize(width: Self.side, height: Self.side * h / w) : CGSize(width: Self.side * w / h, height: Self.side)
        let c = Self.clamp(canvas.center, fw, fh)
        ZStack(alignment: .topLeading) {
          if let thumb { Image(decorative: thumb, scale: 1).resizable() } else { Color.black }
          // Sharpening tiles, coloured as in the pill's map: done white, the next one accent.
          // Like the pill, not for a quiet job (only off-screen margin tiles, often back from disk).
          if let job = model.detailJob, !job.quiet {
            ForEach(Array(job.cells.enumerated()), id: \.offset) { i, cell in
              let current = !job.finished && !job.loading && i == job.done
              if job.finished || i <= job.done {
                Rectangle()
                  .fill(job.finished ? Color.green.opacity(0.25) : current ? Color.accentColor.opacity(0.45) : Color.white.opacity(0.3))
                  .frame(width: cell.width / w * size.width, height: cell.height / h * size.height)
                  .offset(x: cell.minX / w * size.width, y: cell.minY / h * size.height)
              }
            }
          }
          Rectangle()
            .strokeBorder(.white, lineWidth: 1.5)
            .shadow(color: .black.opacity(0.7), radius: 1)
            .frame(width: fw * size.width, height: fh * size.height)
            .offset(x: (c.x - fw / 2) * size.width, y: (c.y - fh / 2) * size.height)
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .contentShape(Rectangle())
        .gesture(DragGesture(minimumDistance: 0)
          .onChanged { g in
            let p = CGPoint(x: g.location.x / size.width, y: g.location.y / size.height)
            if grab == nil {
              // Inside the frame it moves by where it was caught; outside it centres on the pointer.
              let inside = abs(p.x - c.x) <= fw / 2 && abs(p.y - c.y) <= fh / 2
              grab = inside ? CGPoint(x: p.x - c.x, y: p.y - c.y) : .zero
            }
            if hypot(g.translation.width, g.translation.height) > 2 { dragged = true }
            guard dragged, let grab else { return }
            canvas.center = Self.clamp(CGPoint(x: p.x - grab.x, y: p.y - grab.y), fw, fh)
          }
          .onEnded { g in
            if !dragged {
              canvas.animateZoom = true
              canvas.center = Self.clamp(CGPoint(x: g.location.x / size.width, y: g.location.y / size.height), fw, fh)
            }
            grab = nil
            dragged = false
          })
        .padding(3)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
        .help(tr("버드뷰 · 틀을 끌어 이동, 누르면 그 자리로", "Navigator · drag the frame to pan, click to jump"))
        .task(id: ObjectIdentifier(preview)) { thumb = PixelImage.cgImage(halfP3: preview) }
      }
    }
  }

  /// Keeps the frame inside the photo.
  static func clamp(_ p: CGPoint, _ fw: Double, _ fh: Double) -> CGPoint {
    CGPoint(x: min(max(p.x, fw / 2), 1 - fw / 2), y: min(max(p.y, fh / 2), 1 - fh / 2))
  }
}
