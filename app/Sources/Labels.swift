// PhotoEmul - native editor for spektrafilm (GPL-3.0-or-later)
// Parameter labels (engine English + Korean), module layout and film metadata.

import Foundation

/// A panel in the right-hand module stack, built from descriptor groups or an explicit name list.
struct ModuleSpec: Identifiable {
  enum Panel { case colorHead, testStrip, gradeCurve, lensBrowser, edgeProfile, vignetteProfile, illuminantSpd }

  let id: String
  let title: String
  var groups: [String] = []
  /// Explicit params in display order; overrides `groups` when not empty.
  var names: [String] = []
  /// Bool params toggled by the header switch (all on / all off).
  var enableParams: [String] = []
  /// Bool params owned by another module that must be on for this one to apply.
  var requires: [String] = []
  /// Params owned by other UI (film/paper browser, other modules) or fixed by the app.
  var hidden: Set<String> = []
  /// Advanced engine params shown in the basic section of this module.
  var promote: Set<String> = []
  var panel: Panel?
  var note: String?
  /// Lowest tool level that shows this card.
  var level: ToolLevel = .expert
  /// The rows a beginner sees open; the rest go under More. Empty: the usual tier-0 rows.
  var basic: [String] = []
}

/// How hard a tool may be and still show: beginner < standard < expert. Only what shows; hidden values still apply.
enum ToolLevel: String, CaseIterable, Comparable {
  case beginner, standard, expert
  static let key = "toolLevel"

  var title: String {
    switch self {
    case .beginner: return tr("초보", "Beginner")
    case .standard: return tr("일반", "Standard")
    case .expert: return tr("전문가", "Expert")
    }
  }

  static func < (a: ToolLevel, b: ToolLevel) -> Bool { allCases.firstIndex(of: a)! < allCases.firstIndex(of: b)! }

  /// Existing users keep every tool so the panel does not shrink on them; a first launch starts at standard.
  static func setDefault(_ store: UserDefaults = .standard) {
    guard store.object(forKey: key) == nil else { return }
    store.set((store.object(forKey: "launchSeconds") != nil ? expert : standard).rawValue, forKey: key)
  }
}

enum Modules {
  static let hiddenEverywhere: Set<String> = [
    "inputColorSpace", "outputColorSpace", "outputRole", "hdrPreset", "hdrTransfer",
    "hdrReferenceWhiteNits", "hdrPeakNits", "hdrExposureEv", "hdrToneMapping",
    "film", "paper", "adjacencyDeveloper",
    // Academy printer density timing needs the licensed SMPTE ST 2065-2 tables, which are not shipped
    // (the generated table is all zeros and renders a blank print), so the enlarger is always filtered.
    "printTiming", "printerLightsGang", "printerLightR", "printerLightG", "printerLightB", "printerLightCalibration",
  ]

  static let colorHead = [
    "filterC", "filterMShift", "filterYShift",
    "printerLightsGang", "printerLightR", "printerLightG", "printerLightB", "printerLightCalibration",
  ]
  static let preflash = ["preflashExposure", "preflashMFilterShift", "preflashYFilterShift"]
  static let glare = ["glarePercent", "glareRoughness", "glareBlur"]

  private static func diffusion(_ prefix: String) -> [String] {
    ["Family", "Strength", "HaloWarmth", "SpatialScale", "CoreIntensity", "CoreSize",
     "HaloIntensity", "HaloSize", "BloomIntensity", "BloomSize"].map { prefix + $0 }
  }

