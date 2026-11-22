import AppKit

/// One line per slider drag in ~/Library/Logs/PhotoEmul/slider.log, to tell on a given Mac whether
/// a lagging knob comes from the main thread (busy %, event lag, model change ms) or the GPU (draft ms).
enum SliderTrace {
  private static var start = 0.0, idle = 0.0, sleptAt = 0.0
  private static var events = 0, lagSum = 0.0, lagMax = 0.0
  private static var applies: [Double] = [], renders: [Double] = []
  private static var observer: CFRunLoopObserver?
  private static var now: Double { ProcessInfo.processInfo.systemUptime }

  static func begin() {
    start = now; idle = 0; sleptAt = 0; events = 0; lagSum = 0; lagMax = 0; applies = []; renders = []
    // Time the main thread spends asleep; the rest of the drag it was busy.
    let o = CFRunLoopObserverCreateWithHandler(
      nil, CFRunLoopActivity.beforeWaiting.rawValue | CFRunLoopActivity.afterWaiting.rawValue, true, 0
    ) { _, activity in
      if activity == .beforeWaiting { sleptAt = now } else if sleptAt > 0 { idle += now - sleptAt; sleptAt = 0 }
    }
    CFRunLoopAddObserver(CFRunLoopGetMain(), o, .commonModes)
    observer = o
  }

  static func event(lag: Double) { events += 1; lagSum += lag; lagMax = max(lagMax, lag) }
  static func apply(ms: Double) { applies.append(ms) }
  static func render(_ ms: Double) { if observer != nil { renders.append(ms) } }

  static func end() {
    guard let o = observer else { return }
    CFRunLoopRemoveObserver(CFRunLoopGetMain(), o, .commonModes)
    observer = nil
    let total = now - start
    guard events > 2 else { return }  // a click, not a drag
    func avg(_ a: [Double]) -> Double { a.isEmpty ? 0 : a.reduce(0, +) / Double(a.count) }
    #if arch(x86_64)
      let arch = "x86_64"
    #else
      let arch = "arm64"
    #endif
    let line = String(
      format: "%@ %@ %@ draft %d | %.2f s, busy %.0f%%, events %d, applied %d, lag avg %.0f max %.0f ms, change avg %.1f max %.1f ms, drafts %d avg %.0f ms\n",
      ISO8601DateFormatter().string(from: Date()), arch, Performance.current.rawValue, EditModel.draftEdge,
      total, total > 0 ? (1 - idle / total) * 100 : 0, events, applies.count,
      lagSum / Double(events) * 1000, lagMax * 1000, avg(applies), applies.max() ?? 0, renders.count, avg(renders))
    if ProcessInfo.processInfo.environment["SPEKTRALAB_DIAG"] != nil { print("slider:", line, terminator: "") }
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/PhotoEmul")
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let url = dir.appendingPathComponent("slider.log")
    if let h = try? FileHandle(forWritingTo: url) {
      h.seekToEndOfFile()
      h.write(Data(line.utf8))
      try? h.close()
    } else {
      try? Data(line.utf8).write(to: url)
    }
  }
}
