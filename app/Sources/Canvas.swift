// PhotoEmul - native editor for spektrafilm (GPL-3.0-or-later)
// Metal canvas: shows the proxy render, swaps in the full-res render when zoomed in.

import AppKit
import MetalKit
import SwiftUI

/// Zoom/pan state shared by the canvas and the toolbar.
@Observable
final class CanvasState {
  /// Device pixels per source pixel; nil means fit to window.
  var zoom: Double?
  /// Point of the image (0...1) shown at the view centre.
  var center = CGPoint(x: 0.5, y: 0.5)
  var fitZoom: Double = 1
  /// Zoom at which the image covers the whole view.
  var fillZoom: Double = 1
  /// Fill is a mode, not a number: the zoom follows the view through resizes and margin changes.
  var fill = false
  /// Which base a toggle (Z, click, double tap) returns to: the last of Fit / Fill the user picked.
  var baseFill = false
  var atBase: Bool { zoom == nil || fill }
  /// Level a click or Z zooms to from Fit (the last preset picked, like Lightroom's navigator).
  var toggleLevel: Double = 1
  /// Divider position of the split view, 0...1 across the view (stays put while panning and zooming).
  var split: Double = 0.5
  /// Divider position of the top/bottom split view, 0...1 down from the top.
  var splitY: Double = 0.5
  /// Colour under the cursor; separate object so moving the mouse does not redraw the canvas.
  let probe = ProbeState()

  var effectiveZoom: Double { zoom ?? fitZoom }
  /// The next draw eases to the new zoom and centre instead of jumping (Z, Fit, presets, clicks).
  @ObservationIgnored var animateZoom = false

  /// Diagnostics: SPEKTRALAB_ZOOM="z[,cx,cy][@seconds];..." opens the window at the first zoom
  /// and centre and moves to each later one after its delay, to replay a zoom sequence.
  init() {
    guard ProcessInfo.processInfo.environment["SPEKTRALAB_DIAG"] != nil,
          let spec = ProcessInfo.processInfo.environment["SPEKTRALAB_ZOOM"] else { return }
    for step in spec.split(separator: ";") {
      let at = step.split(separator: "@")
      let parts = at[0].split(separator: ",").compactMap { Double($0) }
      let delay = at.count > 1 ? Double(at[1]) ?? 0 : 0
      let apply = { [weak self] in
        guard let self, let z = parts.first else { return }
        self.zoom = z
        if parts.count >= 3 { self.center = CGPoint(x: parts[1], y: parts[2]) }
        FileHandle.standardError.write("zoom step \(z)\n".data(using: .utf8)!)
        func redraw(_ v: NSView) { (v as? MTKView)?.needsDisplay = true; v.subviews.forEach(redraw) }
        NSApp.windows.compactMap(\.contentView).forEach(redraw)
      }
      if delay > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: apply) } else { apply() }
    }
  }

  func setZoom(_ z: Double?) {
    fill = false
    animateZoom = true
    zoom = z.map { min(max($0, 0.02), 16) }
    if z == nil { center = CGPoint(x: 0.5, y: 0.5); baseFill = false }
  }

  static let presets: [Double] = [0.125, 0.25, 0.5, 1, 2, 4, 8]

  /// Picks a preset level (nil = Fit); fixed levels also become the click / Z level.
  func choose(_ z: Double?) {
    if let z, abs(z - fillZoom) > 1e-6 { toggleLevel = z }
    setZoom(z)
  }

  /// Fill, centred.
  func chooseFill() {
    animateZoom = true
    zoom = fillZoom
    fill = true
    baseFill = true
    center = CGPoint(x: 0.5, y: 0.5)
  }

  /// Back to the base the user last picked: Fit or Fill.
  func home() { baseFill ? chooseFill() : setZoom(nil) }

  /// Z / click: Fit or Fill <-> the toggle level (100% / 200%), whichever base was picked last.
  func toggle() { atBase ? setZoom(toggleLevel) : home() }

  /// ⌘+ / ⌘−: next preset level up or down, Fit and Fill included.
  func step(_ direction: Int) {
    let z = effectiveZoom
    let levels = (Self.presets + [fitZoom, fillZoom]).sorted()
    let next = direction > 0 ? levels.first { $0 > z * 1.001 } : levels.last { $0 < z * 0.999 }
    guard let next else { return }
    if abs(next - fillZoom) < 1e-9 { return chooseFill() }
    setZoom(abs(next - fitZoom) < 1e-9 ? nil : next)
  }
}

struct ProbeReading: Equatable {
  /// Source-image pixel under the cursor.
  let x: Int, y: Int
  /// Display P3 encoded 0...1.
  let rgb: [Double]
}

@Observable
final class ProbeState {
  var reading: ProbeReading?
}

struct CanvasView: NSViewRepresentable {
  let model: EditModel
  let state: CanvasState

  func makeNSView(context: Context) -> CanvasMTKView {
    let view = CanvasMTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
    view.canvas = state
    view.renderer = CanvasRenderer(view: view)
    return view
  }

  func updateNSView(_ view: CanvasMTKView, context: Context) {
    guard let r = view.renderer else { return }
    // Read so a pan from outside the canvas (the navigator) redraws it; its own drags draw directly.
    _ = state.center
    let source = model.source
    r.sourceSize = source.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
    // Slower Macs stay on the proxy until the zoom is well past it, so Fit on a big screen does
    // not start a full-res render after every edit.
    let wants = state.effectiveZoom > model.proxyScale * (Performance.lowPower ? 1.6 : 1.05)
    let hover = model.showBefore ? nil : model.testStripImage ?? model.hoverPreview
    let next = model.showBefore ? model.before : hover ?? model.preview
    // Into, out of and between hover looks: cross-fade from what is on screen.
    let hoverLook = model.testStripImage == nil && hover != nil
    if next !== r.image, hoverLook || r.showingHover, !model.showBefore, FilmPanel.hoverFade { r.beginFade() }
    r.showingHover = hoverLook
    r.image = next
    // With the test strip up, a click on a band picks it; kept as the effect, an option-click
    // does, so a plain click still zooms.
    view.stripPickable = model.testStripOn && model.testStripImage != nil
    view.stripOptionPickable = model.testStripEffect && !model.showBefore
    view.onStripPick = { [weak model] x, y in
      guard let model else { return }
      model.pickTestStrip(model.testStripBand(x: x, y: y))
    }
    // Zoomed in: the full-res render of the visible area goes over the proxy. The current scale
    // goes on top; the other scales show only where it has no tile yet, coarser ones at the
    // bottom. Grain is drawn afresh at each scale, so a sharper tile left from an earlier, closer
    // zoom would otherwise sit beside the current ones with a visible edge for good.
    // A hovered film shows the proxy alone; the tiles of the current look keep rendering.
    let scale = EditModel.detailScale(zoom: state.effectiveZoom, proxyScale: model.proxyScale)
    func layered(_ tiles: [DetailTile]) -> [(PixelBuffer, CGRect)] {
      // Coarser (coarsest first) < finer (finest first) < current.
      func rank(_ s: Double) -> Double { s == scale ? 10 : s < scale ? s : 1 + 1 / s }
      return tiles.sorted { rank($0.scale) < rank($1.scale) }.map { ($0.buffer, $0.region) }
    }
    r.details = !model.showBefore && hover == nil && wants ? layered(model.detailTiles) : []
    r.mode = model.showBefore ? .off : model.compareMode
    r.compare = r.mode == .off ? nil : model.compareImage
    r.compareDetails = r.compare != nil && wants ? layered(model.compareTiles) : []
    r.onViewport = { [weak model] rect in
      DispatchQueue.main.async { if model?.viewport != rect { model?.viewport = rect } }
    }
    r.onCompareViewport = { [weak model] rect in
      DispatchQueue.main.async { if model?.compareViewport != rect { model?.compareViewport = rect } }
    }
    if model.detailScale != scale { DispatchQueue.main.async { model.detailScale = scale } }
    if model.wantsDetail != wants { DispatchQueue.main.async { model.wantsDetail = wants } }
    view.requestDraw()
  }
}