  // Light path order: lens -> camera filter -> negative -> enlarger -> print -> scan -> finishing.
  static var all: [ModuleSpec] { [
    ModuleSpec(id: "film", title: tr("촬영 · 포맷 · 노출", "Capture · Format · Exposure"), groups: ["film", "filtering"], level: .beginner, basic: ["filmExposureEv", "filmFormat"]),
    ModuleSpec(id: "develop", title: tr("현상 · 보관", "Development · Storage"), groups: ["devProcess", "develop", "aging"],
               hidden: ["devHighlightCompression", "devBromideDrag"],
               note: tr("표준 현상 대비 온도와 시간, 만료 후 경과 연수. 표준: C-41 37.8°C 3:15, ECN-2 41.1°C 3:00, E-6 38°C, 흑백 20°C, 인스턴트 약 25°C(Fujifilm 기준).",
                        "Temperature and time against the standard process, and years past expiry. Standard: C-41 37.8°C 3:15, ECN-2 41.1°C 3:00, E-6 38°C, B&W 20°C, instant about 25°C (Fujifilm)."), level: .standard),
    ModuleSpec(id: "lensProfile", title: tr("렌즈 프로파일", "Lens Profile"),
               names: ["lensAperture", "lensFocusDistance", "lensProfileStrength",
                       "lensApplyDistortion", "lensApplyTca", "lensApplyVignette"],
               enableParams: ["lensProfileEnabled"], panel: .lensBrowser,
               note: tr("실제 렌즈의 왜곡 · 색수차 · 주변부 감광을 재현합니다 (lensfun 데이터베이스, CC BY-SA 3.0). 렌즈는 필름 포맷 크기에 맞춰 실제처럼 적용되므로 작은 포맷에서는 효과가 약해집니다. 보정 프레임보다 큰 포맷(65mm · IMAX)은 보정 범위에 맞춰 적용합니다.",
                        "Reproduces a real lens's distortion, color fringing and vignetting (lensfun database, CC BY-SA 3.0). The lens covers the chosen film format as it would in reality, so small formats show less of it. Formats larger than the calibration frame (65 mm, IMAX) are fitted to it."), level: .standard),
    ModuleSpec(id: "lensBlur", title: tr("렌즈 블러", "Lens Blur"), groups: ["lensBlur"], enableParams: ["lensBlurEnabled"],
               note: tr("초점 영역 밖을 원형 보케로 흐립니다 (촬영 단계, 필름 이전).", "Blurs outside the focus area with round bokeh (at capture, before the film)."), level: .standard),
    ModuleSpec(id: "vignette", title: tr("비네팅", "Vignette"), groups: ["vignette"], enableParams: ["vignetteEnabled"], level: .beginner, basic: ["vignetteAmount"]),
    ModuleSpec(id: "aberration", title: tr("색수차", "Chromatic Aberration"), groups: ["aberration"], enableParams: ["aberrationEnabled"], level: .standard),
    ModuleSpec(id: "cameraDiffusion", title: tr("디퓨전 필터 (촬영)", "Diffusion Filter (Camera)"), names: diffusion("cameraDiffusion"),
               enableParams: ["cameraDiffusionEnabled"], note: tr("렌즈 앞 확산 필터: Pro-Mist, Glimmerglass 등.", "Diffusion filter in front of the lens: Pro-Mist, Glimmerglass, etc."), level: .standard),
    ModuleSpec(id: "dir", title: tr("DIR 커플러 (색 번짐)", "DIR Couplers"), groups: ["dir"], level: .expert),
    ModuleSpec(id: "halation", title: tr("할레이션", "Halation"), groups: ["halation"], enableParams: ["halationEnabled"], level: .beginner, basic: ["halationAmount"]),
    ModuleSpec(id: "grain", title: tr("그레인", "Grain"), groups: ["grain", "grainSynthesis"], enableParams: ["grainEnabled"], level: .beginner, basic: ["grainAmount", "grainParticleAreaUm2"]),
    ModuleSpec(id: "colorHead", title: tr("컬러 헤드 (CMY)", "Color Head (CMY)"), names: colorHead, panel: .colorHead,
               note: tr("확대기 다이크로익 필터. 패드를 드래그하면 M/Y가 함께 바뀝니다.", "Enlarger dichroic filters. Drag the pad to change M and Y together."), level: .standard),
    ModuleSpec(id: "preflash", title: tr("프리플래시", "Preflash"), names: preflash, promote: Set(preflash),
               note: tr("인화 전 균일 노광: 섀도 대비를 낮추고 색을 입힙니다.", "Uniform pre-exposure of the paper: lowers shadow contrast and adds a tint."), level: .expert),
    ModuleSpec(id: "print", title: tr("인화", "Print"), groups: ["print", "filmPlane"], hidden: Set(colorHead + preflash), level: .beginner, basic: ["printExposureEv", "printPushPullStops"]),
    ModuleSpec(id: "adjacency", title: tr("교반 · 인접 효과", "Agitation · Adjacency"), groups: ["adjacency", "develop"],
               enableParams: ["adjacencyEnabled"], hidden: ["devDeveloper", "devDilution"],
               note: tr("인접 효과: 짙은 부분 옆이 덜 현상되어 윤곽이 또렷해집니다(에버하르트 경계). 묽은 현상액과 적은 교반일수록 강합니다. 컬러 네거는 필름의 DIR 커플러가 같은 일을 하므로, DIR 양이 0일 때만 대신합니다. 한쪽으로 끌리는 꼬리는 '브로마이드 드래그' 모듈에서 켭니다.",
                        "Adjacency effects: development slows beside dense areas, so edges sharpen (Eberhard border). Dilute developer and little agitation make it stronger. On colour negative the film's DIR couplers do the same, so this stands in only when the DIR amount is 0. For a directional tail, turn on the Bromide Drag module."), level: .expert),
    ModuleSpec(id: "uneven", title: tr("현상 불균일", "Uneven Development"), groups: ["uneven"], enableParams: ["unevenEnabled"],
               note: tr("현상 과정의 결함을 효과로 씁니다. 얼룩: 지친 현상액·부족한 교반의 구름 무늬. 가장자리: 새 현상액이 먼저 닿는 필름 긴 변이 더 현상됨. 서지 마크: 퍼포레이션에서 안쪽으로 뻗는 짙은 줄. 에어벨: 기포가 막은 작은 원이 덜 현상됨(인화에서 검은 점). 현상액 부족: 한쪽 긴 변이 잠기지 않아 띠가 생김(%는 띠 폭). 무늬는 필름 위치(mm) 기준이라 확대 · 내보내기에서도 같습니다.",
                        "Process defects as looks. Mottling: cloudy patches from tired developer or too little agitation. Edge: the long strip edges, reached first by fresh developer, develop further. Surge marks: dense streaks running in from the perforations. Air bells: bubbles keep developer off small round spots (dark dots on the print). Low level: one long side stayed out of the developer, leaving a band (% sets its width). The pattern is laid out in film millimetres, so zoom and export match."), level: .expert),
    ModuleSpec(id: "bromideDrag", title: tr("브로마이드 드래그", "Bromide Drag"), groups: ["bromideDrag"], enableParams: ["bromideDragEnabled"],
               note: tr("교반이 적으면 짙은 부분에서 나온 브로마이드가 한쪽으로 흘러 그 뒤의 현상을 늦춥니다. 밝은 물체 뒤로 인화에서 어두운 꼬리가 생기고, 어두운 부분을 지나온 쪽은 밝은 물체의 시작이 조금 밝아집니다. 방향 0°는 아래쪽(세워 둔 탱크), 90°는 오른쪽입니다. 꼬리 길이는 필름 위 mm입니다. 흑백 · 컬러 네거티브에 적용되고 슬라이드 · 인스턴트에는 적용되지 않습니다.",
                        "With too little agitation, bromide from dense areas flows one way and slows development behind them. Bright objects get a dark tail on the print, and where the flow comes off a dark area the start of a bright one comes out a little lighter. Direction 0° is down (a tank left upright), 90° is right. Tail length is in millimetres on the film. Applies to B&W and colour negative, not to slide or instant film."), level: .expert),
    ModuleSpec(id: "darkroom", title: tr("암실 인화 (흑백)", "Darkroom (B&W)"), groups: ["darkroom"],
               note: tr("등급과 분할 등급은 흑백 다계조 인화지(Kodak 2302)에, 광원은 흑백 필름의 은 입자에 적용됩니다. 분할 등급을 켜면 등급 대신 연한 쪽(00)·진한 쪽(5) 두 번 노광합니다.",
                        "Grade and split grade apply to black-and-white paper (Kodak 2302); the light source applies to the silver of black-and-white film. Split grade replaces the grade with two exposures, soft (00) and hard (5)."), level: .expert),
    ModuleSpec(id: "testStrip", title: tr("테스트 스트립", "Test Strip"), groups: ["testStrip"], panel: .testStrip,
               note: tr("사진을 띠로 나눠 띠마다 인화 노출을 달리합니다. 띠를 누르면 그 노출이 인화 노출이 됩니다. 효과로 쓸 때는 ⌥+클릭. 효과로 쓰지 않으면 보기용이라 저장 · 내보내기에 들어가지 않습니다.",
                        "Splits the photo into bands, each printed at a different exposure. Click a band to make its exposure the print exposure; with Use as Effect on, Option-click. Without the effect the strip is only for viewing and is not saved or exported."), level: .standard),
    ModuleSpec(id: "printDiffusion", title: tr("디퓨전 필터 (인화)", "Diffusion Filter (Print)"), names: diffusion("printDiffusion"),
               enableParams: ["printDiffusionEnabled"], note: tr("확대기 렌즈 아래 확산 필터.", "Diffusion filter under the enlarger lens."), level: .expert),
    ModuleSpec(id: "scanner", title: tr("스캔 · 샤프닝", "Scan · Sharpening"), groups: ["scanner"], enableParams: ["scannerEnabled"],
               hidden: Set(glare), level: .beginner, basic: ["scannerWhiteLevel", "scannerBlackLevel"]),
    ModuleSpec(id: "glare", title: tr("글레어", "Glare"), names: glare, requires: ["scannerEnabled"], promote: Set(glare),
               note: tr("스캐너 광학의 베일링 플레어. 스캔 모듈이 켜져 있어야 적용됩니다.", "Veiling flare of the scanner optics. Applies only when the Scan module is on."), level: .standard),
    ModuleSpec(id: "toning", title: tr("흑백 토닝", "B&W Toning"), groups: ["toning"],
               note: tr("흑백 필름에만 적용됩니다. 셀레늄은 섀도, 세피아는 중간톤을 물들입니다.", "Applies to black-and-white film only. Selenium tints the shadows, sepia the midtones."), level: .standard),
    ModuleSpec(id: "dust", title: tr("먼지 · 스크래치", "Dust & Scratches"), groups: ["dust"], enableParams: ["dustEnabled"],
               note: tr("실제 스캔 통계 모델: 크기·개수·방향 분포는 Ivanova, Williamson, Henderson, “Simulating Analogue Film Damage” (Eurographics 2023)의 FilmDamageSimulator 주석 데이터(MIT)에서 측정했습니다.",
                        "Real-scan model: size, count and direction statistics measured from the FilmDamageSimulator annotations (MIT) of Ivanova, Williamson, Henderson, “Simulating Analogue Film Damage” (Eurographics 2023)."), level: .beginner, basic: ["dustAmount", "dustScratches"]),
    ModuleSpec(id: "frame", title: tr("필름 프레임 · 테두리", "Film Frame · Border"), groups: ["frame"], level: .beginner, basic: ["frameStyle", "frameSize"]),
    ModuleSpec(id: "color", title: tr("색 처리 · 모드", "Color · Mode"), groups: ["color"], level: .beginner, basic: ["process"]),
  ] }
}

