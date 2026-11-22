// PhotoEmul - native editor for spektrafilm (GPL-3.0-or-later)
// Editor state: parameter values, undo history, preview/detail/thumbnail rendering.

import AppKit
import CSpektra
import Foundation
import Observation
import UniformTypeIdentifiers

struct HistoryEntry: Identifiable {
  /// Kept when the step moves between the undo and redo stacks, so the timeline keeps its icons.
  var id = UUID()
  let label: String
  var values: [String: ParamValue]
  /// The timeline group the step sits in (a run of neighbouring steps), if any.
  var group: StepGroup?
  /// Who made the step: nil = the user, "ai:<agent>" = an agent (orange ✦ on the timeline).
  var source: String?
  /// The agent's reason for the step.
  var note: String?

  var isAI: Bool { source?.hasPrefix("ai") == true }
  func with(values: [String: ParamValue]) -> HistoryEntry { var e = self; e.values = values; return e }
}

struct StepGroup: Codable, Hashable {
  var id = UUID()
  var name: String
  /// Shown on the timeline as one tile.
  var collapsed = false
}


/// What the compare views put next to the current edit.
enum CompareBase: Hashable {
  case original
  case snapshot(UUID)
  /// The current settings with another film stock (follows every edit).
  case film(Int)
  /// A point on the history timeline, taken when it was picked.
  case history(String, [String: ParamValue])
}

struct Histogram {
  var bins: [[Float]] = [[], [], []]  // normalised 0...1, 128 bins per channel
  var shadowClip: Double = 0
  var highlightClip: Double = 0
}

@Observable
final class ValueCell { var bump = 0 }

@Observable
final class EditModel {
  /// Smaller on slower Macs; the full-resolution detail render still fills in when zoomed.
  static var proxyEdge: Int { Performance.lowPower ? 2048 : 2560 }
  static let thumbEdge = 240
  /// Preview size while a slider is dragged; the full proxy renders on release. Slower Macs draw a
  /// smaller one so the canvas keeps up with the pointer.
  static var draftEdge: Int { Performance.lowPower ? 800 : 1280 }

  /// The window's model, for Finder "Open With" and dropped files.
  static weak var current: EditModel?
  /// A photo the system asked to open before the window existed.
  static var pendingOpen: URL?

  // Launch contract
  private(set) var inputURL: URL?
  let outputURL: URL?
  /// Remembers this photo's edit between launches (Lightroom photo path or input path).
  private(set) var sessionKey: String?
  /// Further photos that get the same settings on save (multi-photo edit from Lightroom).
  let batch: [BatchItem]
  /// Launched on its own rather than from Lightroom: photos are opened and exported here.
  var standalone: Bool { outputURL == nil && batch.isEmpty }
  var exportFormat: ExportFormat = ExportFormat(rawValue: UserDefaults.standard.string(forKey: "exportFormat") ?? "") ?? .tiff16 {
    didSet { UserDefaults.standard.set(exportFormat.rawValue, forKey: "exportFormat") }
  }
  private(set) var resumed = false
  private(set) var snapshots: [EditSnapshot] = []

  var compareMode: CompareMode = CompareMode(rawValue: Layout.string("compareMode") ?? "") ?? .off {
    didSet {
      Layout.save(compareMode.rawValue, forKey: "compareMode")
      if compareMode.isSplit { lastSplit = compareMode }
      if compareMode.isSideBySide { lastSideBySide = compareMode }
      if compareMode != .off {
        requestPreview()
        scheduleCompareDetail()
      } else {
        cancelCompareDetail()
        compareTiles = []
      }
    }
  }
  /// The orientation each compare tool used last, so its toolbar button and Y / ⇧Y bring it back.
  var lastSplit: CompareMode = CompareMode(rawValue: Layout.string("compareSplit") ?? "").flatMap { $0.isSplit ? $0 : nil } ?? .split {
    didSet { Layout.save(lastSplit.rawValue, forKey: "compareSplit") }
  }
  var lastSideBySide: CompareMode = CompareMode(rawValue: Layout.string("compareSideBySide") ?? "").flatMap { $0.isSideBySide ? $0 : nil } ?? .sideBySide {
    didSet { Layout.save(lastSideBySide.rawValue, forKey: "compareSideBySide") }
  }
  var compareBase: CompareBase = .original {
    didSet {
      requestPreview()
      scheduleCompareDetail()
    }
  }
  /// Render of the compare base when it is not the untouched original.
  private(set) var reference: PixelBuffer?
  private var referenceKey: [String: ParamValue]?

  var values: [String: ParamValue] {
    didSet {
      for (name, cell) in cells where oldValue[name] != values[name] { cell.bump += 1 }
      if !interacting || scrubbing { settle() }
    }
  }
  /// What panel layout, notes and graphs follow: `values`, held still while a slider is dragged so
  /// a drag redraws only its own row and the picture (reading `values` redraws every card).
  private(set) var settledValues: [String: ParamValue] = [:]
  /// One per parameter a view has read through `value(_:)`: only views reading the changed name redraw.
  @ObservationIgnored private var cells: [String: ValueCell] = [:]
  private func settle() { if settledValues != values { settledValues = values } }
  private(set) var undoStack: [HistoryEntry] = []
  private(set) var redoStack: [HistoryEntry] = []

  private(set) var source: SourceImage?
  private(set) var preview: PixelBuffer?
  private(set) var before: PixelBuffer?
  /// Sharper renders of parts of the image, drawn over the proxy when zoomed in. Tiles sit on a
  /// fixed grid per scale so panning reuses the ones already rendered; one tile is the whole frame
  /// when the look cannot be rendered in parts.
  private(set) var detailTiles: [DetailTile] = [] {
    didSet { if Self.tileLog { logTiles() } }
  }
  // SPEKTRALAB_TILELOG=1: every change of the tile set, with the view and scale it is drawn at.
  static let tileLog = ProcessInfo.processInfo.environment["SPEKTRALAB_TILELOG"] != nil
  private func logTiles() {
    let v = viewport
    var line = String(format: "tiles scale %.3g view %.0f,%.0f %.0fx%.0f:", detailScale, v.minX, v.minY, v.width, v.height)
    for t in detailTiles.sorted(by: { ($0.scale, $0.region.minY, $0.region.minX) < ($1.scale, $1.region.minY, $1.region.minX) }) {
      let r = t.region
      line += String(format: " [%.3g %.0f,%.0f %.0fx%.0f%@]", t.scale, r.minX, r.minY, r.width, r.height, r.intersects(v) ? "*" : "")
    }
    FileHandle.standardError.write((line + "\n").data(using: .utf8)!)
  }
  /// Part of the image on screen, in source pixels; set by the canvas.
  @ObservationIgnored var viewport: CGRect = .zero {
    didSet { if wantsDetail, detailQueued.generation >= 0 || !detailCovers(viewport) { scheduleDetail(delay: 0.25) } }
  }
  /// The same for the compare base (left side of the compare views). Rendered after the current
  /// edit's tiles and kept in memory only.
  private(set) var compareTiles: [DetailTile] = []
  /// Part of the compare image on screen, in source pixels; set by the canvas.
  @ObservationIgnored var compareViewport: CGRect = .zero {
    didSet { if compareViewport != oldValue { scheduleCompareDetail(delay: 0.25) } }
  }
  /// What `compareTiles` were rendered from; tiles of another base or photo are dropped.
  @ObservationIgnored private var compareTileKey: CompareTileKey?
  @ObservationIgnored private var compareToken = CancelFlag()
  /// Tiles the running compare job was given.
  @ObservationIgnored private var compareQueued: [CGRect] = []
  /// Compare jobs of this base that hit a render failure; retries stop after a few.
  @ObservationIgnored private var compareFailures = 0
  private(set) var histogram = Histogram()
  private(set) var filmThumbs: [Int: CGImage] = [:]
  private(set) var paperThumbs: [Int: CGImage] = [:]
  /// The look of the film or paper the pointer rests on in the picker, from the proxy only (no
  /// detail tiles); shown on the canvas instead of `preview` until the pointer leaves.
  private(set) var hoverPreview: PixelBuffer?
  private(set) var hoverLabel: String?
  @ObservationIgnored private var hoverTarget: HoverTarget?
  @ObservationIgnored private var hoverWork: DispatchWorkItem?
  /// Clears the hover look once the pointer has stayed off the cards for FilmPanel.hoverHold.
  @ObservationIgnored private var hoverLeaveWork: DispatchWorkItem?
  /// Name of the card under the pointer while its look renders and the last one stays on screen.
  private(set) var hoverPendingLabel: String?
  @ObservationIgnored private var hoverBusy = false
  /// The last few hovered looks for the current edit, so going back and forth renders nothing.
  @ObservationIgnored private var hoverCache: [(target: HoverTarget, buffer: PixelBuffer)] = []
  /// Darkroom test strip shown as a tool (TestStrip): drawn over the preview until it is hidden,
  /// edits and band picks redraw it. Not saved; `testStripEffect` keeps the strip in the picture.
  private(set) var testStripImage: PixelBuffer?
  private(set) var testStripOn = false
  @ObservationIgnored private var testStripToken = 0
  /// Stops the bands still to render when the strip closes or is opened again.
  @ObservationIgnored private var testStripCancel = CancelFlag()
  /// Redraws the strip once the edit settles; the plain preview shows meanwhile.
  @ObservationIgnored private var testStripWork: DispatchWorkItem?

  var showBefore = false
  var wantsDetail = false {
    didSet {
      guard wantsDetail != oldValue else { return }
      fullCacheDrop?.cancel()
      if wantsDetail {
        scheduleDetail()
      } else {
        // Back to the proxy: stop between tiles and hand the full-res scratch buffers back.
        detailWork?.cancel()
        detailToken.cancelled = true
        detailJob = nil
        cancelCompareDetail()
        let engine = detailEngine
        detailQueue.async { engine.created?.releaseMemory() }
        // The full-size source is large; let it go if the view stays zoomed out a while.
        let cache = fullCache
        let drop = DispatchWorkItem { cache.drop() }
        fullCacheDrop = drop
        detailQueue.asyncAfter(deadline: .now() + 30, execute: drop)
      }
    }
  }
  @ObservationIgnored private var fullCacheDrop: DispatchWorkItem?
  var sidebarTab: SidebarTab = .film
  /// The film/paper/preset picker docked left of the canvas; the photo re-fits beside it.
  var pickerOpen = Layout.bool("pickerOpen") ?? true {
    didSet { Layout.save(pickerOpen, forKey: "pickerOpen") }
  }
  var showHistory = false
  /// Last preset applied, for the recipe bar.
  var presetName: String?

