// PhotoEmul - native editor for spektrafilm (GPL-3.0-or-later)
// UI language: Korean or English, following the system unless chosen in the Language menu.
// `-language en` on the command line overrides it for one run (NSArgumentDomain).

import Foundation

enum L10n {
  static let key = "language"

  enum Choice: String, CaseIterable, Identifiable {
    case system, ko, en
    var id: String { rawValue }
    var title: String {
      switch self {
      case .system: return tr("시스템 설정", "System")
      case .ko: return "한국어"
      case .en: return "English"
      }
    }
  }

  static var isKorean: Bool {
    switch UserDefaults.standard.string(forKey: key) ?? "system" {
    case "ko": return true
    case "en": return false
    default: return Locale.preferredLanguages.first?.hasPrefix("ko") ?? false
    }
  }
}

/// Picks the Korean or English text for the current UI language.
func tr(_ ko: String, _ en: String) -> String { L10n.isKorean ? ko : en }