/// Which stages the chosen mode runs. Scan negative skips the print; process negative takes the
/// input as an already developed negative and skips the film (capture, development, grain).
enum ProcessScope {
  static let styleKey = "inactiveControls"
  enum Style: Int, CaseIterable, Identifiable {
    case dim, hide
    var id: Int { rawValue }
    var title: String { self == .dim ? tr("흐리게", "Dimmed") : tr("숨기기", "Hidden") }
  }

  /// 0 print simulation, 1 scan negative, 2 process negative. Slides and instant film are scanned.
  static func mode(_ values: [String: ParamValue]) -> Int {
    let process = values["process"]?.intValue ?? 0
    if process == 0, let film = Catalog.films[safe: values["film"]?.intValue ?? -1], FilmInfo.isPositive(film) { return 1 }
    return process
  }

  /// The film stages run (capture, development, grain): not when the input is already a negative.
  static func usesFilm(_ values: [String: ParamValue]) -> Bool { mode(values) != 2 }
  /// The paper is printed on: not when scanning, which positive film always is.
  static func usesPaper(_ values: [String: ParamValue]) -> Bool { mode(values) != 1 }
  /// Positive film printed as a negative: the film choice is ignored, so the pick contradicts itself.
  static func conflict(_ values: [String: ParamValue]) -> String? {
    guard mode(values) == 2, let film = Catalog.films[safe: values["film"]?.intValue ?? -1], FilmInfo.isPositive(film) else { return nil }
    return tr("슬라이드 · 인스턴트 필름은 포지티브라 네거로 인화할 수 없습니다. 이 모드에서는 필름 선택이 쓰이지 않습니다.",
              "Slide and instant film are positives and cannot be printed as a negative. The film choice is not used in this mode.")
  }

