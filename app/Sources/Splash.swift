import AppKit

/// Launch splash, design A "감광층 쌓기": the icon's cyan, magenta and yellow layers light up
/// one per real loading stage, then a beam passes through them. Built from Core Animation
/// layers so it keeps animating while the main thread is busy setting the engine up.
/// Skipped when the last launch was ready in under a second.
enum Splash {
  enum Stage: Int { case renderer, films, papers, session }

  static let enabledKey = "showSplash"
  private static let durationKey = "launchSeconds"
  private static var window: SplashWindow?
  private static var started = 0.0
  private static var stage = Stage.renderer
  private static var active = false
  private static var finished = false
  /// SPLASH_SNAPSHOT=1 with --snapshot: always show, and save a picture per stage.
  private static var captureDirectory: URL?

  static func begin() {
    started = CFAbsoluteTimeGetCurrent()
    if let dir = Snapshotter.shared.directory {
      guard ProcessInfo.processInfo.environment["SPLASH_SNAPSHOT"] != nil else { return }
      captureDirectory = dir
    } else if UserDefaults.standard.object(forKey: enabledKey) as? Bool == false {
      return
    }
    active = true
    // A first launch has no timing yet: wait and show only if a stage is slow.
    if captureDirectory != nil || UserDefaults.standard.double(forKey: durationKey) >= 1 { show() }
    update()
  }

  static func advance(_ next: Stage) {
    guard active else { return }
    stage = next
    if window == nil, CFAbsoluteTimeGetCurrent() - started > 0.6 { show() }
    update()
  }

  /// The first picture is up (or there is none to load): finish and fade out.
  static func finish() {
    guard active, !finished else { return }
    finished = true
    let elapsed = CFAbsoluteTimeGetCurrent() - started
    if captureDirectory == nil { UserDefaults.standard.set(elapsed, forKey: durationKey) }
    guard let window else { return }
    window.show(step: tr("준비 완료", "Ready"), progress: 1, lit: 3, beam: true)
    capture("splash_5_done")
    // Stay long enough to be read, then let the beam finish before fading.
    let hold = max(0.8 - elapsed, 0) + (reduceMotion ? 0.2 : 0.7)
    DispatchQueue.main.asyncAfter(deadline: .now() + hold) {
      window.dismiss(animated: !reduceMotion)
      Self.window = nil
    }
  }

  private static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

  private static func show() {
    let w = SplashWindow(reduceMotion: reduceMotion)
    window = w
    w.orderFrontRegardless()
    // Never left up for good, whatever goes wrong while loading.
    DispatchQueue.main.asyncAfter(deadline: .now() + 20) { finish() }
  }

  private static func update() {
    guard let window else { return }
    let text: String
    let progress: Double
    switch stage {
    case .renderer: (text, progress) = (tr("Metal 렌더러 준비 중…", "Preparing the Metal renderer…"), 0.06)
    case .films:
      (text, progress) = (tr("필름 프로필 \(Catalog.films.count)종 읽는 중…", "Reading \(Catalog.films.count) film profiles…"), 0.38)
    case .papers: (text, progress) = (tr("인화지 · 프리셋 불러오는 중…", "Loading papers and presets…"), 0.62)
    case .session:
      (text, progress) = launch.input == nil
        ? (tr("작업 공간 여는 중…", "Opening the workspace…"), 0.84)
        : (tr("사진과 지난 편집 복원 중…", "Restoring the photo and last edit…"), 0.84)
    }
    window.show(step: text, progress: progress, lit: stage.rawValue, beam: false)
    capture("splash_\(stage.rawValue + 1)")
  }

  private static func capture(_ name: String) {
    guard let dir = captureDirectory, let window, let png = window.png() else { return }
    try? png.write(to: dir.appendingPathComponent(name + ".png"))
  }
}

