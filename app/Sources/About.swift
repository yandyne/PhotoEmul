// PhotoEmul - native editor for spektrafilm (GPL-3.0-or-later)
// About window: icon, name, version and the credits (Credits.html in the bundle).

import SwiftUI
import WebKit

struct AboutCommand: View {
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Button(tr("PhotoEmul 정보", "About PhotoEmul")) { openWindow(id: "about") }
  }
}

struct AboutView: View {
  private var version: String {
    let info = Bundle.main.infoDictionary
    let short = info?["CFBundleShortVersionString"] as? String ?? "?"
    return short
  }

  var body: some View {
    VStack(spacing: 10) {
      Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 72, height: 72)
      Text("PhotoEmul").font(.title2.weight(.semibold))
      Text(tr("버전 \(version)", "Version \(version)")).font(.callout).foregroundStyle(.secondary)
      CreditsView().frame(minHeight: 300)
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.25)))
    }
    .padding(18)
    .frame(width: 520, height: 600)
  }
}

private struct CreditsView: NSViewRepresentable {
  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeNSView(context: Context) -> WKWebView {
    let web = WKWebView()
    web.setValue(false, forKey: "drawsBackground")
    web.navigationDelegate = context.coordinator
    if let url = Bundle.main.url(forResource: "Credits", withExtension: "html") {
      web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
    }
    return web
  }
  func updateNSView(_ web: WKWebView, context: Context) {}

  /// Links never navigate inside the credits view (there is no way back):
  /// web links open in the browser, bundled files (LICENSE.txt) in their default app.
  final class Coordinator: NSObject, WKNavigationDelegate {
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
      if action.navigationType == .linkActivated, let url = action.request.url {
        NSWorkspace.shared.open(url)
        decisionHandler(.cancel)
      } else {
        decisionHandler(.allow)
      }
    }
  }
}