  /// What the mode does that the picks don't show: positive film chosen with Print is scanned.
  static func modeNote(_ values: [String: ParamValue]) -> String? {
    guard (values["process"]?.intValue ?? 0) == 0, mode(values) == 1 else { return nil }
    return tr("포지티브 필름은 인화하지 않고 스캔으로 처리됩니다.", "Positive film is scanned, not printed.")
  }

  /// Why the film or paper picker has no effect in this mode; nil when the pick is used.
  static func stockReason(film: Bool, _ values: [String: ParamValue]) -> String? {
    if film {
      guard !usesFilm(values) else { return nil }
      return tr("네거 인화 모드: 입력 사진을 네거로 사용하므로 필름 특성은 쓰이지 않습니다. 흑백 필름을 고르면 결과가 흑백이 되는 것만 반영됩니다.",
                "Process negative: the input photo is used as the negative, so the film's character is not used. Picking a B&W film only makes the result black and white.")
    }
    guard !usesPaper(values) else { return nil }
    return (values["process"]?.intValue ?? 0) == 0
      ? tr("포지티브 필름은 인화하지 않고 스캔하므로 인화지는 쓰이지 않습니다.", "Positive film is scanned, not printed, so the paper is not used.")
      : tr("네거 스캔 모드: 인화를 건너뛰므로 인화지는 쓰이지 않습니다.", "Scan negative: the print is skipped, so the paper is not used.")
  }

  private static let filmGroups: Set<String> = [
    "filtering", "film", "filmPlane", "dir", "grain", "grainSynthesis", "halation", "devProcess", "develop", "aging", "adjacency", "uneven", "bromideDrag",
  ]
  private static let printGroups: Set<String> = ["print", "darkroom", "testStrip"]

  static func isActive(_ name: String, _ values: [String: ParamValue]) -> Bool {
    reason(name, values) == nil
  }

  /// Why a control does nothing in the current mode; nil when it applies.
  static func reason(_ name: String, _ values: [String: ParamValue]) -> String? {
    let mode = mode(values), group = Catalog.byName[name]?.group ?? ""
    if name == "scanNegativeInvert" {
      return mode == 1 ? nil : tr("네거 스캔 모드에서만 적용됩니다.", "Applies only in Scan negative mode.")
    }
    if mode == 2, filmGroups.contains(group) || name.hasPrefix("cameraDiffusion") {
      return tr("네거 인화 모드: 입력을 이미 현상된 네거로 보고 바로 인화하므로 이 단계는 적용되지 않습니다. 밝기 · 색은 인화 노출과 C/M/Y 필터로 맞추세요.",
                "Process negative: the input is taken as an already developed negative and printed directly, so this stage does not apply. Set brightness and colour with the print exposure and the C/M/Y filters.")
    }
    if mode == 1, printGroups.contains(group) || name.hasPrefix("printDiffusion") {
      let positive = (values["process"]?.intValue ?? 0) == 0
      return positive
        ? tr("슬라이드 · 인스턴트 필름은 인화하지 않고 스캔하므로 이 단계는 적용되지 않습니다.",
             "Slide and instant film are scanned, not printed, so this stage does not apply.")
        : tr("네거 스캔 모드: 인화를 건너뛰므로 이 단계는 적용되지 않습니다.",
             "Scan negative: the print is skipped, so this stage does not apply.")
    }
    if name == "testStripTarget", !TestStrip.splitAvailable(values) {
      return tr("흑백 인화지에서 분할 등급을 켰을 때만 씁니다.", "Used only with split grade on black-and-white paper.")
    }
    if group == "bromideDrag", let film = Catalog.films[safe: values["film"]?.intValue ?? -1], !BromideDrag.appliesTo(film) {
      return tr("흑백 · 컬러 네거티브에만 적용됩니다.", "Applies only to B&W and colour negative film.")
    }
    return nil
  }

