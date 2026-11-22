import Foundation
import Metal

/// How hard renders may push the GPU. Slower settings pause between chunks of GPU work so the
/// window server and other apps keep getting frames on older Macs; the result is the same.
enum Performance: String, CaseIterable, Identifiable {
  case auto, full, balanced, system
  static let key = "performance"
  var id: String { rawValue }

  var title: String {
    switch self {
    case .auto: return tr("자동", "Automatic") + " (" + Performance.detected.title + ")"
    case .full: return tr("최고 성능", "Maximum Speed")
    case .balanced: return tr("균형", "Balanced")
    case .system: return tr("시스템 우선", "Keep System Responsive")
    }
  }

  /// The setting in effect: `auto` resolves to what suits this Mac.
  static var current: Performance {
    let p = Performance(rawValue: UserDefaults.standard.string(forKey: key) ?? "") ?? .auto
    return p == .auto ? detected : p
  }

  /// Intel Macs and Macs with a discrete GPU or few cores get the balanced setting.
  static let detected: Performance = {
    #if arch(x86_64)
      return .balanced
    #else
      let device = MTLCreateSystemDefaultDevice()
      if device?.hasUnifiedMemory == false || ProcessInfo.processInfo.activeProcessorCount <= 4 { return .balanced }
      return .full
    #endif
  }()

  /// Not the full-speed setting: queues run at lower priority and previews are smaller.
  static var lowPower: Bool { current != .full }

  enum Role { case preview, thumbnail }

  /// Share of time the GPU may be busy (0.1-1). Thumbnails yield more than the preview.
  static func gpuDuty(for role: Role) -> Float {
    if let env = ProcessInfo.processInfo.environment["SPEKTRALAB_GPU_DUTY"], let v = Float(env) {
      return min(max(v, 0.1), 1)
    }
    let base: Float
    switch current {
    case .auto, .full: base = 1
    case .balanced: base = 0.6
    case .system: base = 0.35
    }
    return role == .thumbnail && base < 1 ? max(base * 0.5, 0.15) : base
  }
}