  /// Median of the last few full-size preview renders; 0 until one has been timed. The engine's
  /// very first render (shader and table setup) and drag drafts are left out so it reads typical.
  private(set) var renderMs: Double = 0
  @ObservationIgnored private var renderSamples: [Double] = []
  @ObservationIgnored private var engineWarm = false
  private(set) var detailRendering = false
  /// The tile batch being rendered, for the progress pill; kept briefly after it finishes.
  /// Scale of the source the detail tiles are rendered from: 1 at 100% and up, 1/2 or 1/4 when
  /// zoomed in only a little, so a big photo is not rendered at full size to be shown at 40%.
  @ObservationIgnored var detailScale = 1.0 {
    didSet { if wantsDetail, detailScale != oldValue { scheduleDetail(delay: 0.25) } }
  }
  private(set) var detailJob: DetailJob?
  private(set) var saving = false
  var errorMessage: String?
  private(set) var statusText = ""

  private var committed: [String: ParamValue]
  private var proxySource: PixelBuffer?
  private var thumbSource: PixelBuffer?
  private var draftSource: PixelBuffer?
  /// A slider or pad is being dragged: previews render as drafts.
  private var interacting = false
  private let fullCache = FullSourceCache()
  /// Detail tiles pushed out of memory, read back when the view returns to them.
  private let spill = TileSpill()

  private let previewEngine: SpektraEngine
  // Each engine costs 100-200 ms to set up; these two are made on their own queues when first used.
  private let detailEngine = LazyEngine()
  private let thumbEngine = LazyEngine(role: .thumbnail)
  // One step lower on slower Macs so renders never outrank the window server and other apps.
  private let previewQueue = DispatchQueue(label: "photoemul.preview", qos: Performance.lowPower ? .userInitiated : .userInteractive)
  private let detailQueue = DispatchQueue(label: "photoemul.detail", qos: Performance.lowPower ? .utility : .userInitiated)
  private let thumbQueue = DispatchQueue(label: "photoemul.thumbs", qos: Performance.lowPower ? .background : .utility)

  private(set) var previewBusy = false
  private var previewDirty = false
  /// History step of the render in flight; a request for another step cancels it.
  private var previewPosition = 0
  private var generation = 0
  /// Tile jobs of this generation that hit a render failure; retries stop after a few.
  private var detailFailures = 0
  private var detailToken = CancelFlag()
  private var detailJobCount = 0
  /// Tiles the current detail job was given, so a small pan does not restart it.
  @ObservationIgnored private var detailQueued: (generation: Int, scale: Double, cells: [CGRect]) = (-1, 0, [])
  private var detailWork: DispatchWorkItem?
  private var thumbWork: DispatchWorkItem?
  private var thumbCancel: CancelFlag?
  private var thumbKey: [String: ParamValue] = [:]
  /// Thumbnails the browser shows (films, papers); only these are rendered.
  private var wantedThumbs: [[Int]] = [[], []]
  /// Thumbnails already rendered with the current `thumbKey`.
  private var freshThumbs: [Set<Int>] = [[], []]
  private var scheduledCurrent: [Int] = []
  /// Timeline hover card: one thumbnail per history step, rendered on the thumb queue when its card first shows (iPad step cards).
  private(set) var stepThumbs: [Int: (state: [String: ParamValue], image: CGImage)] = [:]
  private(set) var thumbsPending = false
  /// Thumbnails wait while the user is dragging a slider, so the preview gets the machine.
  private let editClock = EditClock()
  private var loadingURL: URL?