  /// The first reason that every control of a card shares; nil when any of them applies.
  static func reason(_ spec: ModuleSpec, _ values: [String: ParamValue]) -> String? {
    let names = PanelLayouts.shown(spec)
    guard !names.isEmpty, names.allSatisfy({ !isActive($0, values) }) else { return nil }
    return reason(names[0], values)
  }

  /// A card the hide style leaves out.
  static func hides(_ spec: ModuleSpec, _ values: [String: ParamValue], style: Int) -> Bool {
    style == Style.hide.rawValue && reason(spec, values) != nil
  }
}

enum Labels {
  static let params: [String: String] = [
    "process": "처리 모드",
    "scanNegativeInvert": "네거티브 반전",
    "colorAdaptation": "색 적응",
    "colorAdaptationInputCompression": "입력 압축",
    "colorAdaptationCurveSmoothing": "커브 스무딩",
    "colorAdaptationOutputLightnessCompression": "출력 명도 압축",
    "colorAdaptationOutputChromaCompression": "출력 채도 압축",
    "cameraUvFilterEnabled": "UV 필터",
    "cameraUvCutNm": "UV 컷 (nm)",
    "cameraIrFilterEnabled": "IR 필터",
    "cameraIrCutNm": "IR 컷 (nm)",
    "cameraColorFilter": "컬러 필터 (흑백)",
    "bwToning": "토닝",
    "bwToningAmount": "토닝 양",
    "rgbToRawMethod": "RGB→분광 변환",
    "filmFormat": "필름 포맷",
    "filmExposureEv": "노출 (EV)",
    "autoExposure": "자동 노출",
    "autoExposureMethod": "측광 방식",
    "filmPushPullMode": "증감 모드",
    "filmPushPullStops": "증감 현상 (스톱)",
    "negativeBleachBypassAmount": "네거 블리치 바이패스",
    "negativeLeucoCyanCoupling": "류코 시안 커플링",
    "filmGamma": "필름 감마",
    "printTiming": "인화 타이밍",
    "printExposureEv": "인화 노출 (EV)",
    "printPushPullStops": "인화 증감 (스톱)",
    "printBleachBypassAmount": "인화 블리치 바이패스",
    "printGamma": "인화 감마",
    "printShadowShape": "섀도 형태",
    "printHighlightShape": "하이라이트 형태",
    "filterC": "C 필터",
    "filterMShift": "M 필터 (마젠타↔그린)",
    "filterYShift": "Y 필터 (옐로↔블루)",
    "preflashExposure": "프리플래시 노출",
    "preflashMFilterShift": "프리플래시 M",
    "preflashYFilterShift": "프리플래시 Y",
    "printerLightsGang": "프린터 포인트 연동",
    "printerLightR": "프린터 포인트 R",
    "printerLightG": "프린터 포인트 G",
    "printerLightB": "프린터 포인트 B",
    "printerLightCalibration": "프린터 포인트 보정",
    "enlargerScale": "확대 배율",
    "enlargerOffsetXPercent": "오프셋 X (%)",
    "enlargerOffsetYPercent": "오프셋 Y (%)",
    "dirCouplersAmount": "강도",
    "dirCouplersDiffusionUm": "확산 (µm)",
    "dirCouplersDiffusionTailUm": "꼬리 확산 (µm)",
    "dirCouplersDiffusionTailWeight": "꼬리 비중",
    "dirCouplersInhibitionSameLayer": "동일층 억제",
    "dirCouplersInhibitionInterlayer": "층간 억제",
    "dirGammaSameLayerRgb": "동일층 감마 RGB",
    "dirGammaRToGb": "R → G/B 감마",
    "dirGammaGToRb": "G → R/B 감마",
    "dirGammaBToRg": "B → R/G 감마",
    "grainModel": "그레인 모델",
    "grainAmount": "양",
    "grainSaturation": "채도",
    "grainParticleAreaUm2": "입자 면적 (µm²)",
    "grainSublayersEnabled": "서브 레이어",
    "grainSubLayerCount": "서브 레이어 수",
    "grainParticleScale": "입자 크기 RGB",
    "grainParticleScaleLayers": "레이어 크기",
    "grainDensityMin": "최소 농도",
    "grainUniformity": "균일도 RGB",
    "grainFinalBlurUm": "그레인 블러",
    "grainBlurDyeCloudsUm": "염료 구름 블러 (µm)",
    "grainMicroStructure": "미세 구조",
    "grainSeed": "시드",
    "grainAnimate": "애니메이트",
    "halationAmount": "양",
    "halationScale": "크기",
    "halationBoostEv": "하이라이트 부스트 (EV)",
    "halationBoostRange": "부스트 범위",
    "halationProtectEv": "보호 (EV)",
    "halationStrength": "강도 RGB",
    "scatterAmount": "산란 양",
    "scatterScale": "산란 크기",
    "cameraDiffusionEnabled": "촬영 필터 사용",
    "cameraDiffusionFamily": "촬영 필터 종류",
    "cameraDiffusionStrength": "촬영 필터 강도",
    "cameraDiffusionSpatialScale": "촬영 필터 크기",
    "cameraDiffusionHaloWarmth": "촬영 헤일로 색온도",
    "printDiffusionEnabled": "인화 필터 사용",
    "printDiffusionFamily": "인화 필터 종류",
    "printDiffusionStrength": "인화 필터 강도",
    "printDiffusionSpatialScale": "인화 필터 크기",
    "printDiffusionHaloWarmth": "인화 헤일로 색온도",
    "scannerWhiteCorrection": "화이트 보정",
    "scannerBlackCorrection": "블랙 보정",
    "scannerWhiteLevel": "화이트 레벨",
    "scannerBlackLevel": "블랙 레벨",
    "glarePercent": "글레어 (%)",
    "glareRoughness": "글레어 거칠기",
    "glareBlur": "글레어 블러",
    "scannerMtf50LpMm": "스캐너 MTF50 (lp/mm)",
    "scannerUnsharpRadiusUm": "언샤프 반경 (µm)",
    "scannerUnsharpAmount": "언샤프 양",
    "devTempDelta": "온도 편차 (°C)",
    "devTimePercent": "현상 시간 (%)",
    "agingYears": "만료 후 경과 (년)",
    "agingStorage": "보관 온도",
    "agingHumidity": "보관 습도 (%RH)",
    "lensProfileEnabled": "렌즈 프로파일",
    "lensProfileId": "렌즈",
    "lensFocalMm": "초점 거리 (mm)",
    "lensAperture": "조리개",
    "lensFocusDistance": "초점 거리 (피사체)",
    "lensProfileStrength": "강도",
    "lensApplyDistortion": "왜곡",
    "lensApplyTca": "색수차 (TCA)",
    "lensApplyVignette": "주변부 감광",
    "lensBlurEnabled": "렌즈 블러",
    "lensBlurShape": "초점 형태",
    "lensBlurAmount": "블러 크기",
    "lensBlurFocusSize": "초점 영역",
    "lensBlurTransition": "전환 폭",
    "lensBlurFocusX": "초점 위치 X",
    "lensBlurFocusY": "초점 위치 Y",
    "lensBlurBokehBoost": "보케 하이라이트",
    "vignetteEnabled": "비네팅",
    "vignetteAmount": "양 (EV)",
    "vignetteMidpoint": "시작 지점",
    "vignetteFeather": "부드러움",
    "vignetteRoundness": "원형도",
    "aberrationEnabled": "색수차",
    "aberrationRedCyan": "레드 ↔ 시안",
    "aberrationBlueYellow": "블루 ↔ 옐로",
    "dustEnabled": "먼지 · 스크래치",
    "dustAmount": "먼지 양",
    "dustSize": "먼지 크기",
    "dustScratches": "스크래치",
    "dustPolarity": "먼지 색",
    "dustSeed": "패턴",
    "dustModel": "먼지 모델",
    "dustTypeDust": "먼지",
    "dustTypeHair": "머리카락 · 섬유",
    "dustTypeScratch": "긁힘 (진행 방향)",
    "dustTypeStain": "얼룩 · 물자국",
    "dustTypeFingerprint": "지문",
    "dustFormat": "필름 포맷",
    "dustEdgeBias": "가장자리 집중",
    "adjacencyEnabled": "인접 효과",
    "unevenEnabled": "현상 불균일",
    "unevenMottle": "얼룩 (%)",
    "unevenEdge": "가장자리 과현상 (%)",
    "unevenSurge": "서지 마크 (%)",
    "unevenAirBells": "에어벨 · 기포 (%)",
    "unevenLowLevel": "현상액 부족 띠 (%)",
    "unevenSeed": "무늬",
    "testStripEffect": "효과로 쓰기 (저장 · 내보내기에 포함)",
    "testStripCount": "칸 수",
    "testStripStep": "노출 간격",
    "testStripDirection": "방향 (연한 → 진한)",
    "testStripTarget": "바꿀 노출",
    "testStripLabels": "띠 숫자 (노출 차 · 초 표시)",
    "bromideDragEnabled": "브로마이드 드래그",
    "bromideDragAmount": "강도 (%)",
    "bromideDragLength": "꼬리 길이 (mm)",
    "bromideDragAngle": "방향 (°)",
    "adjacencyDeveloper": "현상액 (이전)",
    "devDeveloper": "현상액",
    "devDilution": "희석",
    "devHighlightCompression": "하이라이트 압축",
    "devBromideDrag": "브로마이드 드래그",
    "adjacencyAgitation": "교반",
    "adjacencyStrength": "강도 배율",
    "enlargerLightSource": "확대기 광원",
    "paperGradeHalf": "인화지 등급 (다계조)",
    "printSplitGrade": "분할 등급 인화",
    "printSoftSeconds": "연한 쪽 (00) 초",
    "printHardSeconds": "진한 쪽 (5) 초",
    "frameStyle": "프레임",
    "frameSize": "테두리 두께",
    "frameRoughness": "가장자리 거칠기",
    "shutterSpeed": "셔터 속도",
    "reciprocityCompensate": "상반칙 불궤 보정",
    "sceneIlluminant": "조명 광원",
    "sceneIlluminantAmount": "광원 색 반영",
  ]