final class CanvasMTKView: MTKView {
  weak var canvas: CanvasState?
  var renderer: CanvasRenderer?
  private var lastDrag: NSPoint?
  private var draggingDivider = false
  /// Lightroom-style clicks: where the press started, whether it has turned into a drag, and
  /// whether the press zoomed in from Fit (released after a drag, it goes back to Fit).
  private var pressStart: NSPoint?
  private var pressMoved = false
  private var pressZoomedIn = false
  /// The press began on a picture, not on the background around it: only then does a click zoom.
  private var pressOnImage = false

  private func onImage(_ p: NSPoint) -> Bool {
    renderer?.drawn.contains { $0.visible.contains(p) } ?? false
  }

  /// Open hand where a press zooms or pans, the arrow on the background of a fitted image.
  private func pointerCursor(_ p: NSPoint) -> NSCursor {
    if nearDivider(p) { return dividerCursor }
    return canvas?.zoom != nil || onImage(p) ? .openHand : .arrow
  }
  private var backdropObserver: NSObjectProtocol?
  private var lastMargin = Appearance.canvasMargin
  var stripPickable = false
  var stripOptionPickable = false
  /// Where the click fell, as fractions of the image: x from the left, y from the top.
  var onStripPick: ((Double, Double) -> Void)?

  override var acceptsFirstResponder: Bool { true }

  /// Draws asked for and not yet made.
  fileprivate var pendingDraw = false

  /// A new size shows the last frame until the next draw: centred at its own size (layerContentsPlacement), not stretched.
  override func setFrameSize(_ newSize: NSSize) {
    super.setFrameSize(newSize)
    // Synced live resize: draw now, inside the window's resize transaction, so the photo and the
    // window change size in the same frame.
    if presentsInTransaction, drawableSize.width > 0 { pendingDraw = false; draw() } else { requestDraw() }
  }

  /// Settings › 일반 › 창 크기 조절 동기화 (on unless turned off): only while the window is being resized.
  static let syncResizeKey = "canvasSyncResize"
  /// Settings › 색 관리 › 16비트 화면 출력 (on unless turned off): smoother gradients than 8 bits;
  /// macOS still converts from Display P3 to the monitor profile either way.
  static let deepColorKey = "canvasDeepColor"
  static var outputFormat: MTLPixelFormat {
    UserDefaults.standard.object(forKey: deepColorKey) as? Bool ?? true ? .rgba16Float : .bgra8Unorm
  }
  private var presentsInTransaction: Bool { (layer as? CAMetalLayer)?.presentsWithTransaction ?? false }

  override func viewWillStartLiveResize() {
    super.viewWillStartLiveResize()
    (layer as? CAMetalLayer)?.presentsWithTransaction = UserDefaults.standard.object(forKey: Self.syncResizeKey) as? Bool ?? true
  }

  override func viewDidEndLiveResize() {
    super.viewDidEndLiveResize()
    (layer as? CAMetalLayer)?.presentsWithTransaction = false
  }

  /// needsDisplay, and a direct draw if AppKit has not made one by the next turn of the run loop.
  /// AppKit can drop the view's needsDisplay requests (after a photo opens into the empty window,
  /// while the window is resized): the canvas then stays blank or stretched until something else draws.
  func requestDraw() {
    needsDisplay = true
    guard !pendingDraw else { return }
    pendingDraw = true
    DispatchQueue.main.async { [weak self] in
      guard let self, self.pendingDraw else { return }
      self.pendingDraw = false
      guard self.window != nil, self.drawableSize.width > 0 else { return }
      self.draw()
    }
  }

  override init(frame: CGRect, device: MTLDevice?) {
    super.init(frame: frame, device: device)
    isPaused = true
    enableSetNeedsDisplay = true
    colorPixelFormat = Self.outputFormat
    // Until a resized view draws again, keep the last frame at its size, centred like a fitted
    // photo, over the backdrop colour: stretched, it would distort the photo for a moment.
    layerContentsPlacement = .center
    layer?.contentsGravity = .center
    // A last frame bigger than the shrunk view is cut at its edges, not drawn over the sidebars.
    layer?.masksToBounds = true
    updateClearColor()
    backdropObserver = NotificationCenter.default.addObserver(
      forName: UserDefaults.didChangeNotification, object: nil, queue: .main
    ) { [weak self] _ in
      guard let self else { return }
      if self.colorPixelFormat != Self.outputFormat {
        self.colorPixelFormat = Self.outputFormat
        self.renderer?.makePipelines()
        self.requestDraw()
      }
      self.renderer?.updateProof()
      let old = self.clearColor
      self.updateClearColor()
      let c = self.clearColor
      let margin = Appearance.canvasMargin
      if (c.red, c.green, c.blue) != (old.red, old.green, old.blue) || margin != self.lastMargin {
        self.lastMargin = margin
        self.requestDraw()
      }
    }
    (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.displayP3)
  }

  required init(coder: NSCoder) { fatalError() }
  deinit {
    if let backdropObserver { NotificationCenter.default.removeObserver(backdropObserver) }
  }

  override func viewDidChangeEffectiveAppearance() {
    super.viewDidChangeEffectiveAppearance()
    updateClearColor()
    requestDraw()
  }