final class SplashWindow: NSPanel {
  static let size = CGSize(width: 440, height: 286)
  private let reduceMotion: Bool
  private let root = CALayer()
  private let layers: [CAShapeLayer]  // cyan, magenta, yellow: bottom first, as they light
  private let beam = CAGradientLayer()
  private let step = CATextLayer()
  private let barFill = CAGradientLayer()
  private let percent = CATextLayer()

  private static let cyan = CGColor(srgbRed: 0.098, green: 0.776, blue: 0.941, alpha: 1)
  private static let magenta = CGColor(srgbRed: 0.941, green: 0.208, blue: 0.604, alpha: 1)
  private static let yellow = CGColor(srgbRed: 0.969, green: 0.824, blue: 0.118, alpha: 1)
  private static let muted = CGColor(srgbRed: 0.56, green: 0.573, blue: 0.604, alpha: 1)
  private static let faint = CGColor(srgbRed: 0.427, green: 0.439, blue: 0.475, alpha: 1)
  private static let barWidth = size.width - 56

  init(reduceMotion: Bool) {
    self.reduceMotion = reduceMotion
    layers = [Self.cyan, Self.magenta, Self.yellow].map { color in
      let l = CAShapeLayer()
      l.fillColor = color
      l.strokeColor = color
      l.lineWidth = 7  // rounds the corners like the icon's plates
      l.lineJoin = .round
      return l
    }
    let screen = NSScreen.main?.visibleFrame ?? CGRect(origin: .zero, size: Self.size)
    super.init(contentRect: CGRect(x: screen.midX - Self.size.width / 2, y: screen.midY - Self.size.height / 2 + 60,
                                   width: Self.size.width, height: Self.size.height),
               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    isOpaque = false
    backgroundColor = .clear
    hasShadow = true
    level = .floating
    isReleasedWhenClosed = false
    collectionBehavior = [.canJoinAllSpaces, .transient]

    let view = NSView(frame: CGRect(origin: .zero, size: Self.size))
    view.wantsLayer = true
    contentView = view
    build(in: view.layer!)
  }

  private func build(in host: CALayer) {
    let scale = NSScreen.main?.backingScaleFactor ?? 2
    root.frame = host.bounds
    root.isGeometryFlipped = true  // lay out from the top like the mock
    root.backgroundColor = CGColor(srgbRed: 0.106, green: 0.11, blue: 0.122, alpha: 1)
    root.cornerRadius = 12
    root.borderWidth = 1
    root.borderColor = CGColor(gray: 1, alpha: 0.1)
    root.masksToBounds = true
    host.addSublayer(root)

    // Three plates seen at an angle, yellow on top and cyan at the bottom.
    let stack = CALayer()
    stack.frame = CGRect(x: (Self.size.width - 120) / 2, y: 30, width: 120, height: 110)
    root.addSublayer(stack)
    for (i, plate) in layers.reversed().enumerated() {  // yellow first so cyan draws on top
      let top = CGFloat(i) * 22 + 4
      let path = CGMutablePath()
      path.move(to: CGPoint(x: 60, y: top))
      path.addLine(to: CGPoint(x: 112, y: top + 27))
      path.addLine(to: CGPoint(x: 60, y: top + 54))
      path.addLine(to: CGPoint(x: 8, y: top + 27))
      path.closeSubpath()
      plate.path = path
      plate.opacity = 0.12
      stack.addSublayer(plate)
    }
    beam.colors = [CGColor(gray: 1, alpha: 0.95), CGColor(gray: 1, alpha: 0)]
    beam.startPoint = CGPoint(x: 0.5, y: 0)
    beam.endPoint = CGPoint(x: 0.5, y: 1)
    beam.anchorPoint = CGPoint(x: 0.5, y: 0)
    beam.frame = CGRect(x: 59, y: -18, width: 2, height: 0)
    stack.addSublayer(beam)

    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    let name = NSMutableAttributedString(string: "PhotoEmul", attributes: [
      .font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: NSColor(white: 0.9, alpha: 1)])
    name.append(NSAttributedString(string: "  " + version, attributes: [
      .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium), .foregroundColor: NSColor(cgColor: Self.muted)!]))
    root.addSublayer(text(name, frame: CGRect(x: 20, y: 156, width: Self.size.width - 40, height: 30), scale: scale))

    step.frame = CGRect(x: 20, y: 194, width: Self.size.width - 40, height: 18)
    configure(step, scale: scale)
    root.addSublayer(step)

    let track = CALayer()
    track.frame = CGRect(x: 28, y: 226, width: Self.barWidth, height: 3)
    track.backgroundColor = CGColor(gray: 1, alpha: 0.08)
    track.cornerRadius = 1.5
    track.masksToBounds = true
    root.addSublayer(track)
    barFill.colors = [Self.cyan, Self.magenta, Self.yellow]
    barFill.startPoint = CGPoint(x: 0, y: 0.5)
    barFill.endPoint = CGPoint(x: 1, y: 0.5)
    barFill.anchorPoint = .zero
    barFill.frame = CGRect(x: 0, y: 0, width: 0, height: 3)
    track.addSublayer(barFill)

    let foot = NSAttributedString(string: "spektrafilm · GPLv3", attributes: footAttributes)
    let left = text(foot, frame: CGRect(x: 28, y: 246, width: 240, height: 16), scale: scale)
    left.alignmentMode = .left
    root.addSublayer(left)
    percent.frame = CGRect(x: Self.size.width - 28 - 80, y: 246, width: 80, height: 16)
    configure(percent, scale: scale)
    percent.alignmentMode = .right
    root.addSublayer(percent)
  }