  static let options: [String: String] = [
    "Print simulation": "인화 시뮬레이션",
    "Film balance": "필름 기준광 (변화 없음)",
    "Daylight 5500K": "주광 5500K",
    "Shade 7500K": "그늘 · 흐림 7500K",
    "Blue hour 12000K": "블루 아워 12000K",
    "Tungsten 3200K": "텅스텐 3200K",
    "Household 2700K": "가정용 전구 2700K",
    "Candle 1900K": "촛불 1900K",
    "Cool white fluorescent": "형광등 (주백색)",
    "Tri-band fluorescent": "삼파장 형광등",
    "Sodium street light": "나트륨 가로등",
    "White LED": "백색 LED",
    "Xenon flash": "제논 (플래시 · 영사기)",
    "Mercury vapour lamp": "수은등",
    "1 s": "1초", "2 s": "2초", "4 s": "4초", "8 s": "8초", "15 s": "15초", "30 s": "30초",
    "1 min": "1분", "2 min": "2분", "4 min": "4분", "8 min": "8분", "15 min": "15분", "30 min": "30분", "1 h": "1시간",
    "Yellow (8)": "옐로 (8)",
    "Orange (21)": "오렌지 (21)",
    "Red (25)": "레드 (25)",
    "Green (11)": "그린 (11)",
    "Selenium": "셀레늄",
    "Sepia": "세피아",
    "Gold (blue)": "골드 (블루)",
    "Split (sepia / selenium)": "스플릿 (세피아 / 셀레늄)",
    "Scan negative": "네거티브 스캔",
    "Process negative": "네거 인화",
    "Center weighted": "중앙 중점",
    "Median": "중앙값",
    "Standard": "표준",
    "Experimental": "실험적",
    "Filtered enlarger": "필터 확대기",
    "APD printer density": "APD 프린터 농도",
    "Preview": "미리보기 (빠름)",
    "Production": "프로덕션",
    "Grain Synthesis": "그레인 합성",
    "Circle (center focus)": "원형 (중앙 초점)",
    "Horizontal band (tilt)": "수평 띠 (틸트)",
    "Whole frame (soft)": "전체 (소프트)",
    "Wide open": "개방",
    "Infinity": "무한대",
    "White (negative print)": "흰색 (네거 인화)",
    "Auto (by film)": "자동 (필름 따라)",
    "Real scan statistics": "실제 스캔 통계",
    "Stock (D-76)": "원액 (D-76)",
    "Diluted 1+1 (D-76 1+1)": "1+1 희석 (D-76 1+1)",
    "Acutance (Rodinal 1+50)": "고선예도 (로디날 1+50)",
    "Compensating (Rodinal 1+100)": "보상 현상 (로디날 1+100)",
    "Continuous (rotary)": "연속 (로터리)",
    "Every 30 s": "30초마다",
    "Every minute": "1분마다",
    "Every 3 minutes": "3분마다",
    "Stand (none)": "스탠드 (교반 없음)",
    "Diffuser": "확산광",
    "Condenser": "콘덴서",
    "Cold light (cathode)": "냉음극 (콜드 라이트)",
    "Point source": "점광원",
    "Classic": "기본 (이전)",
    "Black (slide / scan)": "검은색 (슬라이드 · 스캔)",
    "None": "없음",
    "White print border": "흰 인화 테두리",
    "Filed carrier (black)": "필드 캐리어 (검정)",
    "35mm film strip": "35mm 필름 스트립",
    "Instant film": "인스턴트 필름",
    "Freezer (-18 °C)": "냉동 (−18 °C)",
    "Refrigerator (4 °C)": "냉장 (4 °C)",
    "Room temperature (21 °C)": "실온 (21 °C)",
    "Hot (30 °C)": "고온 (30 °C)",
    "1/3 stop": "1/3 스톱",
    "1/2 stop": "1/2 스톱",
    "1 stop": "1 스톱",
    "Left → right": "왼쪽 → 오른쪽",
    "Right → left": "오른쪽 → 왼쪽",
    "Top → bottom": "위 → 아래",
    "Bottom → top": "아래 → 위",
    "Exposure": "노광",
    "Soft (00)": "연한 쪽 (00)",
    "Hard (5)": "진한 쪽 (5)",
  ]

