import SwiftUI
import UniformTypeIdentifiers

/// PhotoEmul > Settings… (⌘,).
struct SettingsView: View {
  @Bindable var model: EditModel

  var body: some View {
    TabView {
      GeneralSettings(model: model)
        .tabItem { Label(tr("일반", "General"), systemImage: "gearshape") }
      FilmPanelSettings()
        .tabItem { Label(tr("재료 패널", "Stock Panel"), systemImage: "film.stack") }
      PanelLayoutSettings()
        .tabItem { Label(tr("도구 패널", "Tool Panel"), systemImage: "rectangle.3.group") }
      OSDSettings()
        .tabItem { Label(tr("화면 정보", "Overlay"), systemImage: "info.square") }
      ColorSettings()
        .tabItem { Label(tr("색 관리", "Color"), systemImage: "paintpalette") }
      PerformanceSettings()
        .tabItem { Label(tr("성능", "Performance"), systemImage: "speedometer") }
      ExportSettings(model: model)
        .tabItem { Label(tr("내보내기", "Export"), systemImage: "square.and.arrow.up") }
      CacheSettings()
        .tabItem { Label(tr("캐시", "Cache"), systemImage: "internaldrive") }
      AISettings()
        .tabItem { Label("AI", systemImage: "sparkles") }
    }
    .frame(width: 720)  // nine tabs; narrower pushes the last ones into a ">>" menu where macOS greys them out
  }
}

private struct GeneralSettings: View {
  let model: EditModel
  @AppStorage(L10n.key) private var language = L10n.Choice.system.rawValue
  @AppStorage(Appearance.key) private var appearance = Appearance.system.rawValue
  @AppStorage(Appearance.backdropKey) private var backdrop = Backdrop.auto.rawValue
  @AppStorage(Splash.enabledKey) private var splash = true
  @AppStorage(Appearance.marginKey) private var margin = true
  @AppStorage(Appearance.marginSizeKey) private var marginSize = Appearance.defaultMarginSize
  @AppStorage(Layout.rememberKey) private var remember = true
  @AppStorage(CanvasMTKView.syncResizeKey) private var syncResize = true
  @AppStorage(StoredHistory.enabledKey) private var saveHistory = true
  @AppStorage(EditModel.scrubPauseKey) private var scrubPause = EditModel.defaultScrubPause
  @AppStorage(EditModel.sliderPauseKey) private var sliderPause = 0.0
  @State private var confirmResetAll = false
  @State private var layoutDone = false

