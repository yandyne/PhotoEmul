import AppKit
import SwiftUI

/// Toolbar compare buttons in the manner of Photoshop's tool groups: off, split and side by side.
/// Clicking a tool turns on the orientation it used last; pressing and holding (or the small
/// triangle) opens its menu, and the orientation picked there stays the tool's choice.
struct CompareTools: NSViewRepresentable {
  let mode: CompareMode
  let lastSplit: CompareMode
  let lastSideBySide: CompareMode
  let select: (CompareMode) -> Void

  private static let tools: [[CompareMode]] = [[.off], [.split, .splitStacked], [.sideBySide, .sideBySideStacked]]

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> NSSegmentedControl {
    let control = NSSegmentedControl()
    control.segmentCount = Self.tools.count
    control.trackingMode = .selectOne
    control.target = context.coordinator
    control.action = #selector(Coordinator.segmentChosen(_:))
    for (i, group) in Self.tools.enumerated() where group.count > 1 {
      let menu = NSMenu()
      for m in group {
        let item = NSMenuItem(title: m.title, action: #selector(Coordinator.itemChosen(_:)), keyEquivalent: "")
        item.target = context.coordinator
        item.representedObject = m.rawValue
        item.image = NSImage(systemSymbolName: m.symbol, accessibilityDescription: nil)
        menu.addItem(item)
      }
      control.setMenu(menu, forSegment: i)
      control.setShowsMenuIndicator(true, forSegment: i)
    }
    return control
  }

  func updateNSView(_ control: NSSegmentedControl, context: Context) {
    context.coordinator.parent = self
    for (i, group) in Self.tools.enumerated() {
      let shown = group.contains(mode) ? mode : i == 1 ? lastSplit : i == 2 ? lastSideBySide : .off
      control.setImage(NSImage(systemSymbolName: shown.symbol, accessibilityDescription: shown.title), forSegment: i)
      control.setToolTip(tooltip(for: i, shown: shown), forSegment: i)
      for item in control.menu(forSegment: i)?.items ?? [] {
        item.state = item.representedObject as? String == shown.rawValue ? .on : .off
      }
    }
    control.selectedSegment = Self.tools.firstIndex { $0.contains(mode) } ?? 0
  }

  private func tooltip(for segment: Int, shown: CompareMode) -> String {
    switch segment {
    case 1: return shown.title + " · ⇧Y\n" + tr("누르고 있으면 좌우 / 상하 선택 · ⌥Y 90° 돌리기", "Press and hold for left/right or top/bottom · ⌥Y turns 90°")
    case 2: return shown.title + " · Y\n" + tr("누르고 있으면 좌우 / 상하 선택 · ⌥Y 90° 돌리기", "Press and hold for left/right or top/bottom · ⌥Y turns 90°")
    default: return shown.title
    }
  }

  final class Coordinator: NSObject {
    var parent: CompareTools?

    @objc func segmentChosen(_ control: NSSegmentedControl) {
      guard let parent else { return }
      switch control.selectedSegment {
      case 1: parent.select(parent.mode.isSplit ? parent.mode : parent.lastSplit)
      case 2: parent.select(parent.mode.isSideBySide ? parent.mode : parent.lastSideBySide)
      default: parent.select(.off)
      }
    }

    @objc func itemChosen(_ item: NSMenuItem) {
      guard let raw = item.representedObject as? String, let m = CompareMode(rawValue: raw) else { return }
      parent?.select(m)
    }
  }
}