  /// `engine` lets the launch splash time the renderer setup on its own.
  init(input: URL?, output: URL?, sessionKey: String? = nil, batch: [BatchItem] = [], engine: SpektraEngine? = nil) {
    previewEngine = engine ?? SpektraEngine()
    inputURL = input
    outputURL = output
    let key = sessionKey ?? input?.path
    self.sessionKey = key
    self.batch = batch
    let session = key.flatMap { Sessions.load($0) }
    var start = session?.values ?? FilmPanel.startValues()
    // Diagnostics: `--set` applies to the window too, so a look can be reproduced from the command line.
    if ProcessInfo.processInfo.environment["SPEKTRALAB_DIAG"] != nil { HeadlessRender.applyOverrides(&start) }
    values = start
    settledValues = start
    committed = start
    snapshots = session?.snapshots ?? []
    resumed = session != nil
    restoreHistory(session, base: start)
    if !previewEngine.isAvailable {
      errorMessage = tr("Metal 렌더러를 초기화할 수 없습니다: ", "Cannot initialize the Metal renderer: ") + previewEngine.lastError
    }
    // Diagnostics: SPEKTRALAB_TESTSTRIP=seconds opens the darkroom test strip after that delay.
    if ProcessInfo.processInfo.environment["SPEKTRALAB_DIAG"] != nil,
       let delay = ProcessInfo.processInfo.environment["SPEKTRALAB_TESTSTRIP"].flatMap(Double.init) {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in self?.openTestStrip() }
    }
    EditModel.current = self
    NotificationCenter.default.addObserver(
      forName: NSApplication.willTerminateNotification, object: nil, queue: .main
    ) { [weak self] _ in
      self?.persistSession()
      self?.spill.removeAll()
    }
    DispatchQueue.global(qos: .utility).async { ThumbCache.trim() }
  }

  /// Settings › Cache › 캐시 비우기: tiles already in memory stay on screen.
  func clearDiskTiles() { spill.clear() }

  // MARK: Session / snapshots

  func persistSession() {
    guard let key = sessionKey, source != nil else { return }
    let history = StoredHistory.enabled && historyCount > 0
      ? StoredHistory(undo: undoStack, redo: redoStack, base: values) : nil
    Sessions.save(EditSession(values: values, snapshots: snapshots, updated: Date(), history: history), key: key)
  }

  private func restoreHistory(_ session: EditSession?, base: [String: ParamValue]) {
    guard StoredHistory.enabled, let stored = session?.history else { return }
    (undoStack, redoStack) = stored.stacks(base: base)
  }

  func addSnapshot(name: String? = nil, values: [String: ParamValue]? = nil) {
    let n = snapshots.count + 1
    let df = DateFormatter()
    df.dateFormat = "HH:mm"
    let label = name ?? tr("스냅샷 \(n)", "Snapshot \(n)") + " · " + df.string(from: Date())
    snapshots.append(EditSnapshot(name: label, date: Date(), values: values ?? self.values))
    persistSession()
  }

  /// Snapshot of the state at timeline position `k` (0: as opened).
  func addSnapshot(atHistory k: Int) {
    guard (0...historyCount).contains(k) else { return }
    addSnapshot(name: tr("스냅샷 \(snapshots.count + 1)", "Snapshot \(snapshots.count + 1)") + " · " + historyName(k),
                values: historyState(k))
  }

  /// Compare views show the state at timeline position `k`.
  func compare(withHistory k: Int) {
    guard (0...historyCount).contains(k) else { return }
    compareBase = .history(historyName(k), historyState(k))
    if compareMode == .off { compareMode = lastSplit }
  }

  func applySnapshot(_ s: EditSnapshot) { apply(s.values, label: tr("스냅샷: ", "Snapshot: ") + s.name) }

  func renameSnapshot(_ s: EditSnapshot, to name: String) {
    guard let i = snapshots.firstIndex(of: s), !name.isEmpty else { return }
    snapshots[i].name = name
    persistSession()
  }

  func deleteSnapshot(_ s: EditSnapshot) {
    snapshots.removeAll { $0.id == s.id }
    if compareBase == .snapshot(s.id) { compareBase = .original }
    persistSession()
  }

  /// Values the compare base renders with, or nil for the untouched original.
  private func referenceValues() -> [String: ParamValue]? {
    switch compareBase {
    case .original: return nil
    case .snapshot(let id): return snapshots.first { $0.id == id }?.values
    case .film(let i):
      var v = values
      v["film"] = .int(i)
      return v
    case .history(_, let v): return v
    }
  }

  var compareLabel: String {
    switch compareBase {
    case .original: return tr("원본", "Original")
    case .snapshot(let id): return snapshots.first { $0.id == id }?.name ?? tr("스냅샷", "Snapshot")
    case .film(let i): return FilmInfo.displayName(Catalog.films[safe: i] ?? "")
    case .history(let name, _): return name
    }
  }

  /// True once the preview and the compare side show the current values (agent capture waits on it).
  var renderSettled: Bool {
    !previewBusy && !previewDirty && (compareMode == .off || referenceValues() == referenceKey)
  }

  /// Image shown on the "before" side of the compare views.
  var compareImage: PixelBuffer? {
    if case .original = compareBase { return before }
    return reference
  }

  /// Engine defaults with the modules the old Python path had on by default.
  static func appDefaults() -> [String: ParamValue] {
    var v: [String: ParamValue] = [:]
    for d in Catalog.params where d.group != "raw" {
      v[d.name] = d.defaultParamValue
    }
    v["grainEnabled"] = .bool(true)
    v["grainModel"] = .int(1)  // Production
    v["halationEnabled"] = .bool(true)
    v["scannerEnabled"] = .bool(true)
    v["scannerMtf50LpMm"] = .double(0)
    v["autoExposure"] = .bool(true)
    return v
  }

  // MARK: Loading

  static let openableTypes: [UTType] = [.image, .rawImage, .tiff, .jpeg, .heic, .png]

  /// File > Open… (standalone).
  func showOpenPanel() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = Self.openableTypes
    panel.message = tr("편집할 사진을 고르세요 (RAW, TIFF, JPEG, HEIC…)", "Choose a photo to edit (RAW, TIFF, JPEG, HEIC…)")
    guard panel.runModal() == .OK, let url = panel.url else { return }
    open(url)
  }

  /// Switches the editor to another photo, keeping each photo's own edit and snapshots.
  func open(_ url: URL) {
    guard standalone, !saving else { return }
    if url == inputURL { return }
    persistSession()
    let key = url.path
    let session = Sessions.load(key)
    let start = session?.values ?? FilmPanel.startValues()
    sessionKey = key
    inputURL = url
    values = start
    committed = start
    snapshots = session?.snapshots ?? []
    resumed = session != nil
    clearPhoto()
    restoreHistory(session, base: start)
    NSDocumentController.shared.noteNewRecentDocumentURL(url)
    load()
  }

  /// File > Close Photo: standalone goes back to the empty window, keeping the edit in its
  /// session; opened from Lightroom it is the same as Cancel.
  func closePhoto() {
    guard standalone else { return cancel() }
    guard inputURL != nil, !saving else { return }
    persistSession()
    let start = FilmPanel.startValues()
    sessionKey = nil
    inputURL = nil
    values = start
    committed = start
    snapshots = []
    resumed = false
    clearPhoto()
  }

  /// Drops everything rendered from the previous photo.
  private func clearPhoto() {
    undoStack = []
    redoStack = []
    loadingURL = nil
    // Stop the running tile job too, not only the queued one: its tiles belong to the old photo.
    detailWork?.cancel()
    detailToken.cancelled = true
    detailQueued = (-1, 0, [])
    detailJob = nil
    detailRendering = false
    detailFailures = 0
    compareFailures = 0
    thumbCancel?.cancelled = true
    generation += 1
    thumbKey = [:]
    freshThumbs = [[], []]
    interacting = false
    referenceKey = nil
    source = nil
    preview = nil
    hoverTarget = nil
    hoverWork?.cancel()
    hoverCache = []
    clearHoverImage()
    before = nil
    detailTiles = []
    spill.clear()
    cancelCompareDetail()
    compareTiles = []
    compareTileKey = nil
    reference = nil
    proxySource = nil
    thumbSource = nil
    draftSource = nil
    filmThumbs = [:]; stepThumbs = [:]
    paperThumbs = [:]
    histogram = Histogram()
    compareBase = .original
    statusText = ""
    notice = nil
  }

  func load() {
    if inputURL == nil, let url = Self.pendingOpen {
      Self.pendingOpen = nil
      open(url)
      return
    }
    guard let url = inputURL, url != loadingURL else { return }
    loadingURL = url
    statusText = tr("불러오는 중…", "Loading…")
    DispatchQueue.global(qos: .userInitiated).async {
      do {
        let src = try SourceImage.load(url)
        let previews = src.previews(proxyEdge: EditModel.proxyEdge, draftEdge: EditModel.draftEdge, thumbEdge: EditModel.thumbEdge)
        let proxy = previews?.proxy, before = previews?.before, thumb = previews?.thumb, draft = previews?.draft
        DispatchQueue.main.async {
          guard url == self.inputURL else { return }
          self.source = src
          self.fullCache.setSource(src)
          self.proxySource = proxy
          self.before = before
          self.thumbSource = thumb
          self.draftSource = draft
          self.statusText = ""
          self.requestPreview()
          self.scheduleThumbnails(immediate: true)
          // Still zoomed in from the last photo: the view may not move, so ask for its tiles here.
          if self.wantsDetail { self.scheduleDetail() }
          // Set the detail engine up in the background so the first zoom does not pay for it.
          let detail = self.detailEngine
          self.detailQueue.asyncAfter(deadline: .now() + 1) { _ = detail.instance }
        }
      } catch {
        DispatchQueue.main.async {
          guard url == self.inputURL else { return }
          self.errorMessage = error.localizedDescription
          if self.standalone {
            self.inputURL = nil
            self.loadingURL = nil
          }
        }
      }
    }
  }

  // MARK: Values / history

  func value(_ name: String) -> ParamValue {
    let cell = cells[name] ?? { let c = ValueCell(); cells[name] = c; return c }()
    _ = cell.bump  // observe this name only, not the whole dictionary
    return _values[name] ?? Catalog.byName[name]?.defaultParamValue ?? .double(0)
  }

  /// Live change (slider drag). Call `commit()` when the gesture ends.
  func set(_ name: String, _ value: ParamValue) {
    guard values[name] != value else { return }
    values[name] = value
    valuesChanged()
  }

  /// Discrete change: applied and recorded at once.
  func setAndCommit(_ name: String, _ value: ParamValue) {
    set(name, value)
    commit()
  }

  /// Next or previous film (or paper) in catalogue order, wrapping around.
  func stepStock(film: Bool, by delta: Int) {
    let name = film ? "film" : "paper"
    let count = film ? Catalog.films.count : Catalog.papers.count
    guard count > 0 else { return }
    setAndCommit(name, .int(((value(name).intValue + delta) % count + count) % count))
  }

  func reset(_ names: [String], label: String? = nil) {
    let defaults = EditModel.appDefaults()
    for n in names { values[n] = defaults[n] ?? Catalog.byName[n]?.defaultParamValue }
    valuesChanged()
    commit(label: label)
  }

  static let defaultValues = appDefaults()

  /// Some of `names` differ from their defaults (the "modified" mark on a module header).
  func isModified(_ names: [String]) -> Bool {
    names.contains { n in
      guard let d = Self.defaultValues[n] ?? Catalog.byName[n]?.defaultParamValue else { return false }
      switch (value(n), d) {
      case let (.double(a), .double(b)): return abs(a - b) > 1e-9
      case let (.vector(a), .vector(b)): return a.count != b.count || zip(a, b).contains { abs($0 - $1) > 1e-9 }
      case let (a, b): return a != b
      }
    }
  }

  func resetAll() {
    values = EditModel.appDefaults()
    valuesChanged()
    commit(label: tr("모두 초기화", "Reset All"))
  }

  func apply(_ newValues: [String: ParamValue], label: String) {
    values = newValues
    valuesChanged()
    commit(label: label)
  }

  /// A drag starts: previews render as drafts until `commit()`.
  func beginInteraction() { interacting = true }

  func commit(label: String? = nil) {
    if interacting {
      interacting = false
      sliderWork?.cancel()
      requestPreview()  // replace the draft with the full proxy render
    }
    settle()
    guard values != committed else { return }
    let text = label ?? changeLabel(from: committed, to: values)
    undoStack.append(HistoryEntry(label: text, values: committed))
    redoStack.removeAll()
    committed = values
  }

  func undo() { moveHistory(to: historyJump(-1)) }
  func redo() { moveHistory(to: historyJump(1)) }

  /// One step back or forward; an AI group counts as one step.
  private func historyJump(_ d: Int) -> Int {
    let k = historyPosition + d, e = d < 0 ? historyPosition : k
    guard e >= 1, e <= historyCount, historyEntry(e).isAI, let g = historyEntry(e).group else { return k }
    let steps = historySteps(inGroup: g.id)
    return d < 0 ? steps.min()! - 1 : steps.max()!
  }

  /// An agent's draft steps replayed on the current state as one collapsed group (one tile, one
  /// delete), plus a snapshot. Names in `keep` stay at the user's value.
  func applyAgentSteps(_ steps: [AgentSession.Step], request: String, source: String, keep: Set<String>) {
    commit()
    let group = StepGroup(name: "✦ AI · " + request, collapsed: true)
    var added = 0
    for s in steps {
      var next = committed
      for (k, v) in s.changes where !keep.contains(k) { next[k] = v }
      guard next != committed else { continue }
      undoStack.append(HistoryEntry(label: s.label, values: committed, group: group, source: source, note: s.note))
      committed = next
      added += 1
    }
    guard added > 0 else { return }
    redoStack.removeAll()
    values = committed
    valuesChanged()
    if UserDefaults.standard.object(forKey: AgentServer.snapshotKey) as? Bool ?? true { addSnapshot(name: "AI · " + request) }
    persistSession()
  }

  // MARK: History timeline
  // Position k = steps applied: 0 is the photo as opened, `historyCount` the latest step. Steps
  // past the marker are the redo stack; changing a value there drops them (commit).

  var historyPosition: Int { undoStack.count }
  var historyCount: Int { undoStack.count + redoStack.count }

  /// Step k (1...historyCount): the entry that moves the state from k-1 to k.
  func historyEntry(_ k: Int) -> HistoryEntry {
    k <= undoStack.count ? undoStack[k - 1] : redoStack[redoStack.count - (k - undoStack.count)]
  }

  /// Values at position k. Undo entries keep the state before their step, redo entries the state after it.
  func historyState(_ k: Int) -> [String: ParamValue] {
    if k == undoStack.count { return committed }
    return k < undoStack.count ? undoStack[k].values : historyEntry(k).values
  }

  func historyName(_ k: Int) -> String {
    k == 0 ? tr("열었을 때", "Opened") : "#\(k) " + historyEntry(k).label
  }

  /// The values a history step changed, for the inspector to open, scroll to and flash; nil clears it.
  struct Spotlight: Equatable { let names: [String]; let id: Int }
  var spotlight: Spotlight?
  private var spotlightCount = 0

  func spotlight(step k: Int?) { spotlight(steps: k.map { $0...$0 }) }

  /// Steps a...b together (a collapsed group): what changed from before a to after b.
  func spotlight(steps r: ClosedRange<Int>?) {
    guard let r, r.lowerBound >= 1, r.upperBound <= historyCount else { spotlight = nil; return }
    let old = historyState(r.lowerBound - 1), new = historyState(r.upperBound)
    let names = Set(old.keys).union(new.keys).filter { old[$0] != new[$0] }.sorted()
    // Film and paper live in the picker on the left, not in a card.
    if names.contains("film") || names.contains("paper") {
      sidebarTab = names.contains("film") ? .film : .paper
      pickerOpen = true
    }
    spotlightCount += 1
    spotlight = Spotlight(names: names, id: spotlightCount)
  }

  /// Moves the marker to position k; one render for the whole jump.
  func moveHistory(to k: Int) {
    let k = min(max(k, 0), historyCount)
    guard k != undoStack.count else { return }
    while undoStack.count > k, let last = undoStack.popLast() {
      redoStack.append(last.with(values: committed))
      committed = last.values
    }
    while undoStack.count < k, let next = redoStack.popLast() {
      undoStack.append(next.with(values: committed))
      committed = next.values
    }
    values = committed
    if interacting { scrubDrafted = true }
    valuesChanged()
  }

  static let scrubPauseKey = "timelineScrubPause"
  static let defaultScrubPause = 0.25
  static var scrubPause: Double { UserDefaults.standard.object(forKey: scrubPauseKey) as? Double ?? defaultScrubPause }
  /// Settings › 슬라이더 끌기 멈춤 시간: 0 draws every value while dragging; above 0 the photo follows
  /// only once the pointer rests that long, and moving on stops the picture being drawn.
  static let sliderPauseKey = "sliderPause"
  static var sliderPause: Double { UserDefaults.standard.double(forKey: sliderPauseKey) }
  @ObservationIgnored private var sliderWork: DispatchWorkItem?
  @ObservationIgnored private var previewDropped = false
  @ObservationIgnored private var scrubbing = false
  private func previewAfterEdit() {
    sliderWork?.cancel()
    guard interacting, !scrubbing, Self.sliderPause > 0 else { requestPreview(); return }
    if previewBusy { previewDropped = true; previewEngine.cancel() }
    let work = DispatchWorkItem { [weak self] in self?.settle(); self?.requestPreview() }
    sliderWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.sliderPause, execute: work)
  }
  @ObservationIgnored private var scrubDrafted = false

  /// Dragging the timeline marker: the timeline only moves `moveHistory` once the marker rests
  /// (`scrubPause`), and those stops render as drafts, like a slider drag.
  func beginHistoryScrub() {
    beginInteraction()
    scrubbing = true
    scrubDrafted = false
  }
  /// Let go at step k: one full render there, none if the marker never moved the photo.
  func endHistoryScrub(at k: Int) {
    interacting = false
    scrubbing = false
    settle()
    if k != historyPosition { moveHistory(to: k) } else if scrubDrafted { requestPreview() }
  }

  // MARK: Editing the history
  // Steps are kept as their own changes (what they set and removed) and replayed from the photo as
  // opened, so a dropped step takes only its own change with it. A step that no longer changes
  // anything after the replay goes away too.

  private struct StepEdit {
    var entry: HistoryEntry
    var changed: [String: ParamValue]
    var removed: [String]
  }

  private func stepEdit(_ r: ClosedRange<Int>, entry: HistoryEntry) -> StepEdit {
    let old = historyState(r.lowerBound - 1), new = historyState(r.upperBound)
    return StepEdit(entry: entry, changed: new.filter { old[$0.key] != $0.value },
                    removed: old.keys.filter { new[$0] == nil })
  }

  private func replayHistory(_ steps: [StepEdit], position: Int) {
    var state = historyState(0)
    var states = [state], kept: [HistoryEntry] = []
    var position = min(max(position, 0), steps.count)
    for (i, s) in steps.enumerated() {
      var next = state
      for k in s.removed { next[k] = nil }
      next.merge(s.changed) { $1 }
      if next == state {
        if i < position { position -= 1 }
        continue
      }
      kept.append(s.entry)
      states.append(next)
      state = next
    }
    // Undo entries keep the state before their step, redo entries the state after it (last step first).
    undoStack = (0..<position).map { kept[$0].with(values: states[$0]) }
    redoStack = (position..<kept.count).reversed().map {
      kept[$0].with(values: states[$0 + 1])
    }
    normalizeGroups()
    committed = states[position]
    if values != committed {
      values = committed
      valuesChanged()
    }
    persistSession()
  }

  /// Drops steps; the later ones are replayed without them.
  func deleteHistorySteps(_ ks: Set<Int>) {
    let ks = ks.filter { (1...max(historyCount, 1)).contains($0) && $0 <= historyCount }
    guard !ks.isEmpty else { return }
    let steps = (1...historyCount).filter { !ks.contains($0) }.map { stepEdit($0...$0, entry: historyEntry($0)) }
    replayHistory(steps, position: historyPosition - ks.filter { $0 <= historyPosition }.count)
  }

  /// Neighbouring steps in a...b that change the same tools, as runs: what compacting merges.
  /// Steps of different tools stay apart (1, 2, 2.1, 3, 1.1, 1.2 → 1, 2.1, 3, 1.2).
  func compactRuns(_ r: ClosedRange<Int>) -> [ClosedRange<Int>] {
    guard r.lowerBound >= 1, r.upperBound <= historyCount else { return [] }
    var runs: [ClosedRange<Int>] = [], tools: Set<String> = []
    for k in r {
      let t = TimelineStage.tools(from: historyState(k - 1), to: historyState(k))
      if let last = runs.last, !t.isEmpty, t == tools { runs[runs.count - 1] = last.lowerBound...k }
      else { runs.append(k...k); tools = t }
    }
    return runs
  }

  /// Each run of same-tool steps in a...b becomes one step holding the last value of every item.
  /// A marker inside a run moves to its end.
  func compactHistorySteps(_ r: ClosedRange<Int>) {
    let merged = compactRuns(r)
    guard merged.contains(where: { $0.count > 1 }) else { return }
    let runs = (1..<r.lowerBound).map { $0...$0 } + merged + (r.upperBound + 1..<historyCount + 1).map { $0...$0 }
    let steps = runs.map { stepEdit($0, entry: $0.count == 1 ? historyEntry($0.lowerBound) : mergedEntry($0)) }
    let p = historyPosition
    replayHistory(steps, position: runs.filter { $0.lowerBound <= p }.count)
  }

  /// The entry for steps a...b merged: each item once, in the order the steps first touched it; an
  /// item that ended where it started drops out.
  private func mergedEntry(_ r: ClosedRange<Int>) -> HistoryEntry {
    let groups = Set(r.map { historyEntry($0).group?.id })
    let old = historyState(r.lowerBound - 1), new = historyState(r.upperBound)
    var order: [String] = []
    for k in r {
      let a = historyState(k - 1), b = historyState(k)
      for n in Set(a.keys).union(b.keys).sorted() where a[n] != b[n] && old[n] != new[n] && !order.contains(n) { order.append(n) }
    }
    let names = order.map { paramLabel($0, new[$0]) }
    let label = names.isEmpty ? tr("변경", "Change")
      : names.prefix(3).joined(separator: ", ") + (names.count > 3 ? tr(" 외 \(names.count - 3)개", " +\(names.count - 3)") : "")
    var entry = HistoryEntry(label: label, values: [:], group: groups.count == 1 ? historyEntry(r.lowerBound).group : nil)
    entry.id = historyEntry(r.upperBound).id
    if Set(r.map { historyEntry($0).source }).count == 1 { entry.source = historyEntry(r.lowerBound).source }
    return entry
  }

  /// Steps a...b go into a new group.
  func groupHistorySteps(_ r: ClosedRange<Int>) {
    guard r.lowerBound >= 1, r.upperBound <= historyCount else { return }
    let used = Set((1...historyCount).compactMap { historyEntry($0).group?.name })
    let n = (1...).first { !used.contains(tr("그룹 \($0)", "Group \($0)")) } ?? 1
    let group = StepGroup(name: tr("그룹 \(n)", "Group \(n)"))
    for k in r { setGroup(of: k, group) }
    normalizeGroups()
    persistSession()
  }

  /// Takes steps out of their groups; a group split in two keeps going as two groups.
  func ungroupHistorySteps(_ ks: Set<Int>) {
    for k in ks where (1...historyCount).contains(k) { setGroup(of: k, nil) }
    normalizeGroups()
    persistSession()
  }

  func historySteps(inGroup id: UUID) -> Set<Int> {
    historyCount == 0 ? [] : Set((1...historyCount).filter { historyEntry($0).group?.id == id })
  }

  func updateHistoryGroup(_ id: UUID, _ change: (inout StepGroup) -> Void) {
    for k in historySteps(inGroup: id) {
      guard var g = historyEntry(k).group else { continue }
      change(&g)
      setGroup(of: k, g)
    }
    persistSession()
  }

  private func setGroup(of k: Int, _ group: StepGroup?) {
    if k <= undoStack.count { undoStack[k - 1].group = group }
    else { redoStack[redoStack.count - (k - undoStack.count)].group = group }
  }

  /// A group is one run of neighbouring steps: a later run of the same group becomes its own group.
  private func normalizeGroups() {
    guard historyCount > 0 else { return }
    var seen: Set<UUID> = [], run: (old: UUID, new: UUID)?
    for k in 1...historyCount {
      guard var g = historyEntry(k).group else { run = nil; continue }
      if g.id != run?.old {
        run = (g.id, seen.contains(g.id) ? UUID() : g.id)
        seen.insert(g.id)
      }
      if let run, g.id != run.new {
        g.id = run.new
        setGroup(of: k, g)
      }
    }
  }

  private func paramLabel(_ n: String, _ v: ParamValue?) -> String {
    if n == "film" { return tr("필름: ", "Film: ") + FilmInfo.displayName(Catalog.films[safe: v?.intValue ?? 0] ?? "") }
    if n == "paper" { return tr("인화지: ", "Paper: ") + FilmInfo.displayName(Catalog.papers[safe: v?.intValue ?? 0] ?? "") }
    return Labels.param(n)
  }

  func changeLabel(from old: [String: ParamValue], to new: [String: ParamValue]) -> String {
    let changed = new.keys.filter { old[$0] != new[$0] }.sorted()
    guard let first = changed.first else { return tr("변경", "Change") }
    let label = paramLabel(first, new[first])
    return changed.count > 1 ? tr("\(label) 외 \(changed.count - 1)개", "\(label) +\(changed.count - 1)") : label
  }

  private func valuesChanged() {
    editClock.touch()
    generation += 1
    detailFailures = 0
    compareFailures = 0
    hoverTarget = nil
    hoverWork?.cancel()
    hoverPendingLabel = nil
    hoverCache = []
    if testStripOn { refreshTestStrip() }
    detailTiles = []
    spill.clear()
    previewAfterEdit()
    if wantsDetail { scheduleDetail() }
    // A film compare base follows the edit; drop its tiles now.
    scheduleCompareDetail()
    scheduleThumbnails(immediate: false)
  }

  // MARK: Preview (coalesced: at most one in flight, latest values win)

  func requestPreview() {
    guard let proxy = proxySource else { return }
    if previewBusy {
      previewDirty = true
      // Another history step now: the picture being drawn will be dropped, so stop drawing it.
      if historyPosition != previewPosition { previewEngine.cancel() }
      return
    }
    previewBusy = true
    previewDirty = false
    // While dragging: half the proxy size and no grain (it would change look with the size anyway).
    let draft = interacting ? draftSource : nil
    var values = values
    if draft != nil { values["grainEnabled"] = .bool(false) }
    let source = draft ?? proxy
    let engine = previewEngine
    let refValues = compareMode == .off ? nil : referenceValues()
    let renderRef = draft == nil && refValues != nil && refValues != referenceKey
    if refValues == nil { referenceKey = nil }
    let position = historyPosition
    previewPosition = position
    previewQueue.async {
      let t0 = CFAbsoluteTimeGetCurrent()
      let result = RenderPipeline.render(
        engine, source: source, values: values, output: ColorSpaceIndex.displayP3, bytesPerComponent: 2)
      let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
      let error = result == nil ? engine.lastError : nil
      let hist = result.map { Self.histogram(of: $0) } ?? Histogram()
      let ref = renderRef ? RenderPipeline.render(
        engine, source: proxy, values: refValues!, output: ColorSpaceIndex.displayP3, bytesPerComponent: 2) : nil
      DispatchQueue.main.async {
        self.previewBusy = false
        // A photo opened meanwhile: drop this result and render the new one.
        guard proxy === self.proxySource else {
          self.requestPreview()
          return
        }
        if let ref {
          self.reference = ref
          self.referenceKey = refValues
        }
        // Moved to another history step meanwhile (timeline, undo): don't flash the old step's
        // picture, the next render shows the new one. Slider drags keep showing every result.
        // Also dropped: a draw the slider moved on from (sliderPause); the next rest draws again.
        let stale = self.previewDropped || self.previewDirty && self.historyPosition != position
        self.previewDropped = false
        if let error, !stale { self.errorMessage = tr("렌더 실패: ", "Render failed: ") + "\(error)" } else if let out = result, !stale {
          self.preview = out
          if self.hoverTarget == nil { self.clearHoverImage() }
          Splash.finish()
          // Drafts: the histogram waits for the full render on release, like the panels.
          if draft == nil { self.histogram = hist; self.recordRenderTime(ms) } else { SliderTrace.render(ms) }
        }
        if self.previewDirty { self.requestPreview() }
      }
    }
  }

  // MARK: Hover preview (film/paper picker)

  struct HoverTarget: Equatable {
    let param: String
    let index: Int
  }

  static let hoverKey = "hoverPreview"

  /// Pointer entered (`inside`) or left a film/paper card. Entering one card before the last one
  /// reports leaving is normal, so leaving only counts for the card that is being shown.
  func hover(_ param: String, _ index: Int, inside: Bool) {
    let target = HoverTarget(param: param, index: index)
    if !inside {
      guard hoverTarget == target else { return }
      endHover()
      return
    }
    guard UserDefaults.standard.object(forKey: Self.hoverKey) as? Bool ?? true,
          proxySource != nil, !saving, value(param).intValue != index else {
      // The chosen card's look is the current one: show it straight away.
      endHover(hold: 0)
      return
    }
    hoverTarget = target
    hoverWork?.cancel()
    hoverLeaveWork?.cancel()
    if let hit = hoverCache.first(where: { $0.target == target }) {
      showHover(hit.buffer, target)
      return
    }
    if hoverPreview != nil, FilmPanel.hoverPendingLabel { hoverPendingLabel = displayName(target) }
    // Sweeping across the cards renders nothing; resting on one does.
    let work = DispatchWorkItem { [weak self] in self?.renderHover() }
    hoverWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + FilmPanel.hoverDelay, execute: work)
  }

  /// The pointer left the card list: back to the current look at once, without the hold.
  func hoverLeftPanel() {
    guard hoverTarget != nil || hoverPreview != nil else { return }
    endHover(hold: 0)
  }

  /// Leaving a card keeps its look for `hold` seconds, so moving on to the next card shows A → B
  /// rather than A → current → B.
  private func endHover(hold: Double = FilmPanel.hoverHold) {
    hoverTarget = nil
    hoverWork?.cancel()
    hoverLeaveWork?.cancel()
    hoverPendingLabel = nil
    guard hold > 0, hoverPreview != nil else { clearUnlessCommitting(); return }
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.hoverTarget == nil else { return }
      self.clearUnlessCommitting()
    }
    hoverLeaveWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + hold, execute: work)
  }

  /// A click on the card is waiting for its render: keep the hover look until it lands.
  private func clearUnlessCommitting() {
    if !previewBusy, !previewDirty { clearHoverImage() }
  }

  private func clearHoverImage() {
    hoverLeaveWork?.cancel()
    hoverPreview = nil
    hoverLabel = nil
    hoverPendingLabel = nil
  }

  private func displayName(_ target: HoverTarget) -> String {
    let names = target.param == "film" ? Catalog.films : Catalog.papers
    var v = values
    v[target.param] = .int(target.index)
    // The mode the pick really runs in, so a slide hovered with Print doesn't pass for a print.
    let mode = ProcessScope.modeNote(v) != nil ? tr("스캔으로 처리", "scanned")
      : ProcessScope.stockReason(film: target.param == "film", v) != nil ? tr("이 모드에서 쓰이지 않음", "unused in this mode") : nil
    return FilmInfo.displayName(names[safe: target.index] ?? "") + (mode.map { " · " + $0 } ?? "")
  }

  private func showHover(_ buffer: PixelBuffer, _ target: HoverTarget) {
    hoverPreview = buffer
    hoverLabel = displayName(target)
    hoverPendingLabel = nil
  }

  private func renderHover() {
    guard let target = hoverTarget, let proxy = proxySource, !hoverBusy else { return }
    hoverBusy = true
    var values = values
    values[target.param] = .int(target.index)
    // Slower Macs preview from the half-size draft so resting on a card answers quickly.
    let source = Performance.lowPower ? (draftSource ?? proxy) : proxy
    let engine = previewEngine
    let gen = generation
    previewQueue.async {
      let result = RenderPipeline.render(
        engine, source: source, values: values, output: ColorSpaceIndex.displayP3, bytesPerComponent: 2)
      DispatchQueue.main.async {
        self.hoverBusy = false
        guard gen == self.generation, proxy === self.proxySource else { return }
        if let result {
          self.hoverCache.removeAll { $0.target == target }
          self.hoverCache.append((target, result))
          if self.hoverCache.count > 3 { self.hoverCache.removeFirst() }
          if self.hoverTarget == target { self.showHover(result, target) }
        }
        // The pointer moved on to another card while this one rendered.
        if let next = self.hoverTarget, next != target, !self.hoverCache.contains(where: { $0.target == next }) {
          self.renderHover()
        }
      }
    }
  }

  // MARK: Darkroom test strip

  /// A test strip only means something when the image is printed through an enlarger.
  var testStripAvailable: Bool { Darkroom.isPrinting(settledValues) }

  /// The strip is kept in the picture (saved and exported); the preview already shows it.
  var testStripEffect: Bool { TestStrip.effectOn(settledValues) }

  /// The strip is on screen, as a tool or as the effect: the module switch and T.
  var testStripShown: Bool { testStripOn || testStripEffect }

  func toggleTestStrip() { testStripShown ? hideTestStrip() : openTestStrip() }

  /// Shows the strip as a tool: rendered from the proxy over the preview, never saved.
  func openTestStrip() {
    guard testStripAvailable, !testStripEffect, let proxy = proxySource, !saving else { return }
    testStripOn = true
    testStripImage = nil
    testStripToken += 1
    let token = testStripToken
    testStripCancel.cancelled = true
    let flag = CancelFlag()
    testStripCancel = flag
    let values = values
    let source = Performance.lowPower ? (draftSource ?? proxy) : proxy
    let engine = previewEngine
    let gen = generation
    previewQueue.async {
      guard !flag.cancelled else { return }
      let strip = TestStrip.render(engine, source: source, values: values, output: ColorSpaceIndex.displayP3, bytesPerComponent: 2)
      DispatchQueue.main.async {
        guard token == self.testStripToken, gen == self.generation, self.testStripOn else { return }
        self.testStripImage = strip
      }
    }
  }

  /// Hides the strip whichever way it is shown (the effect is switched off too).
  func hideTestStrip() {
    if values["testStripEffect"]?.boolValue == true { setAndCommit("testStripEffect", .bool(false)) }
    closeTestStrip()
  }

  func closeTestStrip() {
    testStripToken += 1
    testStripCancel.cancelled = true
    testStripWork?.cancel()
    testStripOn = false
    testStripImage = nil
  }

  /// After an edit: drop the stale bands and draw them again once the sliders rest.
  /// The tool strip goes away when the image is no longer printed, or the effect takes over.
  private func refreshTestStrip() {
    if testStripEffect { closeTestStrip(); return }
    testStripToken += 1
    testStripCancel.cancelled = true
    testStripImage = nil
    testStripWork?.cancel()
    let work = DispatchWorkItem { [weak self] in
      guard let self, self.testStripOn else { return }
      self.testStripAvailable ? self.openTestStrip() : self.closeTestStrip()
    }
    testStripWork = work
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
  }

  /// The band under a point given as fractions of the image (x from the left, y from the top).
  func testStripBand(x: Double, y: Double) -> Int { TestStrip.Config(values).band(x: x, y: y) }

  /// Use band `index` as the print exposure; the strip stays, now centred on it.
  func pickTestStrip(_ index: Int) {
    guard testStripShown else { return }
    let c = TestStrip.Config(values)
    guard c.offsets.indices.contains(index) else { return }
    setAndCommit(c.param, .double((c.value(index, values) * 1000).rounded() / 1000))
  }

  private func recordRenderTime(_ ms: Double) {
    guard engineWarm else {
      engineWarm = true
      return
    }
    renderSamples.append(ms)
    if renderSamples.count > 5 { renderSamples.removeFirst() }
    renderMs = renderSamples.sorted()[renderSamples.count / 2]
  }

  static func histogram(of buffer: PixelBuffer) -> Histogram {
    let n = 128
    var counts = [[Int]](repeating: [Int](repeating: 0, count: n), count: 3)
    var low = 0, high = 0, total = 0
    let px = buffer.data.assumingMemoryBound(to: UInt16.self)
    let step = max(1, Int(sqrt(Double(buffer.width * buffer.height) / 250_000)))
    for y in stride(from: 0, to: buffer.height, by: step) {
      let row = px + y * buffer.width * 4
      for x in stride(from: 0, to: buffer.width, by: step) {
        var clipLow = true, clipHigh = false
        for c in 0..<3 {
          let v = halfToFloat(row[x * 4 + c])
          counts[c][min(n - 1, max(0, Int(v * Float(n))))] += 1
          if v > 0.002 { clipLow = false }
          if v >= 0.998 { clipHigh = true }
        }
        if clipLow { low += 1 }
        if clipHigh { high += 1 }
        total += 1
      }
    }
    // Ignore the two end bins when scaling so clipped spikes do not flatten the curve.
    let peak = max(1, counts.flatMap { $0[1..<(n - 1)] }.max() ?? 1)
    var h = Histogram()
    h.bins = counts.map { ch in ch.map { min(1, Float($0) / Float(peak)) } }
    h.shadowClip = Double(low) / Double(max(total, 1)) * 100
    h.highlightClip = Double(high) / Double(max(total, 1)) * 100
    return h
  }

  // MARK: Full-resolution detail render (for zoom beyond the proxy)

  var proxyScale: Double {
    guard let s = source, let p = proxySource else { return 1 }
    return Double(p.width) / Double(s.width)
  }

  /// Tile side in source pixels. Small tiles on slower Macs show up sooner and let zooming out
  /// stop the work between tiles.
  private var detailTileEdge: CGFloat { Performance.lowPower ? 768 : 2048 }

  /// Picks the detail scale for a zoom (device pixels per source pixel): the smallest of 1, 1/2,
  /// 1/4 that is at most ~10% enlarged on screen and still sharper than the proxy.
  static func detailScale(zoom: Double, proxyScale: Double) -> Double {
    var m = 1.0
    while m / 2 * 1.1 >= zoom, m / 2 > proxyScale * 1.2 { m /= 2 }
    return m
  }

  /// Grid tiles needed to show `rect`, nearest to its centre first. The grid is laid on the
  /// source scaled by `detailScale`; the cells come back in full-size source pixels.
  private func detailCells(for rect: CGRect, frame: CGRect, regions: Bool? = nil) -> [CGRect] {
    guard regions ?? RenderPipeline.supportsRegion(values) else { return [frame] }
    let r = rect.intersection(frame)
    guard !r.isEmpty else { return [] }
    let e = detailTileEdge / detailScale
    var cells: [CGRect] = []
    for row in Int(r.minY / e)...Int((r.maxY - 1) / e) {
      for col in Int(r.minX / e)...Int((r.maxX - 1) / e) {
        cells.append(CGRect(x: CGFloat(col) * e, y: CGFloat(row) * e, width: e, height: e).intersection(frame))
      }
    }
    let c = CGPoint(x: rect.midX, y: rect.midY)
    return cells.sorted { hypot($0.midX - c.x, $0.midY - c.y) < hypot($1.midX - c.x, $1.midY - c.y) }
  }

  /// Drops tiles so a long pan over a big photo does not keep the whole frame in memory. Tiles
  /// coarser than the current scale (what Fit and middle zooms show) have their own ~20 MP, so
  /// zooming in never pushes them out and zooming back out renders nothing again; the current
  /// scale and finer ones share ~28 MP. Each pool drops tiles away from the view first, farthest
  /// first, then finer scales over the view; tiles the current view and its margin need are kept.
  private func pruneDetailTiles(keep: CGRect) {
    let c = CGPoint(x: viewport.midX, y: viewport.midY)
    func pixels(_ t: DetailTile) -> Int { t.buffer.width * t.buffer.height }
    func distance(_ t: DetailTile) -> CGFloat { hypot(t.region.midX - c.x, t.region.midY - c.y) }
    var drop = IndexSet()
    for (coarse, budget) in [(true, 20_000_000), (false, 28_000_000)] {
      let pool = detailTiles.enumerated().filter { ($0.element.scale < detailScale) == coarse }
      var total = pool.reduce(0) { $0 + pixels($1.element) }
      guard total > budget else { continue }
      let candidates = pool
        .filter { $0.element.scale != detailScale || !$0.element.region.intersects(keep) }
        .sorted { a, b in
          let ai = a.element.region.intersects(keep), bi = b.element.region.intersects(keep)
          if ai != bi { return !ai }
          if ai, a.element.scale != b.element.scale { return a.element.scale > b.element.scale }
          return distance(a.element) > distance(b.element)
        }
      for (i, t) in candidates where total > budget {
        drop.insert(i)
        total -= pixels(t)
      }
    }
    guard !drop.isEmpty else { return }
    for i in drop { spill.store(detailTiles[i].buffer, key: .init(detailTiles[i].region, scale: detailTiles[i].scale)) }
    detailTiles.remove(atOffsets: drop)
  }

  private func hasTile(_ cell: CGRect) -> Bool {
    detailTiles.contains { $0.scale == detailScale && $0.region.insetBy(dx: -1, dy: -1).contains(cell) }
  }

  private func detailCovers(_ rect: CGRect) -> Bool {
    guard let s = source, !rect.isEmpty else { return true }
    return detailCells(for: rect, frame: CGRect(x: 0, y: 0, width: s.width, height: s.height)).allSatisfy(hasTile)
  }

  /// Renders the missing tiles around the viewport, centre first, publishing each as it is done.
  /// Panning or zooming out cancels the rest; an edit starts over.
  func scheduleDetail(delay: Double = 0.35) {
    // After a few failures panning asks for nothing more until the edit or the photo changes.
    guard let s = source, detailFailures <= 3 else { return }
    let frame = CGRect(x: 0, y: 0, width: s.width, height: s.height)
    let v = viewport.isEmpty ? frame : viewport.intersection(frame)
    // The visible tiles first, then a margin so small pans need nothing new.
    let margin = v.insetBy(dx: -max(256, v.width * 0.25), dy: -max(256, v.height * 0.25))
    var all = detailCells(for: v, frame: frame)
    // In the compare views the other side's visible tiles come before this side's margin.
    refreshCompareKey()
    if missingCompareCells().isEmpty {
      for cell in detailCells(for: margin, frame: frame) where !all.contains(cell) { all.append(cell) }
    }
    let have = all.filter(hasTile)
    let cells = all.filter { !hasTile($0) }
    guard !cells.isEmpty else {
      // Everything here is rendered; what a running job still has queued was for an older view
      // (a zoom caught halfway), so stop it rather than keep the pill up for tiles nobody sees.
      if detailQueued.generation >= 0 {
        detailWork?.cancel()
        detailToken.cancelled = true
        detailQueued = (-1, 0, [])
        detailRendering = false
        if detailJob?.finished == false { detailJob = nil }
      }
      scheduleCompareDetail()
      return
    }
    // Tiles kept on disk come back in a moment, so they need no pill either.
    let quiet = detailCells(for: v, frame: frame).allSatisfy { hasTile($0) || spill.contains(.init($0, scale: detailScale)) }
    // Panned onto tiles a quiet margin job is still rendering: show it from here on.
    if !quiet, detailJob?.quiet == true, detailQueued.cells.contains(where: { cells.contains($0) }) { detailJob?.quiet = false }
    // A small pan whose missing tiles are already queued: let the running job go on, unless it
    // still has many tiles this view no longer needs (it was queued for a wider view).
    if !detailToken.cancelled, detailQueued.generation == generation, detailQueued.scale == detailScale,
       cells.allSatisfy(detailQueued.cells.contains),
       detailQueued.cells.filter({ !hasTile($0) }).count <= cells.count + max(4, cells.count / 2) { return }
    detailWork?.cancel()
    detailToken.cancelled = true
    // The current edit goes first; the compare side carries on once its tiles are in.
    cancelCompareDetail()
    let token = CancelFlag()
    detailToken = token
    let gen = generation
    let values = values
    let src = s.image
    let scale = detailScale
    let keep = margin
    detailQueued = (gen, scale, cells)
    detailJobCount += 1
    // Tiles already there count as done, so coming back to a half-rendered view picks up the count.
    var job = DetailJob(id: detailJobCount, cells: have + cells, done: have.count)
    job.quiet = quiet
    let work = DispatchWorkItem { [weak self] in
      guard let self, !token.cancelled else { return }
      DispatchQueue.main.async {
        guard self.detailToken === token else { return }
        self.detailRendering = true
        self.detailJob = job
      }
      defer {
        DispatchQueue.main.async {
          guard self.detailToken === token else { return }
          self.detailRendering = false
          self.detailQueued = (-1, 0, [])
          if let j = self.detailJob, j.id == job.id, !j.finished { self.detailJob = nil }
        }
      }
      func publish(_ out: PixelBuffer, _ cell: CGRect) {
        DispatchQueue.main.async {
          guard gen == self.generation, src === self.source?.image else { return }
          // A job cancelled late can hand in a tile the next job also rendered; keep one.
          self.detailTiles.removeAll { $0.scale == scale && $0.region == cell }
          self.detailTiles.append(DetailTile(buffer: out, region: cell, scale: scale))
          self.pruneDetailTiles(keep: keep)
          if self.detailJob?.id == job.id { self.detailJob?.done += 1 }
        }
      }
      // Tiles seen before come back from disk first, without loading the original.
      var rest: [CGRect] = []
      for cell in cells {
        guard !token.cancelled else { return }
        if let out = self.spill.load(.init(cell, scale: scale)) { publish(out, cell) } else { rest.append(cell) }
      }
      // A tile that fails to render is skipped, not the rest of the job; the missing ones are
      // asked for again below, so a hiccup never leaves a block of the proxy on screen.
      var failure: String?
      if !rest.isEmpty {
        if let full = self.fullCache.get(scale: scale) {
          let engine = self.detailEngine.instance
          let pre = rest.count > 1 ? RenderPipeline.preEffects(full, values: values) : nil
          let levelFrame = CGRect(x: 0, y: 0, width: full.width, height: full.height)
          DispatchQueue.main.async { if self.detailJob?.id == job.id { self.detailJob?.loading = false } }
          for cell in rest {
            guard !token.cancelled else { return }
            let region = CGRect(x: cell.minX * scale, y: cell.minY * scale, width: cell.width * scale, height: cell.height * scale)
              .integral.intersection(levelFrame)
            let out = cell == frame
              ? RenderPipeline.render(engine, source: full, values: values, output: ColorSpaceIndex.displayP3, bytesPerComponent: 2)
              : RenderPipeline.render(
                engine, source: full, region: region, values: values, output: ColorSpaceIndex.displayP3, bytesPerComponent: 2,
                preApplied: pre)
            if let out { publish(out, cell) } else { failure = engine.lastError.isEmpty ? "tile render failed" : engine.lastError }
          }
        } else {
          failure = "full-size source unavailable"
        }
      }
      if let failure { FileHandle.standardError.write("detail tiles: \(failure)\n".data(using: .utf8)!) }
      DispatchQueue.main.async {
        if failure != nil, gen == self.generation {
          self.detailFailures += 1
          if self.detailFailures > 3 { self.errorMessage = tr("확대 렌더 실패: ", "Zoomed render failed: ") + (failure ?? "") }
        }
        // Leave the finished pill up for a moment, then let it go.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
          if let j = self.detailJob, j.id == job.id, j.finished { self.detailJob = nil }
        }
        if self.detailToken === token { self.detailQueued = (-1, 0, []) }
        // Panned on while this was rendering.
        if self.detailToken === token, self.wantsDetail, !self.detailCovers(self.viewport), self.detailFailures <= 3 {
          self.scheduleDetail(delay: failure == nil ? 0.05 : 0.5)
        } else if self.detailToken === token {
          self.scheduleCompareDetail(delay: 0.05)
        }
      }
    }
    detailWork = work
    detailQueue.asyncAfter(deadline: .now() + delay, execute: work)
  }

  private func cancelCompareDetail() {
    compareToken.cancelled = true
    compareQueued = []
  }

  /// Renders the compare base's tiles for the part of it on screen, once the current edit's
  /// tiles are done: the original is the full-size source converted for display, a snapshot or
  /// another film is rendered like the edit.
  func scheduleCompareDetail(delay: Double = 0.35) {
    guard let s = source else { return }
    let key = refreshCompareKey()
    guard wantsDetail, compareMode != .off, detailQueued.generation < 0, compareFailures <= 3 else { return }
    let frame = CGRect(x: 0, y: 0, width: s.width, height: s.height)
    let scale = detailScale
    let ref = key.values
    let cells = missingCompareCells()
    guard !cells.isEmpty else { return }
    if !compareToken.cancelled, cells.allSatisfy(compareQueued.contains) { return }
    compareToken.cancelled = true
    let token = CancelFlag()
    compareToken = token
    compareQueued = cells
    let src = s.image
    let work = DispatchWorkItem { [weak self] in
      guard let self, !token.cancelled, let full = self.fullCache.get(scale: scale) else { return }
      defer { DispatchQueue.main.async { if self.compareToken === token { self.compareQueued = [] } } }
      let levelFrame = CGRect(x: 0, y: 0, width: full.width, height: full.height)
      let engine = ref == nil ? nil : self.detailEngine.instance
      let pre = ref.flatMap { cells.count > 1 && cells[0] != frame ? RenderPipeline.preEffects(full, values: $0) : nil }
      // A tile that fails is skipped, not the rest; the missing ones are asked for again below.
      var failed = false
      for cell in cells {
        guard !token.cancelled else { return }
        let region = CGRect(x: cell.minX * scale, y: cell.minY * scale, width: cell.width * scale, height: cell.height * scale)
          .integral.intersection(levelFrame)
        let out: PixelBuffer?
        if let ref, let engine {
          out = cell == frame
            ? RenderPipeline.render(engine, source: full, values: ref, output: ColorSpaceIndex.displayP3, bytesPerComponent: 2)
            : RenderPipeline.render(
              engine, source: full, region: region, values: ref, output: ColorSpaceIndex.displayP3, bytesPerComponent: 2,
              preApplied: pre)
        } else {
          out = full.cropped(to: region).flatMap(SourceImage.displayCopy(of:))
        }
        guard let out else { failed = true; continue }
        DispatchQueue.main.async {
          guard self.compareToken === token, src === self.source?.image else { return }
          self.compareTiles.append(DetailTile(buffer: out, region: cell, scale: scale))
          self.pruneCompareTiles()
        }
      }
      DispatchQueue.main.async {
        guard self.compareToken === token else { return }
        self.compareQueued = []
        if failed { self.compareFailures += 1 }
        // Panned on while this was rendering; otherwise the current edit's pan margin is next.
        if self.missingCompareCells().isEmpty || self.compareFailures > 3 {
          if self.wantsDetail { self.scheduleDetail(delay: 0.05) }
        } else {
          self.scheduleCompareDetail(delay: failed ? 0.5 : 0.05)
        }
      }
    }
    detailQueue.asyncAfter(deadline: .now() + delay, execute: work)
  }

  /// Drops the compare tiles when the base or the photo changed.
  @discardableResult private func refreshCompareKey() -> CompareTileKey {
    let key = CompareTileKey(values: referenceValues(), image: source.map { ObjectIdentifier($0.image) })
    if key != compareTileKey {
      cancelCompareDetail()
      compareFailures = 0
      compareTiles = []
      compareTileKey = key
    }
    return key
  }

  /// Compare tiles the part of the compare image on screen still needs, centre first.
  private func missingCompareCells() -> [CGRect] {
    guard let s = source, compareMode != .off, let key = compareTileKey else { return [] }
    let frame = CGRect(x: 0, y: 0, width: s.width, height: s.height)
    let v = compareViewport.isEmpty ? viewport.intersection(frame) : compareViewport.intersection(frame)
    guard !v.isEmpty else { return [] }
    let scale = detailScale
    return detailCells(for: v, frame: frame, regions: key.values.map(RenderPipeline.supportsRegion) ?? true)
      .filter { c in !compareTiles.contains { $0.scale == scale && $0.region.insetBy(dx: -1, dy: -1).contains(c) } }
  }

  /// Keeps the compare tiles to ~28 MP: other scales first, then farthest from the view.
  private func pruneCompareTiles() {
    let budget = 28_000_000
    func pixels(_ t: DetailTile) -> Int { t.buffer.width * t.buffer.height }
    var total = compareTiles.reduce(0) { $0 + pixels($1) }
    guard total > budget else { return }
    let v = compareViewport.isEmpty ? viewport : compareViewport
    let c = CGPoint(x: v.midX, y: v.midY)
    let order = compareTiles.indices.sorted { a, b in
      let ta = compareTiles[a], tb = compareTiles[b]
      if (ta.scale == detailScale) != (tb.scale == detailScale) { return ta.scale != detailScale }
      return hypot(ta.region.midX - c.x, ta.region.midY - c.y) > hypot(tb.region.midX - c.x, tb.region.midY - c.y)
    }
    var drop = IndexSet()
    for i in order where total > budget {
      drop.insert(i)
      total -= pixels(compareTiles[i])
    }
    compareTiles.remove(atOffsets: drop)
  }

  /// Full-res linear source, decoded on first use. Call off the main thread.
  private func fullSourceBlocking() -> PixelBuffer? { fullCache.get() }

  // MARK: Thumbnails (film and paper browser)

  /// Engine stages too small to see at thumbnail size: switched off for thumbnails, and
  /// changing them does not re-render the browser.
  private static let thumbSkippedGroups: Set<String> = ["grain", "halation", "diffusion"]
  private static let thumbIgnored: Set<String> = Set(
    Catalog.engineParams.filter { thumbSkippedGroups.contains($0.group) }.map(\.name)
  ).union(AppParams.names).union(["film", "paper"])

  /// The stock browser reports which thumbnails it shows; others wait until shown.
  func showThumbnails(_ indices: [Int], film: Bool) {
    let kind = film ? 0 : 1
    guard wantedThumbs[kind] != indices else { return }
    wantedThumbs[kind] = indices
    scheduleThumbnails(immediate: true)
  }

  /// Settings › 카드 썸네일에 편집 반영 was switched.
  func refreshThumbnails() { scheduleThumbnails(immediate: true) }

  private func scheduleThumbnails(immediate: Bool) {
    // Thumbnails skip the app-side effects and the fine-detail stages, so those values do not invalidate them.
    let look = FilmPanel.thumbsFollowEdits ? values
      : Self.appDefaults().merging(values.filter { FilmPanel.thumbFixedKeys.contains($0.key) }) { $1 }
    let key = look.filter { !Self.thumbIgnored.contains($0.key) }
    let keyChanged = key != thumbKey
    if keyChanged {
      thumbKey = key
      freshThumbs = [[], []]
    }
    // The current film and paper are always wanted: the recipe bar shows them.
    let current = [values["film"]?.intValue ?? 0, values["paper"]?.intValue ?? 0]
    let jobs = (0..<2).flatMap { kind in
      ([current[kind]] + wantedThumbs[kind].filter { $0 != current[kind] })
        .filter { !freshThumbs[kind].contains($0) }.map { (kind, $0) }
    }
    // Unchanged look: keep the work in flight unless a new film or paper was picked.
    if !keyChanged && !immediate && current == scheduledCurrent { return }
    scheduledCurrent = current
    thumbWork?.cancel()
    thumbCancel?.cancelled = true
    guard let src = thumbSource, !jobs.isEmpty else {
      thumbsPending = false
      return
    }
    thumbsPending = true
    var base = look
    for name in ["grainEnabled", "halationEnabled", "cameraDiffusionEnabled", "printDiffusionEnabled"] {
      base[name] = .bool(false)
    }
    let engine = thumbEngine
    let flag = CancelFlag()
    thumbCancel = flag
    let clock = editClock
    let cacheKey = source.flatMap { ThumbCache.key(for: $0.url, values: key, edge: src.width) }
    let work = DispatchWorkItem { [weak self] in
      func publish(_ image: CGImage, _ kind: Int, _ i: Int) {
        DispatchQueue.main.async {
          guard let self, !flag.cancelled else { return }
          if kind == 0 { self.filmThumbs[i] = image } else { self.paperThumbs[i] = image }
          self.freshThumbs[kind].insert(i)
        }
      }
      // Ones rendered before come straight from disk.
      var remaining: [(Int, Int)] = []
      for (kind, i) in jobs {
        if let cacheKey, let image = ThumbCache.load(cacheKey, kind: kind, index: i) {
          publish(image, kind, i)
        } else {
          remaining.append((kind, i))
        }
      }
      for (kind, i) in remaining {
        // Hold off while edits are coming in.
        while clock.idle < 0.8, !flag.cancelled { usleep(100_000) }
        if flag.cancelled || self == nil { return }
        var v = base
        v[kind == 0 ? "film" : "paper"] = .int(i)
        let out = PixelBuffer(width: src.width, height: src.height, bytesPerComponent: 2)
        guard engine.instance.render(src, into: out, params: Catalog.renderParams(v, output: ColorSpaceIndex.displayP3)),
              let image = PixelImage.cgImage(halfP3: out)
        else { continue }
        publish(image, kind, i)
        if let cacheKey { ThumbCache.store(image, key: cacheKey, kind: kind, index: i) }
      }
      if !remaining.isEmpty { ThumbCache.trim() }
      DispatchQueue.main.async {
        guard let self, !flag.cancelled else { return }
        self.thumbsPending = false
      }
    }
    thumbWork = work
    thumbQueue.asyncAfter(deadline: .now() + (immediate ? 0.2 : 1.2), execute: work)
  }

  func wantStepThumb(_ k: Int) {
    let state = historyState(k)
    if stepThumbs[k]?.state == state { return }
    guard let src = thumbSource else { return }
    var v = state
    for name in ["grainEnabled", "halationEnabled", "cameraDiffusionEnabled", "printDiffusionEnabled"] { v[name] = .bool(false) }
    let engine = thumbEngine
    thumbQueue.async { [weak self] in
      let out = PixelBuffer(width: src.width, height: src.height, bytesPerComponent: 2)
      guard engine.instance.render(src, into: out, params: Catalog.renderParams(v, output: ColorSpaceIndex.displayP3)),
            let image = PixelImage.cgImage(halfP3: out) else { return }
      DispatchQueue.main.async { self?.stepThumbs[k] = (state, image) }
    }
  }

  // MARK: Save / cancel

  func save() {
    if standalone { showExportPanel(); return }
    guard let src = source, !saving else { return }
    let output = outputURL ?? Self.defaultOutput(for: src.url)
    saving = true
    statusText = tr("전체 해상도로 렌더링 중…", "Rendering at full resolution…")
    let values = values
    Presets.saveLast(values)
    let lazyEngine = detailEngine
    detailWork?.cancel()
    detailQueue.async {
      let engine = lazyEngine.instance
      do {
        guard let full = self.fullSourceBlocking() else { throw ImageFileError.unreadable(src.url.path) }
        guard let out = RenderPipeline.render(
          engine, source: full, values: values, output: ColorSpaceIndex.proPhoto, bytesPerComponent: 4)
        else {
          throw NSError(domain: "PhotoEmul", code: 1, userInfo: [NSLocalizedDescriptionKey: tr("렌더 실패: ", "Render failed: ") + engine.lastError])
        }
        DispatchQueue.main.async { self.statusText = tr("TIFF 저장 중…", "Writing TIFF…") }
        try TiffWriter.writeProPhoto16(out, to: output, properties: src.properties)
        let rest = Array(self.batch.dropFirst())
        for (i, item) in rest.enumerated() {
          DispatchQueue.main.async {
            self.statusText = tr("일괄 처리 중… ", "Batch rendering… ") + "\(i + 2)/\(rest.count + 1)"
          }
          try Self.renderFile(item, values: values, engine: engine)
          // Keep that photo's own snapshots and history; its current edit becomes the batch edit.
          Sessions.replaceValues(values, key: item.key, label: tr("여러 사진에 적용", "Batch Apply"))
        }
        DispatchQueue.main.async { NSApp.terminate(nil) }
      } catch {
        DispatchQueue.main.async {
          self.saving = false
          self.statusText = ""
          self.errorMessage = error.localizedDescription
        }
      }
    }
  }

  /// Cancel quits without sending anything back; AppDelegate asks first (confirmQuit).
  func cancel() { NSApp.terminate(nil) }

  /// Every quit in Lightroom mode (Cancel, ⌘W, ⌘Q, the red close button) sends nothing back,
  /// so ask first once there is an edit. After a save (`saving` stays true) it just quits.
  func confirmQuit() -> Bool {
    if !standalone, !saving, !undoStack.isEmpty || AgentSession.shared.active {
      let alert = NSAlert()
      alert.messageText = tr("저장하지 않고 닫을까요?", "Close without saving?")
      alert.informativeText = tr("결과가 Lightroom으로 가지 않습니다. 편집 기록은 남아서 다시 열면 이어서 할 수 있습니다.",
                                 "Nothing goes back to Lightroom. The edit history stays, so reopening picks up where you left off.")
      alert.addButton(withTitle: tr("계속 편집", "Keep Editing"))
      alert.addButton(withTitle: tr("닫기", "Close")).hasDestructiveAction = true
      return alert.runModal() == .alertSecondButtonReturn
    }
    return true
  }

  // MARK: Standalone export

  /// Save panel with a format choice; renders at full resolution and keeps the editor open.
  func showExportPanel() {
    guard let src = source, !saving else { return }
    let panel = NSSavePanel()
    let picker = NSPopUpButton(frame: .zero, pullsDown: false)
    picker.addItems(withTitles: ExportFormat.allCases.map(\.title))
    picker.selectItem(at: ExportFormat.allCases.firstIndex(of: exportFormat) ?? 0)
    let label = NSTextField(labelWithString: tr("형식:", "Format:"))
    let row = NSStackView(views: [label, picker])
    row.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
    panel.accessoryView = row
    let chooser = FormatChooser(panel: panel, stem: ExportOptions.stem(for: src.url, values: values))
    picker.target = chooser
    picker.action = #selector(FormatChooser.changed(_:))
    chooser.apply(exportFormat)
    panel.directoryURL = ExportOptions.directory(for: src.url)
    guard panel.runModal() == .OK, let url = panel.url else { return }
    exportFormat = chooser.format
    export(to: url, format: chooser.format)
  }

  func export(to output: URL, format: ExportFormat) {
    guard let src = source, !saving else { return }
    saving = true
    statusText = tr("전체 해상도로 렌더링 중…", "Rendering at full resolution…")
    let values = values
    Presets.saveLast(values)
    persistSession()
    let lazyEngine = detailEngine
    detailWork?.cancel()
    detailQueue.async {
      let engine = lazyEngine.instance
      do {
        guard let full = self.fullSourceBlocking() else { throw ImageFileError.unreadable(src.url.path) }
        guard let out = RenderPipeline.render(engine, source: full, values: values, output: format.colorSpace, bytesPerComponent: 4)
        else {
          throw NSError(domain: "PhotoEmul", code: 1, userInfo: [NSLocalizedDescriptionKey: tr("렌더 실패: ", "Render failed: ") + engine.lastError])
        }
        DispatchQueue.main.async { self.statusText = tr("파일 쓰는 중…", "Writing file…") }
        try format.write(out, to: output, properties: src.properties)
        DispatchQueue.main.async {
          self.saving = false
          self.statusText = ""
          self.notice = tr("저장됨: ", "Saved: ") + output.lastPathComponent
          self.lastExport = output
        }
      } catch {
        DispatchQueue.main.async {
          self.saving = false
          self.statusText = ""
          self.errorMessage = error.localizedDescription
        }
      }
    }
  }

  /// Short confirmation shown in the status bar after an export.
  var notice: String?
  private(set) var lastExport: URL?
  private(set) var batchProgress: String?

  /// "Apply to other photos…": renders the current edit onto chosen photos into a folder.
  func applyToOtherPhotos() {
    guard !saving else { return }
    let pick = NSOpenPanel()
    pick.allowedContentTypes = Self.openableTypes
    pick.allowsMultipleSelection = true
    pick.message = tr("지금 편집을 적용할 사진들을 고르세요", "Choose the photos to apply this edit to")
    pick.prompt = tr("선택", "Choose")
    guard pick.runModal() == .OK, !pick.urls.isEmpty else { return }
    let folder = NSOpenPanel()
    folder.canChooseFiles = false
    folder.canChooseDirectories = true
    folder.canCreateDirectories = true
    folder.message = tr("저장할 폴더를 고르세요 (형식: ", "Choose the output folder (format: ") + exportFormat.title + ")"
    folder.prompt = tr("여기에 저장", "Save Here")
    folder.directoryURL = ExportOptions.directory(for: pick.urls[0])
    guard folder.runModal() == .OK, let dir = folder.url else { return }
    let format = exportFormat
    let values = values
    var items: [BatchItem] = []
    for url in pick.urls {
      var output = ExportOptions.uniqueOutput(in: dir, stem: ExportOptions.stem(for: url, values: values), ext: format.fileExtension)
      // Two photos named alike must not share a not-yet-written output.
      var n = 2
      while items.contains(where: { $0.output == output }) {
        output = dir.appendingPathComponent("\(output.deletingPathExtension().lastPathComponent)-\(n).\(format.fileExtension)")
        n += 1
      }
      items.append(BatchItem(input: url, output: output, key: url.path))
    }
    saving = true
    let engine = SpektraEngine()
    DispatchQueue.global(qos: .userInitiated).async {
      var failed: [String] = []
      for (i, item) in items.enumerated() {
        DispatchQueue.main.async { self.statusText = tr("여러 사진에 적용 중… ", "Applying to photos… ") + "\(i + 1)/\(items.count)" }
        do {
          try Self.renderFile(item, values: values, engine: engine, format: format)
          // Keep that photo's own snapshots and history; its current edit becomes the batch edit.
          Sessions.replaceValues(values, key: item.key, label: tr("여러 사진에 적용", "Batch Apply"))
        } catch {
          failed.append(item.input.lastPathComponent)
        }
      }
      DispatchQueue.main.async {
        self.saving = false
        self.statusText = ""
        self.notice = tr("\(items.count - failed.count)장 저장됨", "Saved \(items.count - failed.count) photos")
        self.lastExport = items.first?.output
        if !failed.isEmpty { self.errorMessage = tr("처리하지 못한 사진:\n", "Could not process:\n") + failed.joined(separator: "\n") }
      }
    }
  }

  /// Full-resolution render of one file with fixed values (batch and headless use).
  static func renderFile(_ item: BatchItem, values: [String: ParamValue], engine: SpektraEngine, format: ExportFormat = .tiff16) throws {
    let src = try SourceImage.load(item.input)
    guard let pixels = src.linearPixels() else { throw ImageFileError.unreadable(item.input.path) }
    guard let out = RenderPipeline.render(
      engine, source: pixels, values: values, output: format.colorSpace, bytesPerComponent: 4)
    else {
      throw NSError(domain: "PhotoEmul", code: 1, userInfo: [NSLocalizedDescriptionKey: tr("렌더 실패: ", "Render failed: ") + engine.lastError])
    }
    try format.write(out, to: item.output, properties: src.properties)
  }

  static func defaultOutput(for input: URL) -> URL {
    ExportOptions.uniqueOutput(in: input.deletingLastPathComponent(), stem: input.deletingPathExtension().lastPathComponent + "-photoemul", ext: "tif")
  }
}