  var body: some View {
    Form {
      Section {
        Picker(tr("언어", "Language"), selection: $language) {
          ForEach(L10n.Choice.allCases) { Text($0.title).tag($0.rawValue) }
        }
        Picker(tr("모양", "Appearance"), selection: $appearance) {
          ForEach(Appearance.allCases) { Text($0.title).tag($0.rawValue) }
        }
        .pickerStyle(.segmented)
        Picker(tr("사진 배경", "Photo Backdrop"), selection: $backdrop) {
          ForEach(Backdrop.allCases) { Text($0.title).tag($0.rawValue) }
        }
        Toggle(tr("여백", "Margin"), isOn: $margin)
        if margin {
          LabeledContent(tr("여백 크기", "Margin Size")) {
            HStack {
              Slider(value: $marginSize, in: Appearance.marginSizes, step: 2)
              Text("\(Int(marginSize)) pt").monospacedDigit().frame(width: 48, alignment: .trailing)
            }
          }
        }
        Text(tr("맞춤 · 채움에서는 사진 둘레를 비워 둡니다. 100% · 200% 같은 확대에서는 사진 가장자리까지 옮겼을 때 여백이 보입니다. 비교 화면에서는 칸마다 따로 적용합니다.",
                "Fit and Fill keep this space around the photo; zoom levels such as 100% and 200% show it once you pan to the photo's edge. Each pane of a compare view gets its own."))
          .font(.caption).foregroundStyle(.secondary)
        Toggle(tr("실행 화면(스플래시) 보이기", "Show Launch Screen"), isOn: $splash)
        Text(tr("준비가 1초 안에 끝나는 Mac에서는 켜져 있어도 나타나지 않습니다.",
                "Skipped on Macs that are ready in under a second."))
          .font(.caption).foregroundStyle(.secondary)
      }
      Section(tr("화면 배치", "Layout")) {
        Toggle(tr("화면 배치 기억하기", "Remember Layout"), isOn: $remember)
        Text(tr("재료 패널과 오른쪽 패널의 폭, 접어 둔 항목, 비교 방식, 창 크기와 위치를 다음 실행 때 그대로 엽니다.",
                "Panel widths, folded sections, compare mode and the window frame come back on the next launch."))
          .font(.caption).foregroundStyle(.secondary)
        Toggle(tr("창 크기 조절 동기화", "Synced Window Resize"), isOn: $syncResize)
        Text(tr("창 크기를 바꾸는 동안 사진을 창과 같은 프레임에 다시 그립니다. 사진이 반 박자 늦게 따라오지 않지만, 무거운 사진에서는 창 끌기가 뻑뻑할 수 있습니다.",
                "While resizing, the photo is redrawn in the same frame as the window: no lag behind the edge, but dragging can feel heavy on large photos."))
          .font(.caption).foregroundStyle(.secondary)
        HStack {
          Button(tr("화면 배치 초기화", "Reset Layout")) {
            Layout.reset(model: model)
            layoutDone = true
          }
          if layoutDone {
            Label(tr("처음 배치로 되돌렸습니다", "Back to the default layout"), systemImage: "checkmark.circle.fill")
              .font(.caption).foregroundStyle(.green)
          }
        }
      }
      Section(tr("히스토리", "History")) {
        Toggle(tr("히스토리 저장", "Save History"), isOn: $saveHistory)
        Text(tr("사진마다 마지막 \(StoredHistory.limit)단계까지 편집 세션에 저장해, 다시 열어도 타임라인으로 되돌아갈 수 있습니다.",
                "Keeps the last \(StoredHistory.limit) steps of each photo in its edit session, so the timeline survives reopening."))
          .font(.caption).foregroundStyle(.secondary)
        LabeledContent(tr("슬라이더 끌기 멈춤 시간", "Slider Drag Pause")) {
          HStack {
            Slider(value: $sliderPause, in: 0...1, step: 0.05)
            Text(sliderPause > 0 ? String(format: "%.2f s", sliderPause) : tr("바로", "Off")).monospacedDigit().frame(width: 48, alignment: .trailing)
          }
        }
        Text(tr("0이면 끄는 동안 계속 그립니다. 0보다 크면 이 시간만큼 멈춰야 사진을 그리고, 그리는 중에 다시 움직이면 그리기를 멈춥니다. 놓으면 바로 그립니다.",
                "At 0 the photo follows the drag. Above 0 it is drawn only once the pointer rests this long, moving on stops the drawing, and letting go draws at once."))
          .font(.caption).foregroundStyle(.secondary)
        LabeledContent(tr("타임라인 끌기 멈춤 시간", "Timeline Scrub Pause")) {
          HStack {
            Slider(value: $scrubPause, in: 0.1...1, step: 0.05)
            Text(String(format: "%.2f s", scrubPause)).monospacedDigit().frame(width: 48, alignment: .trailing)
          }
        }
        Text(tr("타임라인 마커를 끌 때 이 시간만큼 한 단계에 머물러야 사진을 다시 그립니다. 빠르게 지나가는 단계는 그리지 않습니다.",
                "While dragging the timeline marker, the photo redraws only after it rests on a step this long; steps passed quickly are skipped."))
          .font(.caption).foregroundStyle(.secondary)
      }
      Section {
        HStack {
          Button(tr("모든 설정 초기화…", "Reset All Settings…"), role: .destructive) { confirmResetAll = true }
          Spacer()
        }
        Text(tr("즐겨찾기, 프리셋, 사진별 편집과 스냅샷은 지우지 않습니다.",
                "Favorites, presets and each photo's edits and snapshots are kept."))
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .confirmationDialog(tr("모든 설정을 처음 상태로 되돌릴까요?", "Reset all settings to their defaults?"),
                        isPresented: $confirmResetAll) {
      Button(tr("모두 초기화", "Reset All"), role: .destructive) { Layout.resetAll(model: model) }
      Button(tr("취소", "Cancel"), role: .cancel) {}
    } message: {
      Text(tr("언어, 모양, 사진 배경, 성능, 내보내기 설정과 화면 배치가 초기화됩니다.",
              "Language, appearance, backdrop, performance, export settings and layout go back to their defaults."))
    }
  }
}

/// Settings › 필름 패널: cards, groups, a new photo's film and paper, hover preview, favourites.
struct FilmPanelSettings: View {
  @AppStorage(FilmPanel.cardStyleKey) private var cardStyle = FilmPanel.CardStyle.photo.rawValue
  @AppStorage(FilmPanel.cardSizeKey) private var cardSize = FilmPanel.defaultCardSize
  @AppStorage(FilmPanel.cardGapKey) private var cardGap = FilmPanel.defaultCardGap
  @AppStorage(FilmPanel.shortNameKey) private var shortName = true
  @AppStorage(FilmPanel.badgeKey) private var badge = true
  @AppStorage(FilmPanel.orderKey) private var orderRaw = FilmPanel.defaultOrder
  @AppStorage(FilmPanel.hiddenKey) private var hiddenRaw = ""
  @AppStorage(FilmPanel.defaultOpenKey) private var defaultOpenRaw = FilmPanel.defaultOpen
  @AppStorage(FilmPanel.onOpenKey) private var onOpen = FilmPanel.OnOpen.last.rawValue
  @AppStorage(FilmPanel.startFilmKey) private var startFilm = FilmPanel.defaultStartFilm
  @AppStorage(FilmPanel.startPaperKey) private var startPaper = FilmPanel.defaultStartPaper
  @AppStorage(FilmPanel.startLastKey) private var startLast = true
  @AppStorage(EditModel.hoverKey) private var hoverPreview = true
  @AppStorage(FilmPanel.hoverDelayKey) private var hoverDelay = 1
  @AppStorage(FilmPanel.hoverHoldKey) private var hoverHold = 1
  @AppStorage(FilmPanel.hoverPendingKey) private var hoverPendingLabel = true
  @AppStorage(FilmPanel.hoverFadeKey) private var hoverFade = true
  @AppStorage(FilmPanel.thumbsFollowKey) private var thumbsFollow = true
  @AppStorage("favoriteStocks") private var favoritesRaw = ""
  @State private var confirmClear = false
  @State private var confirmReset = false
  @State private var importNote: String?

  private var order: [String] { FilmPanel.order(orderRaw) }
  private var hidden: Set<String> { Set(FilmPanel.list(hiddenRaw)) }
  private var defaultOpen: Set<String> { Set(FilmPanel.list(defaultOpenRaw)) }
  private var favorites: Set<String> { Set(favoritesRaw.split(separator: "\n").map(String.init)) }

  private func title(_ key: String) -> String {
    key == "favorites" ? tr("즐겨찾기", "Favorites") : FilmInfo.Category(rawValue: key)?.title ?? key
  }

  private func count(_ key: String) -> Int {
    key == "favorites" ? Catalog.films.filter(favorites.contains).count
      : Catalog.films.filter { FilmInfo.category($0).rawValue == key }.count
  }

  private func flip(_ key: String, in raw: Binding<String>) {
    var set = Set(FilmPanel.list(raw.wrappedValue))
    if set.contains(key) { set.remove(key) } else { set.insert(key) }
    raw.wrappedValue = order.filter(set.contains).joined(separator: ",")
  }

  var body: some View {
    Form {
      Section(tr("카드", "Cards")) {
        Picker(tr("카드 모양", "Card Style"), selection: $cardStyle) {
          ForEach(FilmPanel.CardStyle.allCases) { Text($0.title).tag($0.rawValue) }
        }
        .pickerStyle(.segmented)
        LabeledContent(tr("기본 카드 크기", "Default Card Size")) {
          HStack {
            ResettableSlider(value: cardSize, range: FilmPanel.cardSizeRange, onChange: { cardSize = $0 }, onBegin: {}, onEnd: {},
                             onReset: { cardSize = FilmPanel.defaultCardSize })
            Text("\(Int(cardSize)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
          }
        }
        LabeledContent(tr("기본 카드 간격", "Default Card Spacing")) {
          HStack {
            ResettableSlider(value: cardGap, range: FilmPanel.cardGapRange, onChange: { cardGap = $0 }, onBegin: {}, onEnd: {},
                             onReset: { cardGap = FilmPanel.defaultCardGap })
            Text("\(Int(cardGap)) pt").monospacedDigit().foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
          }
        }
        Text(tr("패널 아래 슬라이더를 더블클릭하면 이 크기와 간격으로 돌아갑니다.",
                "Double-click the sliders under the panel to come back to this size and spacing."))
          .font(.caption).foregroundStyle(.secondary)
        Picker(tr("이름 표시", "Names"), selection: $shortName) {
          Text(tr("짧게 (Portra 400)", "Short (Portra 400)")).tag(true)
          Text(tr("제조사 포함 (Kodak Portra 400)", "With maker (Kodak Portra 400)")).tag(false)
        }
        Toggle(tr("ISO · 종류 배지 보이기", "Show ISO · Type Badge"), isOn: $badge)
      }
      Section {
        ForEach(order, id: \.self) { key in
          HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
            Toggle(isOn: Binding(get: { !hidden.contains(key) }, set: { _ in flip(key, in: $hiddenRaw) })) {
              HStack(spacing: 6) {
                Text(title(key))
                Text("\(count(key))").monospacedDigit().foregroundStyle(.secondary)
              }
            }
            .toggleStyle(.checkbox)
            Spacer()
            if hidden.contains(key) {
              Text(tr("숨김", "Hidden")).font(.caption).foregroundStyle(.secondary)
            } else {
              Picker("", selection: Binding(get: { defaultOpen.contains(key) },
                                            set: { _ in flip(key, in: $defaultOpenRaw) })) {
                Text(tr("펼침", "Open")).tag(true)
                Text(tr("접힘", "Closed")).tag(false)
              }
              .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
            }
          }
        }
        .onMove { from, to in
          var keys = order
          keys.move(fromOffsets: from, toOffset: to)
          orderRaw = keys.joined(separator: ",")
        }
        Picker(tr("처음 열 때", "On Launch"), selection: $onOpen) {
          ForEach(FilmPanel.OnOpen.allCases) { Text($0.title).tag($0.rawValue) }
        }
      } header: {
        Text(tr("묶음", "Groups"))
      } footer: {
        Text(tr("끌어서 순서를 바꾸고, 체크를 끄면 숨깁니다. 숨긴 묶음도 검색하면 나타납니다. 오른쪽은 「기본값」으로 열 때 펼칠지 여부입니다. 인화지 탭은 「전체」 한 묶음이라 카드 설정만 적용됩니다.",
                "Drag to reorder, uncheck to hide; hidden groups still show up when searching. The right-hand switch is the default for “Defaults”. Papers have a single All group, so only the card options apply."))
          .font(.caption).foregroundStyle(.secondary)
      }
      Section {
        Picker(tr("필름", "Film"), selection: $startFilm) {
          ForEach(Catalog.films, id: \.self) { Text(FilmPanel.name($0, short: false)).tag($0) }
        }
        .disabled(startLast)
        Picker(tr("인화지", "Paper"), selection: $startPaper) {
          ForEach(Catalog.papers, id: \.self) { Text(FilmPanel.name($0, short: false)).tag($0) }
        }
        .disabled(startLast)
        Toggle(tr("대신 마지막에 쓴 조합으로 시작", "Start With the Last Combination Instead"), isOn: $startLast)
      } header: {
        Text(tr("새 사진의 시작값", "New Photo Starts With"))
      } footer: {
        Text(tr("처음 여는 사진에만 적용됩니다. 이미 편집한 사진은 항상 저장된 값으로 열립니다.",
                "Only for photos opened for the first time; an edited photo always opens with its saved values."))
          .font(.caption).foregroundStyle(.secondary)
      }
      Section(tr("미리보기 · 즐겨찾기", "Preview · Favorites")) {
        Toggle(tr("카드 썸네일에 편집 반영", "Card Thumbnails Follow Edits"), isOn: $thumbsFollow)
          .onChange(of: thumbsFollow) { _, _ in EditModel.current?.refreshThumbnails() }
        Text(tr("끄면 카드는 기본값에 그 필름 · 인화지와 처리 모드만 넣은 그림을 보여 주고, 값을 바꿔도 다시 그리지 않습니다. 카드에 올렸을 때의 미리보기는 지금 편집을 그대로 반영합니다.",
                "Off: cards show each stock on default values with only the film, paper and process mode applied, and edits do not redraw them. The hover preview still shows your current edit."))
          .font(.caption).foregroundStyle(.secondary)
        Toggle(tr("마우스를 올리면 사진에 미리보기", "Preview on Photo When Hovering"), isOn: $hoverPreview)
        Text(tr("필름이나 인화지 카드 위에 잠시 머물면 큰 사진에 그 룩을 빠르게 보여 줍니다. 확대 시 선명한 렌더는 클릭해서 고른 뒤에 합니다.",
                "Resting on a film or paper card shows its look on the photo. Sharp zoomed-in rendering follows once you click to choose it."))
          .font(.caption).foregroundStyle(.secondary)
        Picker(tr("미리보기까지 머무는 시간", "Hover Delay"), selection: $hoverDelay) {
          Text(tr("바로", "None")).tag(0)
          Text(tr("짧게", "Short")).tag(1)
          Text(tr("길게", "Long")).tag(2)
        }
        .pickerStyle(.segmented)
        .disabled(!hoverPreview)
        Picker(tr("카드를 벗어난 뒤 미리보기 유지", "Keep Preview After Leaving a Card"), selection: $hoverHold) {
          Text(tr("끔", "Off")).tag(0)
          Text(tr("짧게", "Short")).tag(1)
          Text(tr("길게", "Long")).tag(2)
        }
        .pickerStyle(.segmented)
        .disabled(!hoverPreview)
        Toggle(tr("다음 카드를 불러오는 동안 이름 표시", "Show Which Card Is Loading"), isOn: $hoverPendingLabel)
          .disabled(!hoverPreview)
        Toggle(tr("미리보기 사이를 부드럽게 전환", "Cross-Fade Between Previews"), isOn: $hoverFade)
          .disabled(!hoverPreview)
        Text(tr("카드 사이 빈 곳을 지날 때 원래 사진으로 깜빡이지 않고 이전 미리보기에서 다음 미리보기로 바로 넘어갑니다. 카드 목록 밖으로 나가면 곧바로 원래 사진으로 돌아옵니다.",
                "Crossing the gap between cards goes straight from one preview to the next instead of flashing the current look. Leaving the card list returns to the current look at once."))
          .font(.caption).foregroundStyle(.secondary)
        LabeledContent(tr("즐겨찾기", "Favorites")) {
          Text(tr("필름 \(Catalog.films.filter(favorites.contains).count) · 인화지 \(Catalog.papers.filter(favorites.contains).count)",
                  "\(Catalog.films.filter(favorites.contains).count) films · \(Catalog.papers.filter(favorites.contains).count) papers"))
            .monospacedDigit()
        }
        HStack {
          Button(tr("내보내기…", "Export…")) { FilmPanel.exportFavorites() }
            .disabled(favorites.isEmpty)
          Button(tr("가져오기…", "Import…")) {
            if let added = FilmPanel.importFavorites() {
              importNote = tr("\(added)개를 더했습니다", "Added \(added)")
            } else {
              importNote = nil
            }
          }
          Button(tr("비우기…", "Clear…"), role: .destructive) { confirmClear = true }
            .disabled(favorites.isEmpty)
          if let importNote {
            Label(importNote, systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(.green)
          }
        }
      }
      Section {
        HStack {
          Button(tr("재료 패널 설정 초기화…", "Reset Stock Panel Settings…")) { confirmReset = true }
          Spacer()
        }
        Text(tr("이 탭의 설정과 패널의 카드 크기·간격을 되돌립니다. 즐겨찾기는 지우지 않습니다.",
                "Resets this tab and the panel's card size and spacing; favorites are kept."))
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .frame(height: 640)
    .confirmationDialog(tr("즐겨찾기를 모두 지울까요?", "Remove all favorites?"), isPresented: $confirmClear) {
      Button(tr("비우기", "Clear"), role: .destructive) { FilmPanel.setFavorites([]) }
      Button(tr("취소", "Cancel"), role: .cancel) {}
    } message: {
      Text(tr("먼저 내보내 두면 나중에 가져올 수 있습니다.", "Export them first to bring them back later."))
    }
    .confirmationDialog(tr("재료 패널 설정을 처음 상태로 되돌릴까요?", "Reset the stock panel settings?"),
                        isPresented: $confirmReset) {
      Button(tr("초기화", "Reset"), role: .destructive) { FilmPanel.reset() }
      Button(tr("취소", "Cancel"), role: .cancel) {}
    }
  }
}

private struct ColorSettings: View {
  @AppStorage(CanvasMTKView.deepColorKey) private var deepColor = true
  @AppStorage(SoftProof.onKey) private var proof = false
  @AppStorage(SoftProof.targetKey) private var target = "srgb"
  @AppStorage(SoftProof.iccKey) private var icc = ""
  @AppStorage(SoftProof.intentKey) private var intent = 0
  @AppStorage(SoftProof.gamutKey) private var gamut = false

  private func chooseICC() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = ["icc", "icm"].compactMap { UTType(filenameExtension: $0) }
    panel.directoryURL = icc.isEmpty ? URL(fileURLWithPath: "/Library/ColorSync/Profiles") : URL(fileURLWithPath: icc).deletingLastPathComponent()
    guard panel.runModal() == .OK, let url = panel.url, SoftProof.iccSpace(url.path) != nil else { return }
    icc = url.path
    target = "icc"
  }

  var body: some View {
    Form {
      Section {
        Toggle(tr("16비트 화면 출력", "16-Bit Display Output"), isOn: $deepColor)
        Text(tr("하늘처럼 완만한 계조의 띠를 줄입니다. 모니터 프로파일은 켜고 끄는 것과 상관없이 macOS가 적용합니다.",
                "Smooths gentle gradients such as skies. macOS applies the monitor profile either way."))
          .font(.caption).foregroundStyle(.secondary)
        ForEach(Array(NSScreen.screens.enumerated()), id: \.offset) { _, screen in
          LabeledContent(screen.localizedName, value: OSD.monitorProfile(screen) ?? "—")
        }
        Text(tr("모니터 프로파일은 시스템 설정 › 디스플레이에서 바꿉니다. 사진 위 정보 상자에도 넣을 수 있습니다(화면 정보 › 모니터 프로파일).",
                "Change the monitor profile in System Settings › Displays. It can also go in the photo info box (Overlay › Monitor Profile)."))
          .font(.caption).foregroundStyle(.secondary)
      } header: {
        Text(tr("모니터", "Monitor"))
      }
      Section {
        Toggle(tr("소프트 프루프", "Soft Proof"), isOn: $proof)
        Picker(tr("대상", "Profile"), selection: $target) {
          Text("sRGB").tag("srgb")
          Text("Adobe RGB (1998)").tag("adobe")
          if !icc.isEmpty { Text(URL(fileURLWithPath: icc).deletingPathExtension().lastPathComponent).tag("icc") }
        }
        HStack {
          Button(tr("ICC 파일 고르기…", "Choose ICC File…")) { chooseICC() }
          Spacer()
        }
        Picker(tr("렌더링 의도", "Rendering Intent"), selection: $intent) {
          Text(tr("지각", "Perceptual")).tag(0)
          Text(tr("상대 색도계", "Relative Colorimetric")).tag(1)
        }
        Toggle(tr("범위 밖 색 경고", "Gamut Warning"), isOn: $gamut)
        Text(tr("사진 보기에서 대상 색 공간이나 프린터(ICC 파일)로 냈을 때의 색을 미리 봅니다. 범위 밖 색은 분홍으로 표시합니다. 내보내는 파일은 바뀌지 않습니다.",
                "Previews the colours as they would come out in the target colour space or on a printer (ICC file). Out-of-gamut colours show in pink. Exported files are unchanged."))
          .font(.caption).foregroundStyle(.secondary)
      } header: {
        Text(tr("소프트 프루프", "Soft Proof"))
      }
    }
    .formStyle(.grouped)
  }
}

private struct PerformanceSettings: View {
  @AppStorage(Performance.key) private var performance = Performance.auto.rawValue

  var body: some View {
    Form {
      Picker(tr("성능", "Performance"), selection: $performance) {
        ForEach(Performance.allCases) { Text($0.title).tag($0.rawValue) }
      }
      .pickerStyle(.radioGroup)
      Text(tr("자동은 이 Mac에 맞는 설정을 고릅니다. 인텔 Mac과 코어가 적은 Mac은 '균형'입니다.",
              "Automatic picks what suits this Mac: Intel Macs and Macs with few cores get Balanced."))
        .font(.caption).foregroundStyle(.secondary)
    }
    .formStyle(.grouped)
  }
}

struct ExportSettings: View {
  @Bindable var model: EditModel
  @AppStorage(ExportOptions.qualityKey) private var quality = ExportOptions.defaultQuality
  @AppStorage(ExportOptions.folderKey) private var folder = ""
  @AppStorage(ExportOptions.nameKey) private var nameRule = ExportOptions.defaultName

  var body: some View {
    Form {
      Section {
        Picker(tr("형식", "Format"), selection: $model.exportFormat) {
          ForEach(ExportFormat.allCases, id: \.self) { Text($0.title).tag($0) }
        }
        LabeledContent(tr("JPEG 품질", "JPEG Quality")) {
          HStack {
            ResettableSlider(value: Double(quality), range: 10...100,
                             onChange: { quality = Int($0.rounded()) }, onBegin: {}, onEnd: {},
                             onReset: { quality = ExportOptions.defaultQuality })
            Text("\(quality)").monospacedDigit().frame(width: 32, alignment: .trailing)
          }
        }
        .disabled(model.exportFormat != .jpeg)
        Text(tr("내보내기와 여러 사진에 적용에 쓰입니다. Lightroom에서 열었을 때는 항상 ProPhoto 16비트 TIFF입니다.",
                "Used by Export and Apply to Photos. Edits opened from Lightroom are always saved as ProPhoto 16-bit TIFF."))
          .font(.caption).foregroundStyle(.secondary)
      }
      Section(tr("저장 위치", "Location")) {
        Picker(tr("기본 폴더", "Default Folder"), selection: Binding(
          get: { folder.isEmpty ? 0 : 1 },
          set: { if $0 == 0 { folder = "" } else if folder.isEmpty { choose() } })) {
          Text(tr("사진과 같은 폴더", "Same Folder as the Photo")).tag(0)
          Text(tr("지정한 폴더", "Chosen Folder")).tag(1)
        }
        .pickerStyle(.radioGroup)
        if !folder.isEmpty {
          HStack {
            Image(systemName: ExportOptions.folder == nil ? "exclamationmark.triangle" : "folder")
              .foregroundStyle(ExportOptions.folder == nil ? .orange : .secondary)
            Text((folder as NSString).abbreviatingWithTildeInPath)
              .lineLimit(1).truncationMode(.middle).textSelection(.enabled)
            Spacer()
            Button(tr("선택…", "Choose…")) { choose() }
          }
          if ExportOptions.folder == nil {
            Text(tr("폴더를 찾을 수 없어 사진과 같은 폴더를 씁니다.", "The folder is missing; the photo's folder is used."))
              .font(.caption).foregroundStyle(.orange)
          }
        }
        Text(tr("저장 창이 처음 여는 폴더입니다. 여러 사진에 적용도 이 폴더를 먼저 제안합니다.",
                "Where the save panel opens. Apply to Photos suggests it too."))
          .font(.caption).foregroundStyle(.secondary)
      }
      Section(tr("파일 이름", "File Name")) {
        TextField(tr("규칙", "Rule"), text: $nameRule, prompt: Text(ExportOptions.defaultName))
          .font(.body.monospaced())
        HStack(spacing: 6) {
          ForEach(ExportOptions.tokens, id: \.self) { token in
            Button(token) { nameRule += token }.controlSize(.small)
          }
          Spacer()
          Button(tr("기본값", "Default")) { nameRule = ExportOptions.defaultName }
            .controlSize(.small).disabled(nameRule == ExportOptions.defaultName)
        }
        LabeledContent(tr("예", "Example")) {
          Text(example).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
        }
        Text(tr("{name} 사진 이름 · {film} 필름 · {paper} 인화지 · {date} 날짜. 같은 이름이 있으면 -2, -3을 붙입니다.",
                "{name} photo · {film} film · {paper} paper · {date} date. Taken names get -2, -3."))
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
  }

  private var example: String {
    let source = model.source?.url ?? URL(fileURLWithPath: "/L1041909.jpg")
    return ExportOptions.stem(for: source, values: model.settledValues, rule: nameRule) + "." + model.exportFormat.fileExtension
  }

  private func choose() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = tr("선택", "Choose")
    if let current = ExportOptions.folder { panel.directoryURL = current }
    if panel.runModal() == .OK, let url = panel.url { folder = url.path }
  }
}

struct CacheSettings: View {
  @AppStorage(CachePolicy.daysKey) private var days = CachePolicy.defaultDays
  @AppStorage(CachePolicy.limitKey) private var limitMB = CachePolicy.defaultLimitMB
  @State private var usage: CachePolicy.Usage?
  @State private var confirmClear = false

  var body: some View {
    Form {
      Section {
        LabeledContent(tr("필름·인화지 썸네일", "Film & Paper Thumbnails")) {
          Text(usage.map { "\(bytes($0.thumbnails)) · \(tr("\($0.thumbnailFiles)개", "\($0.thumbnailFiles) files"))" } ?? "…")
            .monospacedDigit()
        }
        LabeledContent(tr("확대 타일 (이번 실행)", "Zoomed Tiles (This Run)")) {
          Text(usage.map { bytes($0.tiles) } ?? "…").monospacedDigit()
        }
        if let usage {
          ProgressView(value: min(1, Double(max(usage.thumbnails, usage.tiles)) / Double(limitMB * 1_048_576)))
          Text(tr("한도 \(CachePolicy.sizeTitle(limitMB)) 중 \(bytes(max(usage.thumbnails, usage.tiles))) 사용",
                  "\(bytes(max(usage.thumbnails, usage.tiles))) of \(CachePolicy.sizeTitle(limitMB)) used"))
            .font(.caption).foregroundStyle(.secondary)
        }
      } header: {
        Text(tr("사용 중", "In Use"))
      }
      Section(tr("보관", "Keep")) {
        Picker(tr("보관 기간", "Keep For"), selection: $days) {
          ForEach(CachePolicy.dayChoices, id: \.self) { Text(CachePolicy.dayTitle($0)).tag($0) }
        }
        Picker(tr("최대 크기", "Maximum Size"), selection: $limitMB) {
          ForEach(CachePolicy.limitChoices, id: \.self) { Text(CachePolicy.sizeTitle($0)).tag($0) }
        }
        Text(tr("보관 기간이 지난 썸네일은 실행할 때 지웁니다. 크기를 넘으면 가장 오래 쓰지 않은 것부터 지웁니다. 확대 타일은 편집하거나 사진을 바꾸거나 앱을 닫으면 지워집니다.",
                "Thumbnails past the period are removed at launch. Over the size, the ones unused longest go first. Zoomed tiles are removed on any edit, new photo or quit."))
          .font(.caption).foregroundStyle(.secondary)
      }
      Section {
        HStack {
          Button(tr("캐시 비우기…", "Clear Cache…")) { confirmClear = true }
          Button(tr("Finder에서 보기", "Show in Finder")) {
            if let dir = ThumbCache.folder { NSWorkspace.shared.activateFileViewerSelecting([dir]) }
          }
          Spacer()
        }
        Text(tr("사진별 편집, 스냅샷, 프리셋과 즐겨찾기는 지우지 않습니다. 썸네일은 다음에 필요할 때 다시 만듭니다.",
                "Photo edits, snapshots, presets and favorites are kept. Thumbnails are made again when needed."))
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .onAppear(perform: refresh)
    .onChange(of: days) { apply() }
    .onChange(of: limitMB) { apply() }
    .confirmationDialog(tr("캐시를 비울까요?", "Clear the cache?"), isPresented: $confirmClear) {
      Button(tr("비우기", "Clear"), role: .destructive) {
        CachePolicy.clearAll { usage = $0 }
      }
      Button(tr("취소", "Cancel"), role: .cancel) {}
    }
  }

  private func bytes(_ n: Int) -> String {
    let f = ByteCountFormatter()
    f.countStyle = .file
    f.allowsNonnumericFormatting = false
    return f.string(fromByteCount: Int64(n))
  }

  /// A smaller limit or shorter period takes effect right away.
  private func apply() {
    DispatchQueue.global(qos: .utility).async {
      ThumbCache.trim()
      DispatchQueue.main.async { refresh() }
    }
  }

  private func refresh() {
    DispatchQueue.global(qos: .utility).async {
      let u = CachePolicy.usage()
      DispatchQueue.main.async { usage = u }
    }
  }
}

/// Outside AI agents: the local socket, its token, where they may export, and pacing.
/// One add-in's API key in the keychain; the field never shows a saved key.
private struct KeyField: View {
  let account: String
  @State private var input = ""
  @State private var saved = false

  var body: some View {
    HStack {
      SecureField(saved ? tr("저장됨 · 바꾸려면 입력", "Saved · type to replace") : tr("API 키", "API key"), text: $input)
      Button(tr("저장", "Save")) { Keychain.set(account, input); saved = true; input = "" }
        .disabled(input.isEmpty)
      Button(tr("지우기", "Remove")) { Keychain.set(account, ""); saved = false }
        .disabled(!saved)
    }
    .onAppear { saved = Keychain.get(account) != nil }
  }
}

private struct AISettings: View {
  @AppStorage(AgentServer.enabledKey) private var enabled = false
  @AppStorage(AgentServer.tokenKey) private var token = ""
  @AppStorage(AgentServer.snapshotKey) private var snapshot = true
  @AppStorage(AgentQueue.delayKey) private var delay = 0.3
  @AppStorage(AgentCommands.exportFolderKey) private var folder = ""
  private let server = AgentServer.shared
  @AppStorage(OpenAICompatible.urlKey) private var openAIURL = OpenAICompatible.defaultURL
  @AppStorage(OpenAICompatible.modelKey) private var openAIModel = ""
  @AppStorage(OpenAICompatible.imagesKey) private var openAIImages = true
  @AppStorage(UserAddIn.onKey) private var userOn = ""
  @State private var userAddIns = UserAddIn.scan()

  var body: some View {
    Form {
      Section {
        Toggle(tr("외부 제어 허용", "Allow External Control"), isOn: $enabled)
          .onChange(of: enabled) { _, on in on ? server.start() : server.stop() }
        LabeledContent(tr("상태", "Status")) {
          Text(server.failure.map { tr("오류: ", "Error: ") + $0 }
               ?? (server.listening == nil ? tr("꺼짐", "Off") : tr("대기 중 · 연결 \(server.clients)개", "Listening · \(server.clients) connected")))
        }
        LabeledContent(tr("토큰", "Token")) {
          HStack {
            Text(token.isEmpty ? "—" : token).font(.caption.monospaced()).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
            Button(tr("새로 만들기", "New")) { token = AgentServer.newToken() }
          }
        }
        Text(tr("이 Mac의 다른 프로그램(Monogram 컨트롤러, photoemul-mcp 등)이 \(AgentServer.socketURL.path) 소켓으로 접속합니다. 처음에 토큰을 보내야 합니다. AI 모델과는 무관합니다.",
                "Programs on this Mac (the Monogram controller, photoemul-mcp and others) connect to \(AgentServer.socketURL.path) and must send the token first. No AI model is involved."))
          .font(.caption).foregroundStyle(.secondary)
        HStack {
          Button(tr("Claude Code 등록 명령 복사", "Copy Claude Code Command")) {
            copy("claude mcp add photoemul -- '\(Bundle.main.executablePath ?? "")' --mcp")
          }
          Button(tr("Claude Desktop 설정 복사", "Copy Claude Desktop Config")) {
            copy(MCP.encode(["mcpServers": ["photoemul": ["command": Bundle.main.executablePath ?? "", "args": ["--mcp"]]]]) ?? "")
          }
        }
        Text(tr("MCP를 쓰는 AI(Claude Code, Claude Desktop 등)에 붙여 넣으세요. 앱이 꺼져 있으면 AI가 처음 부를 때 엽니다.",
                "Paste into an MCP client (Claude Code, Claude Desktop…). PhotoEmul opens on the first call if it isn't running."))
          .font(.caption).foregroundStyle(.secondary)
      } header: { Text(tr("외부 제어", "External Control")) }
      Section(tr("AI 탭 애드인", "AI Tab Add-ins")) {
        LabeledContent("Claude API") { KeyField(account: "claude") }
        LabeledContent(tr("OpenAI 호환", "OpenAI-Compatible")) {
          VStack(alignment: .leading) {
            TextField(tr("주소", "Base URL"), text: $openAIURL)
            TextField(tr("모델 (예: llama3.2-vision)", "Model (e.g. llama3.2-vision)"), text: $openAIModel)
            KeyField(account: "openai")
            Toggle(tr("미리보기 보내기 (이미지를 보는 모델만)", "Send the preview (image models only)"), isOn: $openAIImages)
          }
        }
        LabeledContent("Claude Code") {
          Text(tr("이 Mac의 claude 명령 (위 MCP 연결을 이 세션 동안 사용)", "The claude command on this Mac (uses the MCP connection above for the session)"))
            .foregroundStyle(.secondary)
        }
        Text(tr("키는 키체인에 저장합니다. 요청마다 미리보기(1024px)와 현재 값이 함께 보내집니다.",
                "Keys are kept in the keychain. Each request sends a 1024 px preview and the current values."))
          .font(.caption).foregroundStyle(.secondary)
        Text(tr("OpenAI 호환: OpenAI·OpenRouter·LM Studio·Ollama(http://localhost:11434/v1, 키 없음) 등. 비용은 Claude API와 Claude Code만 표시합니다.",
                "OpenAI-compatible: OpenAI, OpenRouter, LM Studio, Ollama (http://localhost:11434/v1, no key)… Cost is shown for Claude API and Claude Code only."))
          .font(.caption).foregroundStyle(.secondary)
      }
      Section(tr("내 애드인", "My Add-ins")) {
        ForEach(userAddIns, id: \.id) { a in
          VStack(alignment: .leading) {
            Toggle(isOn: Binding(get: { UserAddIn.on.contains(a.id) }, set: { turn in
              if turn, !a.approve() { return }
              var on = UserAddIn.on
              if turn { on.insert(a.id) } else { on.remove(a.id) }
              UserAddIn.on = on
            })) {
              Text(a.title)
              Text(a.capabilities).font(.caption).foregroundStyle(.secondary)
            }
            if a.manifest.key == true { KeyField(account: a.id) }
          }
        }
        HStack {
          Button(tr("폴더 열기", "Open Folder")) {
            try? FileManager.default.createDirectory(at: UserAddIn.directory, withIntermediateDirectories: true)
            NSWorkspace.shared.open(UserAddIn.directory)
          }
          Button(tr("예제 설치", "Install Examples")) { UserAddIn.installExamples(); userAddIns = UserAddIn.scan() }
        }
        Text(tr("폴더에 *.pemai 폴더(manifest.json + 실행 파일)를 넣으면 여기에 나타납니다. 켠 애드인은 AI 탭 목록에 보입니다.",
                "Put *.pemai folders (manifest.json + program) in the folder; they show here. Turned-on ones appear in the AI tab."))
          .font(.caption).foregroundStyle(.secondary)
      }
      .id(userOn)
      .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in userAddIns = UserAddIn.scan() }
      Section(tr("AI가 할 수 있는 일", "What AI May Do")) {
        LabeledContent(tr("내보내기 폴더", "Export Folder")) {
          HStack {
            Text(AgentCommands.exportFolder.path).lineLimit(1).truncationMode(.middle)
            Button(tr("선택…", "Choose…")) { choose() }
          }
        }
        Picker(tr("단계 사이 간격", "Pause Between Steps"), selection: $delay) {
          ForEach([0, 0.15, 0.3, 0.6, 1.0], id: \.self) { Text(String(format: tr("%.2g초", "%.2g s"), $0)).tag($0) }
        }
        Toggle(tr("적용할 때마다 스냅샷 남기기", "Add a Snapshot on Each Apply"), isOn: $snapshot)
        Text(tr("AI는 이 폴더에만 내보내고 있는 파일은 덮어쓰지 않습니다. 사진은 사용자가 알려 준 경로만 엽니다.",
                "AI exports only into this folder and never overwrites. It opens only paths you give it."))
          .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .onAppear { if token.isEmpty { token = AgentServer.token } }
  }

  private func copy(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  private func choose() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.prompt = tr("선택", "Choose")
    panel.directoryURL = AgentCommands.exportFolder
    if panel.runModal() == .OK, let url = panel.url { folder = url.path }
  }
}