  private func updateClearColor() {
    var c = MTLClearColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)
    effectiveAppearance.performAsCurrentDrawingAppearance {
      if let rgb = Appearance.canvasColor.usingColorSpace(.sRGB) {
        c = MTLClearColor(red: rgb.redComponent, green: rgb.greenComponent, blue: rgb.blueComponent, alpha: 1)
      }
    }
    clearColor = c
    layer?.backgroundColor = CGColor(srgbRed: c.red, green: c.green, blue: c.blue, alpha: 1)
  }

  private var scale: Double { Double(window?.backingScaleFactor ?? 2) }

  /// Moves the image so that `delta` (view points, y down) follows the cursor.
  private func pan(by delta: CGSize) {
    guard let c = canvas, let r = renderer, r.sourceSize.width > 0 else { return }
    let z = c.effectiveZoom
    clampCenter()  // a centre left outside by a resize would swallow the first part of the drag
    c.center.x -= delta.width * scale / (r.sourceSize.width * z)
    c.center.y -= delta.height * scale / (r.sourceSize.height * z)
    clampCenter()
  }

  private func clampCenter() {
    guard let c = canvas, let r = renderer else { return }
    c.center = r.clampedCentre(c.center, zoom: c.effectiveZoom)
  }

  /// Zooms to `level` (nil = back to Fit / Fill), keeping the image point under `point` still.
  private func zoom(to level: Double?, at point: NSPoint) {
    guard let c = canvas else { return }
    guard let level else { return c.home() }
    zoom(by: level / c.effectiveZoom, at: point, minimum: 0.02)
    c.animateZoom = true
  }

  /// Zooms by `factor`, keeping the image point under `point` (view coords) still.
  private func zoom(by factor: Double, at point: NSPoint, minimum: Double? = nil) {
    guard let c = canvas, let r = renderer, r.sourceSize.width > 0 else { return }
    let z0 = c.effectiveZoom
    let z1 = min(max(z0 * factor, minimum ?? c.fitZoom * 0.5), 16)
    // Measure from the centre of the pane under the pointer (side by side has two), and from
    // the centre actually drawn: a fitted image is always centred whatever `center` holds.
    let pane = r.panes.first { $0.contains(point) }
      ?? r.panes.min { hypot($0.midX - point.x, $0.midY - point.y) < hypot($1.midX - point.x, $1.midY - point.y) }
      ?? bounds
    let dx = (point.x - pane.midX) * scale, dy = (pane.midY - point.y) * scale
    let c0 = r.drawnCentre
    let ix = c0.x + dx / (r.sourceSize.width * z0)
    let iy = c0.y + dy / (r.sourceSize.height * z0)
    c.zoom = z1
    c.fill = false
    c.center = CGPoint(x: ix - dx / (r.sourceSize.width * z1), y: iy - dy / (r.sourceSize.height * z1))
    clampCenter()
  }

  override func scrollWheel(with event: NSEvent) {
    if event.modifierFlags.contains(.command) || event.modifierFlags.contains(.option) {
      zoom(by: exp(event.scrollingDeltaY * 0.01), at: convert(event.locationInWindow, from: nil))
    } else {
      pan(by: CGSize(width: event.scrollingDeltaX, height: event.scrollingDeltaY))
    }
    requestDraw()
  }

  override func magnify(with event: NSEvent) {
    zoom(by: 1 + event.magnification, at: convert(event.locationInWindow, from: nil))
    requestDraw()
  }

  override func updateTrackingAreas() {
    super.updateTrackingAreas()
    trackingAreas.forEach(removeTrackingArea)
    addTrackingArea(NSTrackingArea(
      rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect, .cursorUpdate],
      owner: self))
  }

  /// The divider stays this far inside the view so it can always be grabbed again.
  static let dividerInset = 16.0

  private var hasDivider: Bool { renderer?.dividerX != nil || renderer?.dividerY != nil }

  private var dividerCursor: NSCursor { renderer?.dividerY != nil ? .resizeUpDown : .resizeLeftRight }

  private func nearDivider(_ p: NSPoint) -> Bool {
    let grab = CanvasRenderer.knobRadius + 3
    if let y = renderer?.dividerY {
      return abs(p.y - y) < 12 || hypot(p.x - bounds.midX, p.y - y) < grab
    }
    guard let x = renderer?.dividerX else { return false }
    return abs(p.x - x) < 12 || hypot(p.x - x, p.y - bounds.midY) < grab
  }

  /// Moves the divider to `p` (view points), kept `dividerInset` inside the view.
  private func setDivider(_ p: NSPoint) {
    guard let c = canvas else { return }
    let inset = Self.dividerInset
    if renderer?.dividerY != nil {
      guard bounds.height > 2 * inset else { return }
      c.splitY = 1 - min(max(p.y, inset), bounds.height - inset) / bounds.height
    } else {
      guard bounds.width > 2 * inset else { return }
      c.split = min(max(p.x, inset), bounds.width - inset) / bounds.width
    }
    requestDraw()
  }

  private func setDividerHot(_ hot: Bool) {
    guard let r = renderer, r.dividerHot != hot else { return }
    r.dividerHot = hot
    requestDraw()
  }

  override func mouseMoved(with event: NSEvent) {
    let p = convert(event.locationInWindow, from: nil)
    canvas?.probe.reading = renderer?.probe(at: p)
    setDividerHot(nearDivider(p))
    if !PanelEdge.engaged { pointerCursor(p).set() }
  }

  override func mouseExited(with event: NSEvent) {
    canvas?.probe.reading = nil
    // AppKit keeps sending drag events outside the view; keep the divider cursor until mouseUp.
    guard !draggingDivider else { return }
    setDividerHot(false)
    if !PanelEdge.engaged { NSCursor.arrow.set() }
  }

  override func cursorUpdate(with event: NSEvent) {
    guard !draggingDivider else { return dividerCursor.set() }
    guard !PanelEdge.engaged else { return NSCursor.resizeLeftRight.set() }
    pointerCursor(convert(event.locationInWindow, from: nil)).set()
  }

  override func mouseDown(with event: NSEvent) {
    window?.makeFirstResponder(self)
    let p = convert(event.locationInWindow, from: nil)
    if hasDivider {
      // Option-click summons the divider; double-clicking it centres it.
      if event.modifierFlags.contains(.option) {
        setDivider(p)
        draggingDivider = true
        dividerCursor.set()
        return
      }
      if nearDivider(p) {
        if event.clickCount == 2 { setDivider(NSPoint(x: bounds.midX, y: bounds.midY)) }
        draggingDivider = true
        dividerCursor.set()
        return
      }
    }
    if stripPickable || (stripOptionPickable && event.modifierFlags.contains(.option)), let rect = renderer?.lastImageRect, rect.width > 0, rect.height > 0, rect.contains(p) {
      onStripPick?((p.x - rect.minX) / rect.width, (rect.maxY - p.y) / rect.height)
      return
    }
    // Like Lightroom: pressing on a fitted image zooms in at the pointer right away; a click
    // keeps the zoom, a drag pans and goes back to Fit on release. Zoomed in, a click fits.
    lastDrag = event.locationInWindow
    pressStart = event.locationInWindow
    pressMoved = false
    pressZoomedIn = false
    pressOnImage = onImage(p)
    guard event.clickCount == 1, pressOnImage, let c = canvas, c.atBase, renderer?.sourceSize.width ?? 0 > 0 else { return }
    zoom(to: c.toggleLevel, at: p)
    pressZoomedIn = true
    NSCursor.closedHand.set()
    requestDraw()
  }

  override func mouseDragged(with event: NSEvent) {
    if draggingDivider {
      setDivider(convert(event.locationInWindow, from: nil))
      dividerCursor.set()
      return
    }
    guard let last = lastDrag else { return }
    let p = event.locationInWindow
    if let start = pressStart, hypot(p.x - start.x, p.y - start.y) > 3 { pressMoved = true }
    NSCursor.closedHand.set()
    pan(by: CGSize(width: p.x - last.x, height: last.y - p.y))
    lastDrag = p
    requestDraw()
  }

  override func mouseUp(with event: NSEvent) {
    lastDrag = nil
    if pressStart != nil {
      if pressZoomedIn ? pressMoved : pressOnImage && !pressMoved && event.clickCount == 1 {
        canvas?.home()
        requestDraw()
      }
      pressStart = nil
      let p = convert(event.locationInWindow, from: nil)
      if bounds.contains(p) && !PanelEdge.engaged { pointerCursor(p).set() }
    }
    guard draggingDivider else { return }
    draggingDivider = false
    let p = convert(event.locationInWindow, from: nil)
    let inside = bounds.contains(p)
    setDividerHot(inside && nearDivider(p))
    (inside ? pointerCursor(p) : NSCursor.arrow).set()
  }
}