/// Keeps the save panel's file type and extension in step with the format popup.
final class FormatChooser: NSObject {
  let panel: NSSavePanel
  let stem: String
  private(set) var format: ExportFormat = .tiff16

  init(panel: NSSavePanel, stem: String) {
    self.panel = panel
    self.stem = stem
  }

  func apply(_ f: ExportFormat) {
    format = f
    panel.allowedContentTypes = [f.type]
    let current = panel.nameFieldStringValue
    let base = current.isEmpty ? stem : (current as NSString).deletingPathExtension
    panel.nameFieldStringValue = base + "." + f.fileExtension
  }

  @objc func changed(_ sender: NSPopUpButton) {
    apply(ExportFormat.allCases[safe: sender.indexOfSelectedItem] ?? .tiff16)
  }
}

extension Array {
  subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}

enum PixelImage {
  static func cgImage(halfP3 buffer: PixelBuffer) -> CGImage? {
    let data = Data(bytes: buffer.data, count: buffer.rowBytes * buffer.height)
    guard let provider = CGDataProvider(data: data as CFData) else { return nil }
    let info = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue
      | CGBitmapInfo.byteOrder16Little.rawValue
    return CGImage(
      width: buffer.width, height: buffer.height, bitsPerComponent: 16, bitsPerPixel: 64,
      bytesPerRow: buffer.rowBytes, space: CGColorSpace(name: CGColorSpace.displayP3)!,
      bitmapInfo: CGBitmapInfo(rawValue: info), provider: provider, decode: nil,
      shouldInterpolate: true, intent: .defaultIntent)
  }
}