  /// English wording where the engine label is terse or uses ASCII units.
  static let english: [String: String] = [
    "filterMShift": "M Filter (Magenta ↔ Green)",
    "filterYShift": "Y Filter (Yellow ↔ Blue)",
    "cameraUvCutNm": "UV Cut (nm)",
    "cameraIrCutNm": "IR Cut (nm)",
    "cameraColorFilter": "Color Filter (B&W)",
    "enlargerOffsetXPercent": "Offset X (%)",
    "enlargerOffsetYPercent": "Offset Y (%)",
    "grainParticleAreaUm2": "Particle Area (µm²)",
    "glarePercent": "Glare (%)",
  ]

  static func param(_ name: String) -> String {
    if L10n.isKorean, let k = params[name] { return k }
    if let e = english[name] { return e }
    let label = Catalog.byName[name]?.label ?? name
    return label.hasSuffix(" um") ? String(label.dropLast(3)) + " (µm)" : label
  }

  static func option(_ label: String) -> String { L10n.isKorean ? options[label] ?? label : label }
}

enum FilmInfo {
  enum Category: String, CaseIterable, Identifiable {
    case all, negative, cine, slide, instant, bw
    var id: String { rawValue }
    /// Positive stocks are viewed directly (scanned), not printed.
    var isPositive: Bool { self == .slide || self == .instant }
    var title: String {
      switch self {
      case .all: return tr("전체", "All")
      case .negative: return tr("컬러 네거", "Negative")
      case .cine: return tr("시네마", "Cine")
      case .slide: return tr("슬라이드", "Slide")
      case .instant: return tr("인스턴트", "Instant")
      case .bw: return tr("흑백", "B&W")
      }
    }
  }