final class CanvasRenderer: NSObject, MTKViewDelegate {
  var image: PixelBuffer?
  /// Sharper renders of parts of the image (region in source pixels), drawn over `image`.
  var details: [(buffer: PixelBuffer, region: CGRect)] = []
  /// The "before" image of the compare views.
  var compare: PixelBuffer?
  /// Sharper renders of parts of `compare`.
  var compareDetails: [(buffer: PixelBuffer, region: CGRect)] = []
  var mode: CompareMode = .off
  var sourceSize: CGSize = .zero
  /// Receives the part of the (current) image on screen, in source pixels, after each draw.
  var onViewport: ((CGRect) -> Void)?
  private var lastViewport: CGRect = .zero
  /// The same for the compare image.
  var onCompareViewport: ((CGRect) -> Void)?
  private var lastCompareViewport: CGRect = .zero
  /// Where the (current) image was last drawn, in view points (bottom-left origin).
  private(set) var lastImageRect: CGRect = .zero
  /// The panes the image was last drawn in (view points, bottom-left origin): two in the
  /// side-by-side views, otherwise the whole view. Zooming keeps the point under the pointer
  /// still relative to the pane it falls in.
  private(set) var panes: [CGRect] = []
  /// The image centre actually drawn (0...1), which differs from `Canvas.center` when the
  /// fitted image is centred or Fill clamps it.
  private(set) var drawnCentre = CGPoint(x: 0.5, y: 0.5)
  /// Pane size and Fit/Fill margin of the last draw (device pixels), for `clampedCentre`.
  private var paneSize = CGSize.zero
  private var paneMargin = 0.0

  /// Zoom (device pixels per source pixel), centre (0...1) and Fit/Fill margin (device pixels) of a view.
  private struct ViewPose: Equatable { var z: Double, c: CGPoint, inset: Double }
  /// What the last draw showed, and the pose the state asked for then (with the image and pane
  /// sizes, which jump instead of easing when they change).
  private var shownPose: ViewPose?
  private var lastTarget: (pose: ViewPose, size: CGSize, pane: CGSize)?
  private var zoomAnim: (from: ViewPose, start: CFTimeInterval, duration: Double)?
  private static let zoomDuration = 0.25