final class CancelFlag: @unchecked Sendable {
  var cancelled = false
}

struct DetailJob: Equatable {
  let id: Int
  /// Tiles in render order, in source pixels.
  let cells: [CGRect]
  var done = 0
  /// Still loading the full-size source.
  var loading = true
  /// Only tiles off screen (the pan margin) are missing, so the view is already sharp and the
  /// pill stays hidden.
  var quiet = false
  var finished: Bool { done >= cells.count }

}

struct CompareTileKey: Equatable {
  /// Values the compare base renders with, nil for the original.
  let values: [String: ParamValue]?
  let image: ObjectIdentifier?
}

struct DetailTile {
  let buffer: PixelBuffer
  /// Part of the source, in full-size source pixels.
  let region: CGRect
  /// Scale of the source it was rendered from; the buffer holds region × scale pixels.
  let scale: Double
}

/// Creates its engine on first use, from whichever queue asks first.
final class LazyEngine: @unchecked Sendable {
  private let lock = NSLock()
  private var engine: SpektraEngine?
  private let role: Performance.Role

  init(role: Performance.Role = .preview) { self.role = role }

  var instance: SpektraEngine {
    lock.lock()
    defer { lock.unlock() }
    if let engine { return engine }
    let e = SpektraEngine()
    e.role = role
    engine = e
    return e
  }