  static let monoStocks = ["tri_x", "trix", "tmax", "hp5", "acros", "doublex", "ilford_delta", "fp4", "pan_f", "xp2"]
  static let monoPapers = ["kodak_2302"]
  /// Black-and-white reversal: filed under B&W but viewed directly like a slide.
  static let monoPositives = ["kodak_trix"]

  /// The current values select a black-and-white film, or a black-and-white print stock.
  static func isMono(_ values: [String: ParamValue]) -> Bool {
    guard let film = Catalog.films[safe: values["film"]?.intValue ?? -1] else { return false }
    if category(film) == .bw { return true }
    // Only a print touches the paper; positives are always viewed as scans.
    guard (values["process"]?.intValue ?? 0) == 0, !isPositive(film),
          let paper = Catalog.papers[safe: values["paper"]?.intValue ?? -1] else { return false }
    return monoPapers.contains(paper)
  }

  /// Positive stocks are viewed directly (scanned), not printed.
  static func isPositive(_ name: String) -> Bool {
    category(name).isPositive || monoPositives.contains(name)
  }

  static func category(_ name: String) -> Category {
    if monoStocks.contains(where: name.contains) { return .bw }
    if ["vision3", "verita", "cinestill", "eterna"].contains(where: name.contains) { return .cine }
    if ["ektachrome", "kodachrome", "velvia", "provia"].contains(where: name.contains) { return .slide }
    if ["instax", "polaroid", "fp100c"].contains(where: name.contains) { return .instant }
    return .negative
  }

  /// Speed the stock is sold at vs. the speed of the profile data it is built from.
  static let exposureIndex: [String: (base: Double, rated: Double)] = [
    "cinestill_800t": (base: 500, rated: 800),
  ]

  /// Stocks whose names the word rules cannot build.
  static let fullNames = [
    "kodak_trix": "Kodak Tri-X Reversal 7266",
    "kodak_doublex": "Kodak Double-X 5222",
    "kodak_2302": "Kodak 2302 B&W",
    "fujifilm_eterna_cp_3513di": "Fujifilm Eterna-CP 3513DI",
    "fujifilm_fp100c": "Fujifilm FP-100C",
    "fujifilm_instax": "Fujifilm instax mini · WIDE",
  ]

  static func displayName(_ name: String) -> String {
    if let full = fullNames[name] { return full }
    let words = name.replacingOccurrences(of: "tri_x", with: "trix").split(separator: "_").map { w -> String in
      switch w {
      case "fujifilm": return "Fujifilm"
      case "cinestill": return "CineStill"
      case "push1": return "+1"
      case "push2": return "+2"
      case "typeii": return "Type II"
      case "trix": return "Tri-X"
      case "tmax": return "T-Max"
      case "hp5": return "HP5"
      case "fp4": return "FP4"
      case "xp2": return "XP2"
      case "ii": return "II"
      case "noremjet": return tr("(렘젯 제거)", "(no rem-jet)")
      default:
        if w.first?.isNumber ?? false { return w.uppercased() }
        return w.prefix(1).uppercased() + w.dropFirst()
      }
    }
    return words.joined(separator: " ")
  }
}
