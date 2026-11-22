import AppKit
import SwiftUI

/// Window layout remembered across launches (panel widths, folded modules, compare mode,
/// window frame), and the resets the Settings window offers.
enum Layout {
  static let rememberKey = "rememberLayout"
  static let windowName = "SpektraLabMain"  // old autosave name, only cleared now
  /// Window frame (NSWindow.frameDescriptor), saved by WindowFrameSaver.
  static let frameKey = "windowFrame"
  static let defaultSize = CGSize(width: 1500, height: 950)

  /// Everything "화면 배치 초기화" clears. Favorites and photo edits are not layout.
  static let keys = [
    "pickerOpen", Panels.recipeBarKey, Panels.inspectorKey, "pickerWidth", "inspectorWidth", "inspectorCollapsed", "inspectorMore", "compareMode",
    "pickerCard.film", "pickerCard.paper", "pickerGap.film", "pickerGap.paper",
    "pickerExpanded.film", "pickerExpanded.paper", "NSWindow Frame \(windowName)", "NSWindow Frame main", frameKey,
  ]
  /// Preferences "모든 설정 초기화" clears on top of the layout.
  static let preferenceKeys = [L10n.key, Appearance.key, Performance.key, "exportFormat", Splash.enabledKey, rememberKey, EditModel.hoverKey, EditModel.scrubPauseKey, EditModel.sliderPauseKey,
                                CachePolicy.daysKey, CachePolicy.limitKey, Appearance.backdropKey, Appearance.marginKey, Appearance.marginSizeKey,
                                ProcessScope.styleKey, CanvasMTKView.deepColorKey] + SoftProof.keys + ExportOptions.keys + FilmPanel.keys + OSD.keys

  static var remember: Bool { UserDefaults.standard.object(forKey: rememberKey) as? Bool ?? true }

  /// Snapshot runs set panels and compare modes for their pictures; those must not stick.
  static var persists: Bool { Snapshotter.shared.directory == nil }

  /// Called once before any view reads the layout: with remembering off, each launch starts fresh.
  static func prepareForLaunch() {
    if !remember { clear(keys) }
  }

  static func bool(_ key: String) -> Bool? {
    persists ? UserDefaults.standard.object(forKey: key) as? Bool : nil
  }

  static func string(_ key: String) -> String? {
    persists ? UserDefaults.standard.string(forKey: key) : nil
  }

  static func save(_ value: Any, forKey key: String) {
    if persists { UserDefaults.standard.set(value, forKey: key) }
  }

  /// Puts the open window back to the first-launch layout.
  static func reset(model: EditModel) {
    clear(keys)
    model.pickerOpen = true
    model.compareMode = .off
    UserDefaults.standard.removeObject(forKey: "pickerOpen")
    UserDefaults.standard.removeObject(forKey: "compareMode")
    UserDefaults.standard.removeObject(forKey: HistoryTimeline.shownKey)
    if let window = WindowFrameSaver.window {
      let screen = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? .zero
      let size = CGSize(width: min(defaultSize.width, screen.width), height: min(defaultSize.height, screen.height))
      window.setFrame(CGRect(x: screen.midX - size.width / 2, y: screen.midY - size.height / 2,
                             width: size.width, height: size.height), display: true, animate: true)
    }
  }

  /// Layout plus every preference; favorites, presets and per-photo edits stay.
  static func resetAll(model: EditModel) {
    clear(preferenceKeys)
    model.exportFormat = .tiff16
    UserDefaults.standard.removeObject(forKey: "exportFormat")
    reset(model: model)
  }

  private static func clear(_ list: [String]) {
    for key in list { UserDefaults.standard.removeObject(forKey: key) }
  }
}

/// Remembers the main window's size and place. SwiftUI's own autosave for the Window scene and
/// a second AppKit autosave name used to fight (each restored its own, often stale, frame at
/// launch), so the frame is saved here by hand on every move and resize and on close, and put back
/// once SwiftUI has placed the window.
struct WindowFrameSaver: NSViewRepresentable {
  static weak var window: NSWindow?

  func makeNSView(context: Context) -> NSView { Probe() }
  func updateNSView(_ nsView: NSView, context: Context) {}

  private final class Probe: NSView {
    private var tokens: [NSObjectProtocol] = []

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      guard let window, WindowFrameSaver.window !== window else { return }
      WindowFrameSaver.window = window
      guard Layout.persists else { return }
      if !window.frameAutosaveName.isEmpty { window.setFrameAutosaveName("") }
      restore(window)
      DispatchQueue.main.async { [weak self, weak window] in
        guard let self, let window else { return }
        restore(window)
        Self.test(window)
        let centre = NotificationCenter.default
        for name in [NSWindow.didMoveNotification, NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification,
                     NSWindow.willCloseNotification] {
          tokens.append(centre.addObserver(forName: name, object: window, queue: .main) { [weak window] _ in
            if let window { Self.save(window) }
          })
        }
        tokens.append(centre.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak window] _ in
          if let window { Self.save(window) }
        })
      }
    }

    private func restore(_ window: NSWindow) {
      guard let saved = UserDefaults.standard.string(forKey: Layout.frameKey) else { return }
      window.setFrame(from: saved)
    }

    private static func save(_ window: NSWindow) {
      guard Layout.persists, !window.styleMask.contains(.fullScreen), !window.isMiniaturized else { return }
      UserDefaults.standard.set(window.frameDescriptor, forKey: Layout.frameKey)
    }

    /// PHOTOEMUL_FRAMETEST=log prints the frame once placed; "x y w h" also moves the window there and
    /// closes it (as the close button would), to check the frame survives a relaunch.
    private static var tested = false
    private static func test(_ window: NSWindow) {
      guard let arg = ProcessInfo.processInfo.environment["PHOTOEMUL_FRAMETEST"], !tested else { return }
      tested = true
      DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
        print("frametest placed", NSStringFromRect(window.frame))
        let n = arg.split(separator: " ").compactMap { Double($0) }
        guard n.count == 4 else { return }
        window.setFrame(CGRect(x: n[0], y: n[1], width: n[2], height: n[3]), display: true)
        window.performClose(nil)
      }
    }

    deinit { tokens.forEach(NotificationCenter.default.removeObserver) }
  }
}
