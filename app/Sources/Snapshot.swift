// PhotoEmul - native editor for spektrafilm (GPL-3.0-or-later)
// `--snapshot <dir>`: drives the UI through a few states and saves window images.
// Works without the Screen Recording permission because the app draws itself.

import AppKit
import SwiftUI

final class Snapshotter {
  static let shared = Snapshotter()
  static var savedExpanded: String?
  static var madeTestPreset = false
  static var saved42: [Any?] = []
  static var saved43: Any?
  static var saved44: ParamValue?
  static var saved45: [Any?] = []
  static var saved41: (style: String?, width: Double?) = (nil, nil)
  /// The editing window; the launch splash panel is never what a snapshot means.
  static var mainWindow: NSWindow? { NSApp.windows.first { $0.isVisible && !($0 is SplashWindow) } }

  var directory: URL?
  weak var model: EditModel?
  weak var canvas: CanvasState?
  private var started = false

  /// A step changes UI state, waits, then saves `name.png`.
  struct Step {
    let name: String
    let wait: Double
    let action: (EditModel, CanvasState) -> Void
  }

  var steps: [Step] = [
    Step(name: "01_main", wait: 2) { m, _ in m.pickerOpen = true },
    Step(name: "02_film_portra400", wait: 4) { m, _ in
      if let i = Catalog.films.firstIndex(of: "kodak_portra_400") { m.setAndCommit("film", .int(i)) }
    },
    Step(name: "03_paper_tab", wait: 6) { m, _ in m.sidebarTab = .paper; m.pickerOpen = true },
    // The four module graphs, in use and not, rendered off screen (no window step needed).
    Step(name: "03b_graphs_unused", wait: 0.3) { m, _ in MainActor.assumeIsolated { Snapshotter.renderGraphs(m.values, "03c_graphs") } },
    // Caught mid-render: the progress pill and the corner marks on the tile in progress.
    Step(name: "04a_zoom_progress", wait: 1.2) { _, c in c.setZoom(1) },
    Step(name: "04_zoom_100", wait: 5) { _, c in c.setZoom(1) },
    // Zoomed in, an edit re-renders only the visible area; panning away renders the new area.
    Step(name: "04b_zoom_edit", wait: 5) { m, _ in m.setAndCommit("filmExposureEv", .double(0.3)) },
    Step(name: "04c_zoom_pan", wait: 5) { _, c in c.center = CGPoint(x: 0.2, y: 0.8) },
    // Zoom in a little (half-size tiles), in, back out, then nudge: done tiles carry over.
    Step(name: "15a_zoom_mid", wait: 1.5) { _, c in c.setZoom(0.45) },
    Step(name: "15b_zoom_in", wait: 1.5) { _, c in c.setZoom(1) },
    Step(name: "15c_zoom_back", wait: 0.8) { _, c in c.setZoom(0.45) },
    Step(name: "15d_zoom_mid_done", wait: 6) { _, _ in },
    Step(name: "15e_zoom_in_pan", wait: 1.5) { _, c in c.setZoom(1) },
    Step(name: "15f_nudge", wait: 0.6) { _, c in c.center = CGPoint(x: c.center.x + 0.02, y: c.center.y) },
    // Back and forth between zooms: after the first round nothing should render again.
    Step(name: "16_0_z100", wait: 0.6) { _, c in c.setZoom(1) },
    Step(name: "16_0_z100_end", wait: 8) { _, _ in },
    Step(name: "16_1_z45", wait: 0.6) { _, c in c.setZoom(0.45) },
    Step(name: "16_1_z45_end", wait: 8) { _, _ in },
    Step(name: "16_2_z100", wait: 0.6) { _, c in c.setZoom(1) },
    Step(name: "16_2_z100_end", wait: 8) { _, _ in },
    Step(name: "16_3_z45", wait: 0.6) { _, c in c.setZoom(0.45) },
    Step(name: "16_3_z45_end", wait: 8) { _, _ in },
    Step(name: "16_4_z100", wait: 0.6) { _, c in c.setZoom(1) },
    Step(name: "16_4_z100_end", wait: 8) { _, _ in },
    Step(name: "16_5_z200", wait: 0.6) { _, c in c.setZoom(2) },
    Step(name: "16_5_z200_end", wait: 8) { _, _ in },
    Step(name: "16_6_z100", wait: 0.6) { _, c in c.setZoom(1) },
    Step(name: "16_6_z100_end", wait: 8) { _, _ in },
    Step(name: "16_7_z45", wait: 0.6) { _, c in c.setZoom(0.45) },
    Step(name: "16_7_z45_end", wait: 8) { _, _ in },
    Step(name: "17_split_on", wait: 1) { m, c in
      if let i = Catalog.films.firstIndex(of: "fujifilm_velvia_100") ?? Catalog.films.indices.last { m.compareBase = .film(i) }
      m.compareMode = .split; c.setZoom(0.45)
    },
    Step(name: "17_0_z45", wait: 0.6) { _, c in c.setZoom(0.45) },
    Step(name: "17_0_z45_end", wait: 8) { _, _ in },
    Step(name: "17_1_z100", wait: 0.6) { _, c in c.setZoom(1) },
    Step(name: "17_1_z100_end", wait: 8) { _, _ in },
    Step(name: "17_2_z45", wait: 0.6) { _, c in c.setZoom(0.45) },
    Step(name: "17_2_z45_end", wait: 8) { _, _ in },
    Step(name: "17_3_z100", wait: 0.6) { _, c in c.setZoom(1) },
    Step(name: "17_3_z100_end", wait: 8) { _, _ in },
    Step(name: "17_4_z45", wait: 0.6) { _, c in c.setZoom(0.45) },
    Step(name: "17_4_z45_end", wait: 8) { _, _ in },
    Step(name: "17_div_left", wait: 0.6) { _, c in c.split = 0.25 },
    Step(name: "17_div_left_end", wait: 8) { _, _ in },
    Step(name: "17_div_back", wait: 0.6) { _, c in c.split = 0.5 },
    Step(name: "17_div_back_end", wait: 3) { _, _ in },
    Step(name: "18_sbs_on", wait: 1) { m, c in m.compareMode = .sideBySide; c.setZoom(0.45) },
    Step(name: "18_0_z45", wait: 0.6) { _, c in c.setZoom(0.45) },
    Step(name: "18_0_z45_end", wait: 8) { _, _ in },
    Step(name: "18_1_z100", wait: 0.6) { _, c in c.setZoom(1) },
    Step(name: "18_1_z100_end", wait: 8) { _, _ in },
    Step(name: "18_2_z45", wait: 0.6) { _, c in c.setZoom(0.45) },
    Step(name: "18_2_z45_end", wait: 8) { _, _ in },
    Step(name: "18_3_z100", wait: 0.6) { _, c in c.setZoom(1) },
    Step(name: "18_3_z100_end", wait: 8) { _, _ in },
    Step(name: "18_4_z45", wait: 0.6) { _, c in c.setZoom(0.45) },
    Step(name: "18_4_z45_end", wait: 8) { _, _ in },
    Step(name: "23_cmp_orig", wait: 1) { m, c in m.compareBase = .original; m.compareMode = .sideBySide; c.setZoom(2); c.center = CGPoint(x: 0.3, y: 0.22) },
    Step(name: "23_cmp_orig_end", wait: 10) { m, _ in print("compare tiles: \(m.compareTiles.count) detail: \(m.detailTiles.count)") },
    Step(name: "23_cmp_film", wait: 1) { m, _ in
      if let i = Catalog.films.firstIndex(of: "fujifilm_velvia_100") ?? Catalog.films.indices.last { m.compareBase = .film(i) }
    },
    Step(name: "23_cmp_film_end", wait: 12) { m, _ in print("compare tiles: \(m.compareTiles.count) detail: \(m.detailTiles.count)") },
    Step(name: "23_cmp_split", wait: 1) { m, _ in m.compareMode = .split },
    Step(name: "23_cmp_split_end", wait: 10) { m, _ in print("compare tiles: \(m.compareTiles.count)") },
    Step(name: "19_big", wait: 12) { _, c in
      if let w = Snapshotter.mainWindow, let f = w.screen?.visibleFrame { w.setFrame(f, display: true) }
      c.setZoom(nil)
    },
    Step(name: "19_fit", wait: 0.6) { _, c in c.setZoom(nil) },
    Step(name: "19_fit_end", wait: 10) { _, _ in },
    Step(name: "19_z100", wait: 0.6) { _, c in c.setZoom(1) },
    Step(name: "19_z100_end", wait: 10) { _, _ in },
    Step(name: "19_fit2", wait: 0.6) { _, c in c.setZoom(nil) },
    Step(name: "19_fit2_end", wait: 10) { _, _ in },
    Step(name: "20_in", wait: 0.6) { _, c in c.setZoom(1); c.center = CGPoint(x: 0.5, y: 0.5) },
    Step(name: "20_in_end", wait: 12) { _, _ in },
    Step(name: "20_back", wait: 0.6) { _, c in c.center = CGPoint(x: 0.5, y: 0.5) },
    Step(name: "20_back_end", wait: 6) { _, _ in },
    Step(name: "20_pan_r", wait: 0.6) { _, c in c.center.x = min(c.center.x + 0.3, 1) },
    Step(name: "20_pan_r_end", wait: 12) { _, _ in },
    Step(name: "20_pan_d", wait: 0.6) { _, c in c.center.y = min(c.center.y + 0.3, 1) },
    Step(name: "20_pan_d_end", wait: 12) { _, _ in },
    Step(name: "20_home", wait: 0.6) { _, c in c.center = CGPoint(x: 0.5, y: 0.5) },
    Step(name: "20_home_end", wait: 4) { _, _ in },
    Step(name: "20_fit", wait: 0.6) { _, c in c.setZoom(nil) },
    Step(name: "20_fit_end", wait: 6) { _, _ in },
    Step(name: "20_z100", wait: 0.6) { _, c in c.setZoom(1); c.center = CGPoint(x: 0.8, y: 0.8) },
    Step(name: "20_z100_end", wait: 6) { _, _ in },
    Step(name: "20_fit2", wait: 0.6) { _, c in c.setZoom(nil) },
    Step(name: "20_fit2_end", wait: 4) { _, _ in },
    // Pointer resting on a B&W film card: proxy look on the canvas, tiles of the current look hidden.
    Step(name: "21_hover", wait: 3) { m, c in
      c.setZoom(nil)
      m.hover("film", Catalog.films.firstIndex { $0.lowercased().contains("acros") } ?? 0, inside: true)
    },
    Step(name: "21_hover_z100", wait: 4) { _, c in c.setZoom(1) },
    Step(name: "21_hover_out", wait: 2) { m, _ in
      m.hover("film", Catalog.films.firstIndex { $0.lowercased().contains("acros") } ?? 0, inside: false)
    },
    // Settings › Cache in a window of its own; the main window is captured as usual.
    Step(name: "22_cache", wait: 2) { _, _ in
      let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560), styleMask: [.titled], backing: .buffered, defer: false)
      w.contentView = NSHostingView(rootView: CacheSettings())
      w.orderFront(nil)
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        if let dir = Snapshotter.shared.directory { Snapshotter.capture(w, to: dir.appendingPathComponent("22_cache_settings.png")) }
        w.orderOut(nil)
      }
    },
    // Black-and-white stocks from the upstream dev branch, each on the photo at fit.
    Step(name: "24_doublex_2302", wait: 6) { m, c in
      c.setZoom(nil)
      m.sidebarTab = .film
      if let i = Catalog.films.firstIndex(of: "kodak_doublex") { m.set("film", .int(i)) }
      if let i = Catalog.papers.firstIndex(of: "kodak_2302") { m.set("paper", .int(i)) }
      m.commit()
    },
    Step(name: "24_trix400_2302", wait: 6) { m, _ in
      if let i = Catalog.films.firstIndex(of: "kodak_tri_x_400") { m.setAndCommit("film", .int(i)) }
    },
    Step(name: "24_portra400_2302", wait: 6) { m, _ in
      if let i = Catalog.films.firstIndex(of: "kodak_portra_400") { m.setAndCommit("film", .int(i)) }
    },
    Step(name: "24_doublex_endura", wait: 6) { m, _ in
      if let i = Catalog.films.firstIndex(of: "kodak_doublex") { m.set("film", .int(i)) }
      if let i = Catalog.papers.firstIndex(of: "kodak_portra_endura") { m.set("paper", .int(i)) }
      m.commit()
    },
    Step(name: "24_trix_reversal", wait: 6) { m, _ in
      if let i = Catalog.films.firstIndex(of: "kodak_trix") { m.setAndCommit("film", .int(i)) }
    },
    // Black-and-white stocks digitized from Ilford and Kodak datasheets, printed on 2302.
    Step(name: "25_delta100", wait: 6) { m, _ in
      if let i = Catalog.papers.firstIndex(of: "kodak_2302") { m.set("paper", .int(i)) }
      if let i = Catalog.films.firstIndex(of: "ilford_delta_100") { m.setAndCommit("film", .int(i)) }
    },
    Step(name: "25_delta400", wait: 6) { m, _ in
      if let i = Catalog.films.firstIndex(of: "ilford_delta_400") { m.setAndCommit("film", .int(i)) }
    },
    Step(name: "25_delta3200", wait: 6) { m, _ in
      if let i = Catalog.films.firstIndex(of: "ilford_delta_3200") { m.setAndCommit("film", .int(i)) }
    },
    Step(name: "25_fp4", wait: 6) { m, _ in
      if let i = Catalog.films.firstIndex(of: "ilford_fp4_plus") { m.setAndCommit("film", .int(i)) }
    },
    Step(name: "25_panf", wait: 6) { m, _ in
      if let i = Catalog.films.firstIndex(of: "ilford_pan_f_plus") { m.setAndCommit("film", .int(i)) }
    },
    Step(name: "25_xp2", wait: 6) { m, _ in
      if let i = Catalog.films.firstIndex(of: "ilford_xp2_super") { m.setAndCommit("film", .int(i)) }
    },
    Step(name: "25_tmax100", wait: 6) { m, _ in
      if let i = Catalog.films.firstIndex(of: "kodak_tmax_100") { m.setAndCommit("film", .int(i)) }
    },
    Step(name: "25_hp5", wait: 6) { m, _ in
      if let i = Catalog.films.firstIndex(of: "ilford_hp5_plus") { m.setAndCommit("film", .int(i)) }
    },
    // Fujifilm Eterna negatives digitized from the motion picture film manual, on 2383, then 3513DI.
    Step(name: "26_eterna_vivid500", wait: 6) { m, _ in
      if let i = Catalog.papers.firstIndex(of: "kodak_2383") { m.set("paper", .int(i)) }
      if let i = Catalog.films.firstIndex(of: "fujifilm_eterna_vivid_500") { m.setAndCommit("film", .int(i)) }
    },
    Step(name: "26_eterna_vivid160", wait: 6) { m, _ in
      if let i = Catalog.films.firstIndex(of: "fujifilm_eterna_vivid_160") { m.setAndCommit("film", .int(i)) }
    },
    Step(name: "26_eterna500", wait: 6) { m, _ in
      if let i = Catalog.films.firstIndex(of: "fujifilm_eterna_500") { m.setAndCommit("film", .int(i)) }
    },
    Step(name: "26_eterna400", wait: 6) { m, _ in
      if let i = Catalog.films.firstIndex(of: "fujifilm_eterna_400") { m.setAndCommit("film", .int(i)) }
    },
    Step(name: "26_eterna250", wait: 6) { m, _ in
      if let i = Catalog.films.firstIndex(of: "fujifilm_eterna_250") { m.setAndCommit("film", .int(i)) }
    },
    Step(name: "26_eterna250d", wait: 6) { m, _ in
      if let i = Catalog.films.firstIndex(of: "fujifilm_eterna_250d") { m.setAndCommit("film", .int(i)) }
    },
    Step(name: "26_vision500t_2383", wait: 6) { m, _ in
      if let i = Catalog.films.firstIndex(of: "kodak_vision3_500t") { m.setAndCommit("film", .int(i)) }
    },
    Step(name: "26_vision500t_3513", wait: 6) { m, _ in
      if let i = Catalog.papers.firstIndex(of: "fujifilm_eterna_cp_3513di") { m.setAndCommit("paper", .int(i)) }
    },
    Step(name: "26_eterna500_3513", wait: 6) { m, _ in
      if let i = Catalog.films.firstIndex(of: "fujifilm_eterna_500") { m.setAndCommit("film", .int(i)) }
    },
    Step(name: "27_portra_std", wait: 6) { m, _ in
      if let i = Catalog.papers.firstIndex(of: "kodak_portra_endura") { m.set("paper", .int(i)) }
      if let i = Catalog.films.firstIndex(of: "kodak_portra_400") { m.setAndCommit("film", .int(i)) }
    },
    Step(name: "27_portra_hot", wait: 6) { m, _ in
      m.setAndCommit("devTempDelta", .double(6))
    },
    Step(name: "27_portra_cold", wait: 6) { m, _ in
      m.setAndCommit("devTempDelta", .double(-6))
    },
    Step(name: "27_portra_long", wait: 6) { m, _ in
      m.set("devTempDelta", .double(0)); m.setAndCommit("devTimePercent", .double(160))
    },
    Step(name: "27_portra_aged", wait: 6) { m, _ in
      m.set("devTimePercent", .double(100)); m.set("agingStorage", .int(2)); m.setAndCommit("agingYears", .double(15))
    },
    Step(name: "27_portra_aged_hot", wait: 6) { m, _ in
      m.setAndCommit("agingStorage", .int(3))
    },
    Step(name: "27_velvia_std", wait: 6) { m, _ in
      m.set("agingYears", .double(0)); m.set("agingStorage", .int(2)); if let i = Catalog.films.firstIndex(of: "fujifilm_velvia_100") { m.setAndCommit("film", .int(i)) }
    },
    Step(name: "27_velvia_aged", wait: 6) { m, _ in
      m.setAndCommit("agingYears", .double(15))
    },
    Step(name: "27_polaroid_std", wait: 6) { m, _ in
      m.set("agingYears", .double(0)); if let i = Catalog.films.firstIndex(of: "polaroid_600") { m.setAndCommit("film", .int(i)) }
    },
    Step(name: "27_polaroid_cold", wait: 6) { m, _ in
      m.setAndCommit("devTempDelta", .double(-8))
    },
    Step(name: "27_polaroid_hot", wait: 6) { m, _ in
      m.setAndCommit("devTempDelta", .double(8))
    },
    Step(name: "28_fp100c_std", wait: 6) { m, _ in
      m.set("devTempDelta", .double(0)); m.set("devTimePercent", .double(100)); m.set("agingYears", .double(0)); if let i = Catalog.films.firstIndex(of: "fujifilm_fp100c") { m.setAndCommit("film", .int(i)) }
    },
    Step(name: "28_fp100c_cold", wait: 6) { m, _ in
      m.setAndCommit("devTempDelta", .double(-8))
    },
    // Divider is fixed to the view and kept 16 pt inside it, even zoomed in and panned.
    Step(name: "29_div_edge", wait: 4) { m, c in
      m.compareMode = .split; c.setZoom(1); c.center = CGPoint(x: 0.3, y: 0.5); c.split = 1
    },
    Step(name: "29_div_pan", wait: 4) { _, c in c.center = CGPoint(x: 0.7, y: 0.5); c.split = 0.6 },
    Step(name: "29_div_end", wait: 1) { m, c in m.compareMode = .off; c.setZoom(nil); c.split = 0.5 },
    Step(name: "30_reset_all", wait: 4) { m, _ in m.resetAll() },
    Step(name: "30_modified", wait: 4) { m, _ in m.setAndCommit("devTempDelta", .double(4)) },
    Step(name: "30_zoom_steps", wait: 2) { _, c in c.step(1); c.step(1) },
    Step(name: "30_zoom_fill", wait: 2) { _, c in c.chooseFill() },
    Step(name: "30_zoom_toggle", wait: 2) { _, c in c.setZoom(nil); c.toggle() },
    // Fill: fresh, after a pan at 100 %, panned to an edge, after a window resize and a margin change.
    Step(name: "40_fill", wait: 3) { _, c in c.setZoom(nil); c.chooseFill() },
    Step(name: "40_fill_after_pan", wait: 3) { _, c in c.setZoom(1); c.center = CGPoint(x: 0.1, y: 0.9); c.chooseFill() },
    Step(name: "40_fill_pan_edge", wait: 3) { _, c in c.chooseFill(); c.center = CGPoint(x: 0, y: 0) },
    Step(name: "40_fill_resize", wait: 3) { _, c in
      c.center = CGPoint(x: 0.5, y: 0.5); c.chooseFill(); Snapshotter.mainWindow?.setContentSize(NSSize(width: 1300, height: 1000))
    },
    Step(name: "40_fill_margin", wait: 3) { _, c in
      Snapshotter.mainWindow?.setContentSize(NSSize(width: 1600, height: 1000)); c.chooseFill()
      UserDefaults.standard.set(80.0, forKey: Appearance.marginSizeKey)
    },
    Step(name: "40_end", wait: 1) { _, c in
      UserDefaults.standard.removeObject(forKey: Appearance.marginSizeKey); c.setZoom(nil)
      if Snapshotter.madeTestPreset, let p = Presets.named("Ektar test") { Presets.delete(p); Snapshotter.madeTestPreset = false }
    },
    // Photo + curves cards: the thumbnail grows with the panel along with the curves.
    Step(name: "41_curves_300", wait: 3) { m, _ in
      let d = UserDefaults.standard
      Snapshotter.saved41 = (d.string(forKey: FilmPanel.cardStyleKey), d.object(forKey: "pickerWidth") as? Double)
      d.set("curves", forKey: FilmPanel.cardStyleKey); d.set(300.0, forKey: "pickerWidth"); m.pickerOpen = true
    },
    Step(name: "41_curves_600", wait: 3) { _, _ in UserDefaults.standard.set(600.0, forKey: "pickerWidth") },
    Step(name: "41_end", wait: 1) { _, _ in
      let d = UserDefaults.standard
      if let v = Snapshotter.saved41.style { d.set(v, forKey: FilmPanel.cardStyleKey) } else { d.removeObject(forKey: FilmPanel.cardStyleKey) }
      if let v = Snapshotter.saved41.width { d.set(v, forKey: "pickerWidth") } else { d.removeObject(forKey: "pickerWidth") }
    },
    // Photo info overlay and label opacity (Settings › 화면 정보); values are put back after.
    Step(name: "42_osd_info", wait: 2) { _, _ in
      let d = UserDefaults.standard
      Snapshotter.saved42 = OSD.keys.map { d.object(forKey: $0) }
      d.set(true, forKey: OSD.infoOnKey); d.removeObject(forKey: OSD.itemsKey)
      d.removeObject(forKey: OSD.backgroundKey); d.removeObject(forKey: OSD.opacityKey)
    },
    Step(name: "42_osd_faint", wait: 2) { m, _ in
      let d = UserDefaults.standard
      d.set(0.0, forKey: OSD.backgroundKey); d.set(0.6, forKey: OSD.opacityKey)
      d.set(OSD.Item.allCases.map(\.rawValue).joined(separator: ","), forKey: OSD.itemsKey)
      m.compareMode = .sideBySide
    },
    Step(name: "42_end", wait: 1) { m, _ in
      m.compareMode = .off
      for (key, value) in zip(OSD.keys, Snapshotter.saved42) {
        if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
      }
    },
    // Process negative: controls that don't apply are dimmed, then hidden (Settings › 도구 패널).
    Step(name: "43_proc2_dim", wait: 4) { m, _ in
      Snapshotter.saved43 = UserDefaults.standard.object(forKey: ProcessScope.styleKey)
      UserDefaults.standard.set(ProcessScope.Style.dim.rawValue, forKey: ProcessScope.styleKey)
      m.setAndCommit("process", .int(2))
    },
    Step(name: "43_proc2_hide", wait: 3) { _, _ in UserDefaults.standard.set(ProcessScope.Style.hide.rawValue, forKey: ProcessScope.styleKey) },
    Step(name: "43_end", wait: 1) { m, _ in
      m.setAndCommit("process", .int(0))
      if let v = Snapshotter.saved43 { UserDefaults.standard.set(v, forKey: ProcessScope.styleKey) }
      else { UserDefaults.standard.removeObject(forKey: ProcessScope.styleKey) }
    },
    Step(name: "30_end", wait: 1) { m, c in c.choose(1); c.setZoom(nil); m.setAndCommit("devTempDelta", .double(0)) },
    // Positive film with Print: the scan note by the mode and the paper picker marked unused.
    Step(name: "44_pos_paper", wait: 5) { m, _ in
      Snapshotter.saved44 = m.values["film"]
      if let i = Catalog.films.firstIndex(of: "polaroid_600") { m.setAndCommit("film", .int(i)) }
      m.sidebarTab = .paper; m.pickerOpen = true
    },
    Step(name: "44_proc2_film", wait: 4) { m, _ in
      if let v = Snapshotter.saved44 { m.setAndCommit("film", v) }
      m.setAndCommit("process", .int(2)); m.sidebarTab = .film
    },
    Step(name: "44_end", wait: 1) { m, _ in m.setAndCommit("process", .int(0)) },
    // Tool levels: beginner in the default layout, then the process-order layout (empty stages go).
    Step(name: "45_beginner", wait: 3) { _, _ in
      let d = UserDefaults.standard
      Snapshotter.saved45 = [ToolLevel.key, PanelLayouts.selectionKey].map { d.object(forKey: $0) }
      d.set(ToolLevel.beginner.rawValue, forKey: ToolLevel.key)
      d.set(PanelLayouts.classicKey, forKey: PanelLayouts.selectionKey)
    },
    Step(name: "45_beginner_workflow", wait: 3) { _, _ in UserDefaults.standard.set(PanelLayouts.workflowKey, forKey: PanelLayouts.selectionKey) },
    Step(name: "45_standard_workflow", wait: 3) { _, _ in UserDefaults.standard.set(ToolLevel.standard.rawValue, forKey: ToolLevel.key) },
    // Hidden tools in use (B3): an expert value edited at standard, the banner opened, then a
    // history step on it peeks the card.
    Step(name: "46_over", wait: 3) { m, _ in
      UserDefaults.standard.set(PanelLayouts.classicKey, forKey: PanelLayouts.selectionKey)
      m.setAndCommit("preflashExposure", .double(0.02))
    },
    Step(name: "46_over_peek", wait: 2) { m, _ in m.spotlight(step: m.historyCount) },
    Step(name: "46_end", wait: 1) { m, _ in m.spotlight(step: nil); m.reset(["preflashExposure"]) },
    Step(name: "45_end", wait: 1) { _, _ in
      for (key, value) in zip([ToolLevel.key, PanelLayouts.selectionKey], Snapshotter.saved45) {
        if let value { UserDefaults.standard.set(value, forKey: key) } else { UserDefaults.standard.removeObject(forKey: key) }
      }
    },
    // Storage humidity: 15 years at room temperature, 50 % vs 85 % RH; instax damp stain.
    Step(name: "31_portra_aged50", wait: 6) { m, _ in
      m.set("agingStorage", .int(2)); m.set("agingHumidity", .double(50)); m.set("agingYears", .double(15)); if let i = Catalog.films.firstIndex(of: "kodak_portra_400") { m.setAndCommit("film", .int(i)) }
    },
    Step(name: "31_portra_aged85", wait: 6) { m, _ in m.setAndCommit("agingHumidity", .double(85)) },
    Step(name: "31_portra_fridge85", wait: 6) { m, _ in m.setAndCommit("agingStorage", .int(1)) },
    Step(name: "31_instax_aged85", wait: 6) { m, _ in
      m.set("agingStorage", .int(2)); m.set("agingYears", .double(5)); if let i = Catalog.films.firstIndex(of: "fujifilm_instax") { m.setAndCommit("film", .int(i)) }
    },
    Step(name: "31_end", wait: 1) { m, _ in m.resetAll() },
    // Split view zoomed in: both halves stay sharp wherever the divider sits.
    Step(name: "32_split_z100", wait: 6) { m, c in m.compareMode = .split; c.setZoom(1); c.split = 0.5 },
    Step(name: "32_split_moved", wait: 0.8) { _, c in c.split = 0.15 },
    Step(name: "32_split_moved2", wait: 0.8) { _, c in c.split = 0.85 },
    // Top/bottom split: before on top, the divider dragged up and down.
    Step(name: "32_stacked", wait: 1.5) { m, c in m.compareMode = .splitStacked; c.splitY = 0.5 },
    Step(name: "32_stacked_moved", wait: 0.8) { _, c in c.splitY = 0.25 },
    Step(name: "32_sbs_stacked", wait: 1.5) { m, c in m.compareMode = .sideBySideStacked; c.setZoom(nil) },
    Step(name: "32_sbs_stacked_z100", wait: 4) { _, c in c.setZoom(1) },
    // Dragging a grain slider while zoomed in: every visible tile must come back with the new look.
    Step(name: "41_grain_z100", wait: 8) { m, c in
      m.set("grainEnabled", .bool(true)); m.commit(); c.setZoom(1)
    },
    Step(name: "41_grain_drag", wait: 10) { m, _ in
      m.beginInteraction()
      for i in 0...20 {
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(i) * 0.06) {
          m.set("grainParticleAreaUm2", .double(0.1 + Double(i) * 0.1))
          if i == 20 { m.commit() }
        }
      }
    },
    Step(name: "41_grain_end", wait: 1) { m, _ in
      FileHandle.standardError.write("tiles after drag: \(m.detailTiles.map { "\(Int($0.region.minX)),\(Int($0.region.minY)) \(Int($0.region.width))x\(Int($0.region.height)) s\($0.scale)" }) viewport \(m.viewport)\n".data(using: .utf8)!)
    },
    Step(name: "32_split_end", wait: 1) { m, c in m.compareMode = .off; c.setZoom(nil); c.split = 0.5; c.splitY = 0.5 },
    // Photo backdrop setting, and the export settings page with its name example.
    Step(name: "33_backdrop_white", wait: 2) { _, _ in UserDefaults.standard.set(Backdrop.white.rawValue, forKey: Appearance.backdropKey) },
    Step(name: "33_backdrop_black", wait: 2) { _, _ in UserDefaults.standard.set(Backdrop.black.rawValue, forKey: Appearance.backdropKey) },
    Step(name: "33_export_settings", wait: 2) { m, _ in
      UserDefaults.standard.removeObject(forKey: Appearance.backdropKey)
      UserDefaults.standard.set("{name}_{film}_{date}", forKey: ExportOptions.nameKey)
      FileHandle.standardError.write("export stem: \(m.source.map { ExportOptions.stem(for: $0.url, values: m.values) } ?? "-")\n".data(using: .utf8)!)
      let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
      w.contentView = NSHostingView(rootView: ExportSettings(model: m))
      w.orderFront(nil)
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        if let dir = Snapshotter.shared.directory { Snapshotter.capture(w, to: dir.appendingPathComponent("33_export_settings_window.png")) }
        w.orderOut(nil)
        UserDefaults.standard.removeObject(forKey: ExportOptions.nameKey)
      }
    },
    Step(name: "34_filmpanel_settings", wait: 2) { _, _ in
      let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 680), styleMask: [.titled], backing: .buffered, defer: false)
      w.contentView = NSHostingView(rootView: FilmPanelSettings())
      w.orderFront(nil)
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
        if let dir = Snapshotter.shared.directory { Snapshotter.capture(w, to: dir.appendingPathComponent("34_filmpanel_settings_window.png")) }
        w.orderOut(nil)
      }
    },
    Step(name: "34_cards_photo", wait: 4) { m, _ in
      m.pickerOpen = true
      Snapshotter.savedExpanded = UserDefaults.standard.string(forKey: "pickerExpanded.film")
      UserDefaults.standard.set("favorites,negative", forKey: "pickerExpanded.film")
    },
    Step(name: "34_cards_curves", wait: 4) { _, _ in
      UserDefaults.standard.set(FilmPanel.CardStyle.curves.rawValue, forKey: FilmPanel.cardStyleKey)
    },
    Step(name: "34_cards_list", wait: 4) { _, _ in
      UserDefaults.standard.set(FilmPanel.CardStyle.list.rawValue, forKey: FilmPanel.cardStyleKey)
    },
    Step(name: "34_cards_maker_nobadge_reordered", wait: 4) { _, _ in
      UserDefaults.standard.removeObject(forKey: FilmPanel.cardStyleKey)
      UserDefaults.standard.set(false, forKey: FilmPanel.shortNameKey)
      UserDefaults.standard.set(false, forKey: FilmPanel.badgeKey)
      UserDefaults.standard.set("bw,favorites,negative,cine,slide,instant", forKey: FilmPanel.orderKey)
      UserDefaults.standard.set("cine,slide", forKey: FilmPanel.hiddenKey)
      UserDefaults.standard.set("bw,favorites", forKey: "pickerExpanded.film")
    },
    Step(name: "34_end", wait: 1) { _, _ in
      FilmPanel.reset()
      if let e = Snapshotter.savedExpanded { UserDefaults.standard.set(e, forKey: "pickerExpanded.film") }
      else { UserDefaults.standard.removeObject(forKey: "pickerExpanded.film") }
      FileHandle.standardError.write("badges: \(["kodak_portra_400", "kodak_vision3_500t", "kodak_trix", "fujifilm_instax", "kodak_portra_endura"].map { "\($0)=\(FilmPanel.badge($0) ?? "-")" })\n".data(using: .utf8)!)
      FileHandle.standardError.write("names: \(["kodak_portra_400", "fujifilm_c200", "ilford_hp5_plus"].map { FilmPanel.name($0, short: true) })\n".data(using: .utf8)!)
    },
    Step(name: "27_trix_std", wait: 6) { m, _ in
      m.set("devTempDelta", .double(0)); if let i = Catalog.films.firstIndex(of: "kodak_tri_x_400") { m.setAndCommit("film", .int(i)) }
    },
    Step(name: "27_trix_long", wait: 6) { m, _ in
      m.setAndCommit("devTimePercent", .double(170))
    },
    Step(name: "05_before", wait: 2) { m, _ in m.showBefore = true },
    Step(name: "06_history", wait: 2) { m, c in
      m.showBefore = false
      c.setZoom(nil)
      m.set("grainParticleAreaUm2", .double(0.4))
      m.commit()
      m.showHistory = true
    },
    Step(name: "70_timeline", wait: 3) { m, _ in
      m.showHistory = false
      m.setAndCommit("filmExposureEv", .double(0.7))
      m.setAndCommit("devTimePercent", .double(120))
      m.setAndCommit("halationEnabled", .bool(true))
      m.setAndCommit("vignetteEnabled", .bool(true))
      m.undo(); m.undo()
      for k in 1...m.historyCount {
        print("timeline", m.historyName(k), StepChanges.lines(from: m.historyState(k - 1), to: m.historyState(k)))
      }
      // PHOTOEMUL_TIMELINE_SELECT=k: as if step k were clicked (opens and flashes its card; this
      // writes the inspector's fold keys, so save and restore them around the run).
      if let k = ProcessInfo.processInfo.environment["PHOTOEMUL_TIMELINE_SELECT"].flatMap(Int.init) { m.spotlight(step: k) }
      // PHOTOEMUL_TIMELINE_OPS="group:2-3,fold,compact:1-2,delete:3,ungroup:2": history edits in
      // order, then each step is printed (name, group, folded) with the marker and the edited values.
      for op in (ProcessInfo.processInfo.environment["PHOTOEMUL_TIMELINE_OPS"] ?? "").split(separator: ",") {
        let parts = op.split(separator: ":")
        let ends = parts.count > 1 ? parts[1].split(separator: "-").compactMap { Int($0) } : []
        let r = ends.isEmpty ? 1...1 : ends[0]...(ends.last ?? ends[0])
        switch parts[0] {
        case "group": m.groupHistorySteps(r)
        case "ungroup": m.ungroupHistorySteps(Set(r))
        case "compact": m.compactHistorySteps(r)
        case "delete": m.deleteHistorySteps(Set(r))
        case "reset": m.resetAll()
        case "ev": m.setAndCommit("filmExposureEv", .double(parts.count > 1 ? Double(parts[1]) ?? 0 : 0))
        case "dev": m.setAndCommit("devTimePercent", .double(parts.count > 1 ? Double(parts[1]) ?? 100 : 100))
        case "select": m.spotlight(step: r.lowerBound)
        case "fold":
          if let g = (1...max(m.historyCount, 1)).lazy.compactMap({ m.historyEntry($0).group }).first {
            m.updateHistoryGroup(g.id) { $0.collapsed.toggle() }
          }
        default: break
        }
        print("op", op, "position", m.historyPosition, "of", m.historyCount)
        for k in stride(from: 1, through: m.historyCount, by: 1) {
          let g = m.historyEntry(k).group
          print("  ", m.historyName(k), g.map { "[\($0.name) \($0.id.uuidString.prefix(4))\($0.collapsed ? " folded" : "")]" } ?? "")
        }
        print("  values", ["filmExposureEv", "devTimePercent", "halationEnabled", "vignetteEnabled"].map { "\($0)=\(m.values[$0].map { "\($0)" } ?? "-")" })
      }
    },
    Step(name: "07_effects", wait: 5) { m, _ in
      m.showHistory = false
      m.sidebarTab = .film
      m.set("lensBlurEnabled", .bool(true))
      m.set("lensBlurAmount", .double(2))
      m.set("vignetteEnabled", .bool(true))
      m.set("frameStyle", .int(3))
      m.commit()
    },
    Step(name: "08_split_snapshot", wait: 6) { m, _ in
      m.addSnapshot(name: "Portra 400 + effects")
      if let i = Catalog.films.firstIndex(of: "kodak_ektar_100") { m.setAndCommit("film", .int(i)) }
      if let s = m.snapshots.last { m.compareBase = .snapshot(s.id) }
      m.compareMode = .split
    },
    Step(name: "09_side_by_side_film", wait: 6) { m, _ in
      if let i = Catalog.films.firstIndex(of: "fujifilm_velvia_100") ?? Catalog.films.indices.last { m.compareBase = .film(i) }
      m.compareMode = .sideBySide
      m.sidebarTab = .film
    },
    Step(name: "10_probe", wait: 2) { m, c in
      m.compareMode = .off
      // Fake a cursor position at the canvas centre for the colour picker readout.
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
        if let r = Snapshotter.findCanvas(in: Snapshotter.mainWindow?.contentView?.superview ?? NSView())?.renderer,
           case let rect = r.lastImageRect, rect.width > 0 {
          c.probe.reading = r.probe(at: NSPoint(x: rect.midX, y: rect.midY))
        }
      }
    },
    Step(name: "11_presets_menu", wait: 2) { m, c in
      c.probe.reading = nil
      // Written to the real preset folder, so 40_end removes it again (only if this run made it).
      if Presets.named("Ektar test") == nil {
        Presets.save(m.values, name: "Ektar test")
        Snapshotter.madeTestPreset = true
      }
      m.sidebarTab = .preset
    },
    // Panel closed: the canvas takes the width back and the photo re-fits.
    Step(name: "12_panel_closed", wait: 3) { m, _ in m.pickerOpen = false },
    Step(name: "13_list_light", wait: 4) { m, _ in
      UserDefaults.standard.set(72.0, forKey: "pickerCard.film")
      Snapshotter.savedExpanded = UserDefaults.standard.string(forKey: "pickerExpanded.film")
      UserDefaults.standard.set("favorites,slide", forKey: "pickerExpanded.film")
      m.sidebarTab = .film
      m.pickerOpen = true
      Appearance.apply(Appearance.light.rawValue)
    },
    // Opening a group in grid mode: cards keep the chosen size.
    Step(name: "13b_grid_cine", wait: 5) { _, _ in
      UserDefaults.standard.removeObject(forKey: "pickerCard.film")
      UserDefaults.standard.set("favorites,cine", forKey: "pickerExpanded.film")
    },
    Step(name: "14_restore", wait: 1) { m, _ in
      if let e = Snapshotter.savedExpanded { UserDefaults.standard.set(e, forKey: "pickerExpanded.film") }
      else { UserDefaults.standard.removeObject(forKey: "pickerExpanded.film") }
      Appearance.apply(UserDefaults.standard.string(forKey: Appearance.key) ?? "")
    },
  ]

  func register(model: EditModel, canvas: CanvasState) {
    self.model = model
    self.canvas = canvas
    guard directory != nil, !started else { return }
    started = true
    // SNAPSHOT_STEPS=01_main,08_split_snapshot limits the run to those steps (40_end always runs: it cleans up).
    if let only = ProcessInfo.processInfo.environment["SNAPSHOT_STEPS"]?.split(separator: ",").map(String.init) {
      steps = steps.filter { only.contains($0.name) || $0.name == "40_end" }
    }
    try? FileManager.default.createDirectory(at: directory!, withIntermediateDirectories: true)
    if model.standalone && model.inputURL == nil {
      runStandalone()
    } else {
      waitUntilReady(deadline: Date().addingTimeInterval(120))
    }
  }

  /// Launched without a photo: capture the empty window, then open SNAPSHOT_OPEN and
  /// export it to SNAPSHOT_EXPORT (format from its extension) the way ⌘O / ⌘S would.
  private func runStandalone() {
    let env = ProcessInfo.processInfo.environment
    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [self] in
      guard let model, let directory else { return }
      if let w = Snapshotter.mainWindow {
        w.setContentSize(NSSize(width: 1600, height: 1000))
        w.center()
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
        if let w = Snapshotter.mainWindow {
          Self.capture(w, to: directory.appendingPathComponent("00_empty.png"))
        }
        guard let path = env["SNAPSHOT_OPEN"] else { NSApp.terminate(nil); return }
        model.open(URL(fileURLWithPath: path))
        waitUntilReady(deadline: Date().addingTimeInterval(120)) {
          guard let out = env["SNAPSHOT_EXPORT"] else { return }
          let url = URL(fileURLWithPath: out)
          model.export(to: url, format: url.pathExtension.lowercased() == "jpg" ? .jpeg : .tiff16)
        }
      }
    }
  }

  private func waitUntilReady(deadline: Date, then: (() -> Void)? = nil) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [self] in
      guard let model else { return }
      let thumbsDone = !model.thumbsPending && !model.filmThumbs.isEmpty
      if (model.preview != nil && thumbsDone) || Date() > deadline {
        if let w = Snapshotter.mainWindow {
          w.setContentSize(NSSize(width: 1600, height: 1000))
          w.center()
        }
        then?()
        run(0)
      } else {
        waitUntilReady(deadline: deadline, then: then)
      }
    }
  }

  private func run(_ index: Int) {
    guard index < steps.count, let model, let canvas, let directory else {
      NSApp.terminate(nil)
      return
    }
    let step = steps[index]
    step.action(model, canvas)
    DispatchQueue.main.asyncAfter(deadline: .now() + step.wait) { [self] in
      if let w = Snapshotter.mainWindow {
        Self.capture(w, to: directory.appendingPathComponent("\(step.name).png"))
      }
      if ["16_", "17_", "18_", "19_", "20_"].contains(where: step.name.hasPrefix) { print("\(step.name): zoom \(String(format: "%.3f", canvas.effectiveZoom)) proxyScale \(String(format: "%.3f", model.proxyScale)) wants \(model.wantsDetail) \(model.detailTiles.count) tiles, job \(model.detailJob.map { "#\($0.id) \($0.done)/\($0.cells.count)\($0.quiet ? " quiet" : "")" } ?? "none"), scale \(model.detailScale)") }
      if let job = model.detailJob {
        print("\(step.name): tile job #\(job.id) \(job.done)/\(job.cells.count)\(job.loading ? " loading" : "") at scale \(model.detailScale)")
      }
      if !model.detailTiles.isEmpty {
        print("\(step.name): viewport \(model.viewport.integral), \(model.detailTiles.count) detail tiles, canvas \(Snapshotter.mainWindow.flatMap { w in Self.findCanvas(in: w.contentView!.superview!).map { $0.convert($0.bounds, to: nil).integral } } ?? .zero)")
      }
      run(index + 1)
    }
  }

  /// Writes the module graphs for a few settings side by side: as given, scene light and B&W
  /// developer on, B&W paper.
  @MainActor static func renderGraphs(_ base: [String: ParamValue], _ name: String) {
    guard let dir = shared.directory else { return }
    var lit = base; lit["sceneIlluminant"] = .int(4)
    var bw = base
    if let i = Catalog.films.firstIndex(of: "ilford_hp5_plus") { bw["film"] = .int(i) }
    bw["adjacencyEnabled"] = .bool(true); bw["sceneIlluminant"] = .int(9)
    if let i = Catalog.papers.firstIndex(of: "kodak_2302") { bw["paper"] = .int(i) }
    let column = { (v: [String: ParamValue]) in
      VStack(alignment: .leading, spacing: 10) {
        EdgeProfileGraph(values: v); IlluminantSpdGraph(values: v); GradeCurveGraph(values: v); VignetteProfileGraph(values: v)
      }.frame(width: 300)
    }
    let view = HStack(alignment: .top, spacing: 16) { column(base); column(lit); column(bw) }
      .padding(12).background(Color(nsColor: .windowBackgroundColor))
    let r = ImageRenderer(content: view); r.scale = 2
    if let img = r.nsImage, let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
      try? png.write(to: dir.appendingPathComponent(name + ".png"))
    }
  }

  static func capture(_ window: NSWindow, to url: URL) {
    // The frame view gives the toolbar, but SwiftUI panels only draw when the
    // content view is cached on its own, and neither paints the window background.
    guard let root = window.contentView?.superview, let content = window.contentView,
          let rep = root.bitmapImageRepForCachingDisplay(in: root.bounds),
          let frameRep = root.bitmapImageRepForCachingDisplay(in: root.bounds),
          let contentRep = content.bitmapImageRepForCachingDisplay(in: content.bounds),
          let ctx = NSGraphicsContext(bitmapImageRep: rep)
    else { return }
    root.cacheDisplay(in: root.bounds, to: frameRep)
    content.cacheDisplay(in: content.bounds, to: contentRep)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = ctx
    window.effectiveAppearance.performAsCurrentDrawingAppearance {
      NSColor.windowBackgroundColor.setFill()
      root.bounds.fill()
    }
    frameRep.draw(in: root.bounds, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
    var contentFrame = content.convert(content.bounds, to: root)
    if root.isFlipped { contentFrame.origin.y = root.bounds.height - contentFrame.maxY }
    // The content view reaches under the unified toolbar; keep the toolbar from the frame view.
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(rect: window.contentLayoutRect).addClip()
    contentRep.draw(in: contentFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
    NSGraphicsContext.restoreGraphicsState()
    // Metal layers are not captured by cacheDisplay; draw the canvas image ourselves.
    if let mtk = findCanvas(in: root), let r = mtk.renderer, !r.drawn.isEmpty {
      var frame = mtk.convert(mtk.bounds, to: root)
      if root.isFlipped { frame.origin.y = root.bounds.height - frame.maxY }
      mtk.effectiveAppearance.performAsCurrentDrawingAppearance { Appearance.canvasColor.setFill() }
      frame.fill()
      ctx.cgContext.interpolationQuality = .high
      for d in r.drawn {
        guard let image = PixelImage.cgImage(halfP3: d.buffer) else { continue }
        ctx.cgContext.saveGState()
        ctx.cgContext.clip(to: d.visible.offsetBy(dx: frame.minX, dy: frame.minY))
        ctx.cgContext.draw(image, in: d.rect.offsetBy(dx: frame.minX, dy: frame.minY))
        ctx.cgContext.restoreGState()
      }
      NSColor(white: 0.92, alpha: 1).setFill()
      let stacked = r.dividerY != nil
      if let pos = r.dividerX ?? r.dividerY {
        if stacked {
          NSRect(x: frame.minX, y: frame.minY + pos - 1, width: frame.width, height: 2).fill()
        } else {
          NSRect(x: frame.minX + pos - 1, y: frame.minY, width: 2, height: frame.height).fill()
        }
        // The handle, as the renderer draws it.
        let k = CanvasRenderer.knobRadius * (r.dividerHot ? 1.15 : 1)
        let c = stacked ? NSPoint(x: frame.midX, y: frame.minY + pos) : NSPoint(x: frame.minX + pos, y: frame.midY)
        NSColor(white: 0.12, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - k - 1, y: c.y - k - 1, width: 2 * k + 2, height: 2 * k + 2)).fill()
        NSColor(white: 0.92, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: c.x - k, y: c.y - k, width: 2 * k, height: 2 * k)).fill()
        NSColor(white: 0.15, alpha: 1).setFill()
        let ah = k * 0.42, aw = k * 0.34, gap = k * 0.14
        // Points in (along, across) the arrow direction, swapped for the up/down arrows.
        func pt(_ a: Double, _ b: Double) -> NSPoint { stacked ? NSPoint(x: c.x + b, y: c.y + a) : NSPoint(x: c.x + a, y: c.y + b) }
        for side in [-1.0, 1.0] {
          let arrow = NSBezierPath()
          arrow.move(to: pt(side * gap, -ah))
          arrow.line(to: pt(side * gap, ah))
          arrow.line(to: pt(side * (gap + aw), 0))
          arrow.close(); arrow.fill()
        }
      } else if r.mode == .sideBySide, r.compare != nil {
        NSRect(x: frame.midX - 1, y: frame.minY, width: 2, height: frame.height).fill()
      } else if r.mode == .sideBySideStacked, r.compare != nil {
        NSRect(x: frame.minX, y: frame.midY - 1, width: frame.width, height: 2).fill()
      }
      // SwiftUI overlays (progress pill, tile marks) sit above the canvas; paint them again on top.
      NSGraphicsContext.saveGraphicsState()
      NSBezierPath(rect: frame).addClip()
      contentRep.draw(in: contentFrame, from: .zero, operation: .sourceOver, fraction: 1, respectFlipped: false, hints: nil)
      NSGraphicsContext.restoreGraphicsState()
    }
    NSGraphicsContext.restoreGraphicsState()
    if let png = rep.representation(using: .png, properties: [:]) {
      try? png.write(to: url)
    }
  }

  static func findCanvas(in view: NSView) -> CanvasMTKView? {
    if let v = view as? CanvasMTKView { return v }
    for sub in view.subviews { if let v = findCanvas(in: sub) { return v } }
    return nil
  }
}