  /// The pose to draw now: eases from what is on screen to `target` after a discrete zoom
  /// (Z, Fit, presets, a click), keeping the image point that stays put between the two still,
  /// so a click zooms in around the pointer. Pans and pinches during the move retarget it.
  private func animatedPose(_ target: ViewPose, canvas: CanvasState) -> ViewPose {
    let now = CACurrentMediaTime()
    let sameGeometry = lastTarget.map { $0.size == sourceSize && $0.pane == paneSize } ?? false
    if !sameGeometry || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
      zoomAnim = nil
    } else if let shown = shownPose, target != lastTarget?.pose {
      if canvas.animateZoom {
        zoomAnim = (shown, now, Self.zoomDuration)
      } else if let a = zoomAnim {
        zoomAnim = (shown, now, max(a.start + a.duration - now, 0.08))
      }
    }
    canvas.animateZoom = false
    lastTarget = (target, sourceSize, paneSize)
    guard let a = zoomAnim else { return target }
    let t = (now - a.start) / a.duration
    if t >= 1 { zoomAnim = nil; return target }
    let e = 1 - pow(1 - t, 3)
    let za = a.from.z, zb = target.z
    let z = exp(log(za) + (log(zb) - log(za)) * e)
    // Offsets from the image edge to the pane centre (device pixels) move in step with the zoom.
    let k = abs(zb - za) > 1e-9 * za ? (z - za) / (zb - za) : e
    let W = sourceSize.width, H = sourceSize.height
    let ox = a.from.c.x * W * za + (target.c.x * W * zb - a.from.c.x * W * za) * k
    let oy = (1 - a.from.c.y) * H * za + ((1 - target.c.y) * H * zb - (1 - a.from.c.y) * H * za) * k
    return ViewPose(z: z, c: CGPoint(x: ox / (W * z), y: 1 - oy / (H * z)),
                    inset: a.from.inset + (target.inset - a.from.inset) * e)
  }

  /// `c` moved so the image keeps covering the pane less the margin wherever it
  /// is larger than the pane, and centred where it is smaller: panning stops at the image edges.
  func clampedCentre(_ c: CGPoint, zoom z: Double) -> CGPoint {
    guard sourceSize.width > 0, paneSize.width > 0 else { return c }
    func axis(_ c: Double, _ size: Double, _ room: Double) -> Double {
      size <= room ? 0.5 : min(max(c, room / 2 / size), 1 - room / 2 / size)
    }
    let m = 2 * paneMargin
    return CGPoint(x: axis(c.x, sourceSize.width * z, paneSize.width - m),
                   y: axis(c.y, sourceSize.height * z, paneSize.height - m))
  }
  /// Split-view divider in view points, nil when not in split view.
  private(set) var dividerX: Double?
  /// The same for the top/bottom split view (bottom-left origin).
  private(set) var dividerY: Double?
  /// The pointer is over the divider: its handle is drawn larger.
  var dividerHot = false
  /// Radius of the divider handle in view points.
  static let knobRadius = 13.0
  /// Drawn images for snapshots and the colour picker: visible area, drawn rect, pixels, and the
  /// part of the source image (source pixels) the pixels cover.
  private(set) var drawn: [(visible: CGRect, rect: CGRect, buffer: PixelBuffer, source: CGRect)] = []

  private let device: MTLDevice
  private let queue: MTLCommandQueue
  private var pipeline: MTLRenderPipelineState
  private var solidPipeline: MTLRenderPipelineState
  private var fadePipeline: MTLRenderPipelineState
  private let library: MTLLibrary
  private let linearSampler: MTLSamplerState
  private let nearestSampler: MTLSamplerState
  /// Soft proof (Settings › 색 관리): the lookup table, or a 1-texel stand-in while off.
  private var proofLUT: MTLTexture?
  private let noLUT: MTLTexture
  private var proofSettings = ""
  private var proofWarn = false
  private var textures: [(source: PixelBuffer, texture: MTLTexture)] = []
  /// Large buffers are copied to the GPU on this queue; drawing shows what is ready meanwhile.
  private let uploadQueue = DispatchQueue(label: "photoemul.upload", qos: .userInitiated)
  private var uploading: Set<ObjectIdentifier> = []
  /// Last texture of the main image, shown while a large new one is still uploading.
  private var lastImageTexture: MTLTexture?
  /// The image shown is a hover look (film/paper card under the pointer).
  var showingHover = false
  /// The previous image fading out over the new one.
  private var fadeFrom: MTLTexture?
  private var fadeStart: CFTimeInterval = 0
  private static let fadeDuration = 0.12
  weak var view: MTKView?
  /// Bigger buffers (e.g. the full-res detail) upload in the background.
  private static let syncUploadLimit = 6_000_000

  private static let shader = """
  #include <metal_stdlib>
  using namespace metal;
  struct VOut { float4 pos [[position]]; float2 uv; };
  vertex VOut vmain(uint vid [[vertex_id]], constant float4 &rect [[buffer(0)]]) {
    float2 corners[4] = { float2(0,0), float2(1,0), float2(0,1), float2(1,1) };
    float2 c = corners[vid];
    VOut o;
    o.pos = float4(rect.xy + c * rect.zw, 0, 1);
    o.uv = float2(c.x, 1 - c.y);
    return o;
  }
  constant sampler lutSampler(filter::linear, address::clamp_to_edge);
  // proof: 0 off, 1 soft proof, 2 soft proof marking out-of-gamut colours.
  float3 proofed(float3 c, texture3d<float> lut, int proof) {
    if (proof == 0) return c;
    float n = lut.get_width();
    float4 p = lut.sample(lutSampler, (saturate(c) * (n - 1) + 0.5) / n);
    return proof == 2 && p.a > 0.5 ? float3(1, 0, 0.5) : p.rgb;
  }
  fragment float4 fmain(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]],
                        texture3d<float> lut [[texture(1)]], constant int &proof [[buffer(1)]]) {
    return float4(proofed(tex.sample(s, in.uv).rgb, lut, proof), 1);
  }
  fragment float4 ffade(VOut in [[stage_in]], texture2d<float> tex [[texture(0)]], sampler s [[sampler(0)]],
                        constant float &alpha [[buffer(0)]], texture3d<float> lut [[texture(1)]], constant int &proof [[buffer(1)]]) {
    return float4(proofed(tex.sample(s, in.uv).rgb, lut, proof), alpha);
  }
  fragment float4 fsolid(VOut in [[stage_in]], constant float4 &color [[buffer(0)]]) {
    return color;
  }
  """

  init?(view: MTKView) {
    guard let device = view.device, let queue = device.makeCommandQueue(),
          let lib = try? device.makeLibrary(source: Self.shader, options: nil)
    else { return nil }
    guard let (pipeline, solidPipeline, fadePipeline) = Self.pipelines(device, lib, view.colorPixelFormat) else { return nil }
    func sampler(_ f: MTLSamplerMinMagFilter) -> MTLSamplerState {
      let s = MTLSamplerDescriptor()
      s.minFilter = .linear
      s.magFilter = f
      s.mipFilter = .notMipmapped
      return device.makeSamplerState(descriptor: s)!
    }
    let one = MTLTextureDescriptor()
    one.textureType = .type3D
    one.pixelFormat = .rgba16Unorm
    one.usage = .shaderRead
    guard let noLUT = device.makeTexture(descriptor: one) else { return nil }
    self.noLUT = noLUT
    self.device = device
    self.queue = queue
    self.pipeline = pipeline
    self.solidPipeline = solidPipeline
    self.fadePipeline = fadePipeline
    library = lib
    linearSampler = sampler(.linear)
    nearestSampler = sampler(.nearest)
    super.init()
    view.delegate = self
    self.view = view
    updateProof()
  }

  /// Rebuilds the soft-proof table when its settings change (in the background, ~1 s).
  func updateProof() {
    let warn = SoftProof.gamutWarning
    if warn != proofWarn { proofWarn = warn; (view as? CanvasMTKView)?.requestDraw() }
    let d = UserDefaults.standard
    let settings = [SoftProof.onKey, SoftProof.targetKey, SoftProof.iccKey, SoftProof.intentKey]
      .map { "\(d.object(forKey: $0) ?? "")" }.joined(separator: "|")
    guard settings != proofSettings else { return }
    proofSettings = settings
    guard let space = SoftProof.space else {
      proofLUT = nil
      (view as? CanvasMTKView)?.requestDraw()
      return
    }
    let intent = SoftProof.intent
    DispatchQueue.global(qos: .userInitiated).async { [weak self] in
      let table = SoftProof.lut(space, intent: intent)
      DispatchQueue.main.async {
        guard let self, self.proofSettings == settings else { return }
        let n = SoftProof.size
        let desc = MTLTextureDescriptor()
        desc.textureType = .type3D
        desc.pixelFormat = .rgba16Unorm
        desc.width = n; desc.height = n; desc.depth = n
        desc.usage = .shaderRead
        guard let tex = self.device.makeTexture(descriptor: desc) else { return }
        table.withUnsafeBytes {
          tex.replace(region: MTLRegionMake3D(0, 0, 0, n, n, n), mipmapLevel: 0, slice: 0,
                      withBytes: $0.baseAddress!, bytesPerRow: n * 8, bytesPerImage: n * n * 8)
        }
        self.proofLUT = tex
        (self.view as? CanvasMTKView)?.requestDraw()
      }
    }
  }

  private static func pipelines(_ device: MTLDevice, _ lib: MTLLibrary, _ format: MTLPixelFormat)
    -> (MTLRenderPipelineState, MTLRenderPipelineState, MTLRenderPipelineState)? {
    let desc = MTLRenderPipelineDescriptor()
    desc.vertexFunction = lib.makeFunction(name: "vmain")
    desc.fragmentFunction = lib.makeFunction(name: "fmain")
    desc.colorAttachments[0].pixelFormat = format
    guard let pipeline = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
    desc.fragmentFunction = lib.makeFunction(name: "fsolid")
    guard let solidPipeline = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
    desc.fragmentFunction = lib.makeFunction(name: "ffade")
    let blend = desc.colorAttachments[0]!
    blend.isBlendingEnabled = true
    blend.sourceRGBBlendFactor = .sourceAlpha
    blend.destinationRGBBlendFactor = .oneMinusSourceAlpha
    blend.sourceAlphaBlendFactor = .one
    blend.destinationAlphaBlendFactor = .oneMinusSourceAlpha
    guard let fadePipeline = try? device.makeRenderPipelineState(descriptor: desc) else { return nil }
    return (pipeline, solidPipeline, fadePipeline)
  }

  /// The view's pixel format changed (Settings › 색 관리).
  func makePipelines() {
    guard let view, let p = Self.pipelines(device, library, view.colorPixelFormat) else { return }
    (pipeline, solidPipeline, fadePipeline) = p
  }

  /// Starts fading out the image on screen; call before `image` changes.
  func beginFade() {
    guard let tex = lastImageTexture else { return }
    fadeFrom = tex
    fadeStart = CACurrentMediaTime()
  }

  func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) { (view as? CanvasMTKView)?.requestDraw() }

  /// The buffer's texture, or nil while a large one is still uploading in the background.
  private func upload(_ buffer: PixelBuffer) -> MTLTexture? {
    if let hit = textures.first(where: { $0.source === buffer }) { return hit.texture }
    guard buffer.width <= 16384, buffer.height <= 16384 else { return nil }
    let desc = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: buffer.bytesPerComponent == 2 ? .rgba16Float : .rgba32Float,
      width: buffer.width, height: buffer.height, mipmapped: false)
    desc.usage = .shaderRead
    if buffer.width * buffer.height <= Self.syncUploadLimit {
      guard let tex = device.makeTexture(descriptor: desc) else { return nil }
      tex.replace(
        region: MTLRegionMake2D(0, 0, buffer.width, buffer.height), mipmapLevel: 0,
        withBytes: buffer.data, bytesPerRow: buffer.rowBytes)
      keep(tex, for: buffer)
      return tex
    }
    let id = ObjectIdentifier(buffer)
    guard !uploading.contains(id) else { return nil }
    uploading.insert(id)
    desc.storageMode = .private
    let device = device, queue = queue
    uploadQueue.async { [weak self] in
      let tex = Self.blitUpload(buffer, desc: desc, device: device, queue: queue)
      DispatchQueue.main.async {
        guard let self else { return }
        self.uploading.remove(id)
        guard let tex, buffer === self.image || buffer === self.compare || self.details.contains(where: { $0.buffer === buffer })
                || self.compareDetails.contains(where: { $0.buffer === buffer }) else { return }
        self.keep(tex, for: buffer)
        (self.view as? CanvasMTKView)?.requestDraw()
      }
    }
    return nil
  }

  private func keep(_ tex: MTLTexture, for buffer: PixelBuffer) {
    // Keep only what is on screen now (current + compare + detail tiles) plus the new texture.
    textures.removeAll { t in
      t.source !== image && t.source !== compare && !details.contains { $0.buffer === t.source }
        && !compareDetails.contains { $0.buffer === t.source }
    }
    textures.append((buffer, tex))
  }

  /// Copies the buffer into a GPU-only texture in ~8 MB strips, each its own short command
  /// buffer, so the copy never holds the GPU (or the main thread) for long.
  private static func blitUpload(_ buffer: PixelBuffer, desc: MTLTextureDescriptor, device: MTLDevice, queue: MTLCommandQueue) -> MTLTexture? {
    guard let tex = device.makeTexture(descriptor: desc),
          let staging = device.makeBuffer(bytesNoCopy: buffer.data, length: buffer.allocatedBytes, options: .storageModeShared, deallocator: nil)
    else { return nil }
    let rows = max(1, (8 << 20) / buffer.rowBytes)
    for y in stride(from: 0, to: buffer.height, by: rows) {
      let n = min(rows, buffer.height - y)
      guard let cmd = queue.makeCommandBuffer(), let blit = cmd.makeBlitCommandEncoder() else { return nil }
      blit.copy(
        from: staging, sourceOffset: y * buffer.rowBytes, sourceBytesPerRow: buffer.rowBytes,
        sourceBytesPerImage: n * buffer.rowBytes, sourceSize: MTLSize(width: buffer.width, height: n, depth: 1),
        to: tex, destinationSlice: 0, destinationLevel: 0, destinationOrigin: MTLOrigin(x: 0, y: y, z: 0))
      blit.endEncoding()
      cmd.commit()
      cmd.waitUntilCompleted()
    }
    // Keeps the pixels alive until the GPU has read them.
    withExtendedLifetime(buffer) {}
    return tex
  }

  func draw(in view: MTKView) {
    (view as? CanvasMTKView)?.pendingDraw = false
    guard let canvas = (view as? CanvasMTKView)?.canvas,
          let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
          let cmd = queue.makeCommandBuffer(), let enc = cmd.makeRenderCommandEncoder(descriptor: pass)
    else { return }
    let vw = Double(view.drawableSize.width), vh = Double(view.drawableSize.height)
    let s = view.drawableSize.width / max(view.bounds.width, 1)
    var newDrawn: [(visible: CGRect, rect: CGRect, buffer: PixelBuffer, source: CGRect)] = []
    var imageRect = CGRect.zero
    var divider: Double?, dividerRow: Double?
    var fadeNeedsFrame = false
    // While the zoom eases, the viewport is reported only once it settles: tiles for passing
    // views would be wasted renders.
    var zooming = false
    if let image, sourceSize.width > 0 {
      let compare = mode == .off ? nil : compare
      let sideBySide = mode == .sideBySide && compare != nil
      let stackedPanes = mode == .sideBySideStacked && compare != nil
      // Side by side: two half-width (or half-height) panes sharing zoom and centre.
      let paneW = sideBySide ? (vw - 2) / 2 : vw
      let paneH = stackedPanes ? (vh - 2) / 2 : vh
      // Fit and Fill keep the margin (Settings › General) free around the photo in each pane;
      // Fill crops to the inset area. Other zoom levels use the whole pane; the
      // margin shows only once panning reaches the photo's edge.
      let margin = min(Appearance.canvasMargin * s, max(min(paneW, paneH) / 2 - 16 * s, 0))
      let innerW = paneW - 2 * margin, innerH = paneH - 2 * margin
      let fit = min(innerW / sourceSize.width, innerH / sourceSize.height)
      let cover = max(innerW / sourceSize.width, innerH / sourceSize.height)
      if abs(canvas.fitZoom - fit) > 1e-9 || abs(canvas.fillZoom - cover) > 1e-9 {
        DispatchQueue.main.async { canvas.fitZoom = fit; canvas.fillZoom = cover }
      }
      let zTarget = canvas.fill ? cover : canvas.zoom ?? fit
      let insetTarget = canvas.fill || canvas.zoom == nil ? margin : 0
      // The image keeps covering the pane at every zoom: panning stops at its edges. A centre
      // left outside by a resize is corrected here; the next pan or zoom stores it.
      paneSize = CGSize(width: paneW, height: paneH)
      paneMargin = margin
      let drawn = clampedCentre(canvas.center, zoom: zTarget)
      drawnCentre = drawn
      let pose = animatedPose(ViewPose(z: zTarget, c: drawn, inset: insetTarget), canvas: canvas)
      shownPose = pose
      zooming = zoomAnim != nil
      let z = pose.z, inset = pose.inset, cx = pose.c.x, cy = pose.c.y
      let w = sourceSize.width * z, h = sourceSize.height * z
      let pw = paneW / s, ph = paneH / s, gap = 2 / s
      panes = sideBySide ? [CGRect(x: 0, y: 0, width: pw, height: ph), CGRect(x: pw + gap, y: 0, width: pw, height: ph)]
        : stackedPanes ? [CGRect(x: 0, y: 0, width: pw, height: ph), CGRect(x: 0, y: ph + gap, width: pw, height: ph)]
        : [CGRect(x: 0, y: 0, width: pw, height: ph)]
      if canvas.fill, canvas.zoom != cover || drawn.x != canvas.center.x || drawn.y != canvas.center.y {
        DispatchQueue.main.async { if canvas.fill { canvas.zoom = cover; canvas.center = drawn } }
      }
      enc.setVertexBytes([Float](repeating: 0, count: 4), length: 16, index: 0)
      var proof: Int32 = proofLUT == nil ? 0 : proofWarn ? 2 : 1
      enc.setFragmentTexture(proofLUT ?? noLUT, index: 1)
      enc.setFragmentBytes(&proof, length: MemoryLayout<Int32>.size, index: 1)

      /// `area` is the part whose source region is reported and covered by sharp tiles; the split
      /// view passes the whole view so moving the divider does not ask for new tiles.
      /// `clipY` is in device pixels, y up.
      func draw(_ buffer: PixelBuffer, paneX: Double, paneY: Double = 0, clip: ClosedRange<Double>,
                clipY: ClosedRange<Double>? = nil, area: ClosedRange<Double>? = nil, isImage: Bool = false) {
        let x0 = paneX + paneW / 2 - cx * w
        let y0 = paneY + paneH / 2 - (1 - cy) * h
        let lo = max(clip.lowerBound, 0, paneX + inset), hi = min(clip.upperBound, vw, paneX + paneW - inset)
        let ylo = max(clipY?.lowerBound ?? 0, 0, paneY + inset), yhi = min(clipY?.upperBound ?? vh, vh, paneY + paneH - inset)
        guard hi - lo >= 1, yhi - ylo >= 1 else { return }
        // The scissor rect has a top-left origin.
        enc.setScissorRect(MTLScissorRect(
          x: Int(lo.rounded()), y: Int((vh - yhi).rounded()), width: Int((hi - lo).rounded()), height: Int((yhi - ylo).rounded())))
        enc.setRenderPipelineState(pipeline)
        let visible = CGRect(x: lo / s, y: ylo / s, width: (hi - lo) / s, height: (yhi - ylo) / s)
        // `region` is in source pixels, y down; the quad is in device pixels, y up.
        func quad(_ buffer: PixelBuffer, region: CGRect, isImage: Bool = false) {
          var tex = upload(buffer)
          if isImage { if tex == nil { tex = lastImageTexture } else { lastImageTexture = tex } }
          guard let tex else { return }
          let qx = x0 + region.minX * z, qy = y0 + h - region.maxY * z
          let qw = region.width * z, qh = region.height * z
          var rect = SIMD4<Float>(Float(qx / vw * 2 - 1), Float(qy / vh * 2 - 1), Float(qw / vw * 2), Float(qh / vh * 2))
          enc.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
          enc.setFragmentTexture(tex, index: 0)
          // Pixel-exact look once a texel covers two or more device pixels.
          let texelScale = qw / Double(buffer.width)
          enc.setFragmentSamplerState(texelScale >= 2 ? nearestSampler : linearSampler, index: 0)
          enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
          let r = CGRect(x: qx / s, y: qy / s, width: qw / s, height: qh / s)
          newDrawn.append((visible.intersection(r), r, buffer, region))
        }
        let whole = CGRect(origin: .zero, size: sourceSize)
        quad(buffer, region: whole, isImage: isImage)
        let alo = max(area?.lowerBound ?? lo, 0), ahi = min(area?.upperBound ?? hi, vw)
        // The split views report the whole view height too; a stacked pane only its own.
        let aylo = area == nil ? ylo : 0, ayhi = area == nil ? yhi : vh
        let seen = CGRect(x: (alo - x0) / z, y: (y0 + h - ayhi) / z, width: (ahi - alo) / z, height: (ayhi - aylo) / z).intersection(whole)
        if isImage {
          imageRect = CGRect(x: x0 / s, y: y0 / s, width: w / s, height: h / s)
          if !zooming, seen != lastViewport, !seen.isEmpty {
            lastViewport = seen
            onViewport?(seen)
          }
        } else if !zooming, seen != lastCompareViewport, !seen.isEmpty {
          lastCompareViewport = seen
          onCompareViewport?(seen)
        }
        // Draw only the tiles on this side of the divider; the rest stay cached for when it moves.
        let shown = CGRect(x: (lo - x0) / z, y: (y0 + h - yhi) / z, width: (hi - lo) / z, height: (yhi - ylo) / z)
        for d in isImage ? details : compareDetails where d.region.intersects(shown) { quad(d.buffer, region: d.region) }
        // The previous image over everything, fading out.
        if isImage, let from = fadeFrom {
          let t = (CACurrentMediaTime() - fadeStart) / Self.fadeDuration
          if t >= 1 || from === lastImageTexture {
            fadeFrom = nil
          } else {
            var rect = SIMD4<Float>(Float(x0 / vw * 2 - 1), Float(y0 / vh * 2 - 1), Float(w / vw * 2), Float(h / vh * 2))
            var alpha = Float(1 - t)
            enc.setRenderPipelineState(fadePipeline)
            enc.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
            enc.setFragmentTexture(from, index: 0)
            enc.setFragmentBytes(&alpha, length: MemoryLayout<Float>.size, index: 0)
            enc.setFragmentSamplerState(linearSampler, index: 0)
            enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            fadeNeedsFrame = true
          }
        }
      }

      /// Solid rectangle in device pixels (bottom-left origin).
      func fill(_ x: Double, _ y: Double, _ fw: Double, _ fh: Double, _ grey: Float) {
        var rect = SIMD4<Float>(Float(x / vw * 2 - 1), Float(y / vh * 2 - 1), Float(fw / vw * 2), Float(fh / vh * 2))
        var color = SIMD4<Float>(grey, grey, grey, 1)
        enc.setVertexBytes(&rect, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        enc.setFragmentBytes(&color, length: MemoryLayout<SIMD4<Float>>.size, index: 0)
        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
      }

      func line(at x: Double) {
        let lw = max(2, s)
        enc.setScissorRect(MTLScissorRect(x: 0, y: 0, width: Int(vw), height: Int(vh)))
        enc.setRenderPipelineState(solidPipeline)
        fill(x - lw / 2, 0, lw, vh, 0.92)
      }

      func row(at y: Double) {
        let lw = max(2, s)
        enc.setScissorRect(MTLScissorRect(x: 0, y: 0, width: Int(vw), height: Int(vh)))
        enc.setRenderPipelineState(solidPipeline)
        fill(0, y - lw / 2, vw, lw, 0.92)
      }

      /// Round handle at the middle of the divider, drawn as pixel rows: left/right arrows on a
      /// vertical divider, up/down arrows on a horizontal one (`y` given).
      func knob(at x: Double, y: Double? = nil) {
        let r = Self.knobRadius * s * (dividerHot ? 1.15 : 1), cy = y ?? vh / 2
        let step = max(1, s / 2)
        func disc(_ radius: Double, _ grey: Float) {
          var y = -radius
          while y < radius {
            let half = (radius * radius - (y + step / 2) * (y + step / 2)).squareRoot()
            fill(x - half, cy + y, 2 * half, step, grey)
            y += step
          }
        }
        disc(r + max(1, s), 0.12)
        disc(r, 0.92)
        // Arrows: triangles pointing out, built from columns.
        let ah = r * 0.42, aw = r * 0.34, gap = r * 0.14
        var t = 0.0
        while t < aw {
          let colH = ah * 2 * (t + step / 2) / aw
          if y == nil {
            fill(x - gap - aw + t, cy - colH / 2, step, colH, 0.15)
            fill(x + gap + aw - t - step, cy - colH / 2, step, colH, 0.15)
          } else {
            fill(x - colH / 2, cy - gap - aw + t, colH, step, 0.15)
            fill(x - colH / 2, cy + gap + aw - t - step, colH, step, 0.15)
          }
          t += step
        }
      }

      if let compare, sideBySide {
        draw(compare, paneX: 0, clip: 0...paneW)
        draw(image, paneX: paneW + 2, clip: (paneW + 2)...vw, isImage: true)
        line(at: paneW + 1)
      } else if let compare, stackedPanes {
        // Compare on top: y up, so its pane starts above the gap.
        draw(compare, paneX: 0, paneY: paneH + 2, clip: 0...vw, clipY: (paneH + 2)...vh)
        draw(image, paneX: 0, clip: 0...vw, clipY: 0...paneH, isImage: true)
        row(at: paneH + 1)
      } else if let compare, mode == .split {
        let inset = min(CanvasMTKView.dividerInset * s, vw / 2)
        let sx = min(max(canvas.split * vw, inset), vw - inset).rounded()
        draw(compare, paneX: 0, clip: 0...sx, area: 0...vw)
        draw(image, paneX: 0, clip: sx...vw, area: 0...vw, isImage: true)
        line(at: sx)
        knob(at: sx)
        divider = sx / s
      } else if let compare, mode == .splitStacked {
        // Before on top: y up, so the compare image takes the part above the divider.
        let inset = min(CanvasMTKView.dividerInset * s, vh / 2)
        let sy = (vh - min(max(canvas.splitY * vh, inset), vh - inset)).rounded()
        draw(compare, paneX: 0, clip: 0...vw, clipY: sy...vh, area: 0...vw)
        draw(image, paneX: 0, clip: 0...vw, clipY: 0...sy, area: 0...vw, isImage: true)
        row(at: sy)
        knob(at: vw / 2, y: sy)
        dividerRow = sy / s
      } else {
        draw(image, paneX: 0, clip: 0...vw, isImage: true)
      }
      lastImageRect = imageRect
    }
    drawn = newDrawn
    if fadeNeedsFrame || zooming {
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.0 / 60) { [weak view] in (view as? CanvasMTKView)?.requestDraw() }
    }
    dividerX = divider
    dividerY = dividerRow
    enc.endEncoding()
    if (view.layer as? CAMetalLayer)?.presentsWithTransaction == true {
      // Shown with the current Core Animation transaction: wait until the GPU has the work, then present here.
      cmd.commit()
      cmd.waitUntilScheduled()
      drawable.present()
    } else {
      cmd.present(drawable)
      cmd.commit()
    }
  }

  /// Display P3 value of the drawn pixel under `point` (view points).
  func probe(at point: NSPoint) -> ProbeReading? {
    guard let hit = drawn.last(where: { $0.visible.contains(point) }), hit.rect.width > 0 else { return nil }
    let u = (point.x - hit.rect.minX) / hit.rect.width
    let v = 1 - (point.y - hit.rect.minY) / hit.rect.height
    let b = hit.buffer
    let px = min(max(Int(u * Double(b.width)), 0), b.width - 1)
    let py = min(max(Int(v * Double(b.height)), 0), b.height - 1)
    let sx = hit.source.minX + u * hit.source.width, sy = hit.source.minY + v * hit.source.height
    let i = (py * b.width + px) * 4
    let rgb: [Double] = (0..<3).map { c in
      b.bytesPerComponent == 2
        ? Double(halfToFloat(b.data.assumingMemoryBound(to: UInt16.self)[i + c]))
        : Double(b.floats[i + c])
    }
    return ProbeReading(
      x: min(Int(sx), Int(sourceSize.width) - 1),
      y: min(Int(sy), Int(sourceSize.height) - 1), rgb: rgb)
  }
}