  var created: SpektraEngine? {
    lock.lock()
    defer { lock.unlock() }
    return engine
  }
}

final class FullSourceCache: @unchecked Sendable {
  private let lock = NSLock()
  private var source: SourceImage?
  private var pixels: PixelBuffer?

  private var scaled: (scale: Double, pixels: PixelBuffer)?

  func setSource(_ s: SourceImage) {
    lock.lock(); defer { lock.unlock() }
    source = s
    pixels = nil
    scaled = nil
  }

  func get() -> PixelBuffer? {
    lock.lock(); defer { lock.unlock() }
    return full()
  }

  /// The source at `scale` (1, 1/2, 1/4…); the last scaled copy is kept.
  func get(scale: Double) -> PixelBuffer? {
    lock.lock(); defer { lock.unlock() }
    guard scale < 1 else { return full() }
    if let scaled, scaled.scale == scale { return scaled.pixels }
    guard let f = full() else { return nil }
    let w = max(1, Int((Double(f.width) * scale).rounded())), h = max(1, Int((Double(f.height) * scale).rounded()))
    guard let p = SourceImage.scaled(f, width: w, height: h) else { return nil }
    scaled = (scale, p)
    return p
  }

  /// Frees the decoded copies; the next get decodes again.
  func drop() {
    lock.lock(); defer { lock.unlock() }
    pixels = nil
    scaled = nil
  }

  private func full() -> PixelBuffer? {
    if let pixels { return pixels }
    pixels = source?.linearPixels()
    return pixels
  }
}