  private var footAttributes: [NSAttributedString.Key: Any] {
    [.font: NSFont.monospacedSystemFont(ofSize: 11, weight: .regular), .foregroundColor: NSColor(cgColor: Self.faint)!]
  }

  private func configure(_ l: CATextLayer, scale: CGFloat) {
    l.contentsScale = scale
    l.alignmentMode = .center
    l.truncationMode = .end
  }

  private func text(_ s: NSAttributedString, frame: CGRect, scale: CGFloat) -> CATextLayer {
    let l = CATextLayer()
    l.frame = frame
    configure(l, scale: scale)
    l.string = s
    return l
  }

  /// Draws the new stage at once: the caller may block the main thread right after.
  func show(step text: String, progress: Double, lit: Int, beam showBeam: Bool) {
    CATransaction.begin()
    CATransaction.setAnimationDuration(reduceMotion ? 0 : 0.4)
    step.string = NSAttributedString(string: text, attributes: [
      .font: NSFont.systemFont(ofSize: 12.5), .foregroundColor: NSColor(cgColor: Self.muted)!])
    percent.string = NSAttributedString(string: "\(Int(progress * 100))%", attributes: footAttributes)
    for (i, plate) in layers.enumerated() { plate.opacity = i < lit ? 0.92 : 0.12 }
    barFill.bounds.size.width = Self.barWidth * progress
    if showBeam, !reduceMotion {
      CATransaction.setAnimationDuration(0.5)
      beam.bounds.size.height = 120
    }
    CATransaction.commit()
    displayIfNeeded()
    CATransaction.flush()
  }

  func dismiss(animated: Bool) {
    guard animated else { return close() }
    NSAnimationContext.runAnimationGroup({ ctx in
      ctx.duration = 0.25
      animator().alphaValue = 0
    }, completionHandler: { self.close() })
  }

  /// The splash as it stands (final values, not mid-animation), for snapshot runs.
  func png() -> Data? {
    let scale = 2
    let w = Int(Self.size.width) * scale, h = Int(Self.size.height) * scale
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!,
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    // The window's host layer is not flipped; a bitmap context is, so turn it over first.
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: CGFloat(scale), y: -CGFloat(scale))
    root.render(in: ctx)
    guard let image = ctx.makeImage() else { return nil }
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
  }
}
