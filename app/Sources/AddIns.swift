// PhotoEmul - native editor for spektrafilm (GPL-3.0-or-later)
// User add-ins (AI plan 5b): a `*.pemai` folder in Application Support/PhotoEmul/AI Add-ins with a
// manifest.json, speaking the OpenAI chat format over HTTP or over stdin/stdout of a program.
// Models without tool calls get the tools in the system prompt and answer with ```json blocks.
import AppKit
import Foundation
import Security

struct UserAddIn: AIAddIn {
  struct Manifest: Decodable {
    var name: String
    /// "http-openai" or "stdio".
    var kind: String
    var url: String?
    var executable: String?
    var models: [String]?
    var images: Bool?
    var tools: Bool?
    /// Asks for an API key (kept in the keychain under the add-in's id).
    var key: Bool?
    var author: String?
  }

  let folder: URL
  let manifest: Manifest

  static let onKey = "aiAddIns.on"
  static var directory: URL { AgentServer.socketURL.deletingLastPathComponent().appendingPathComponent("AI Add-ins") }

  var id: String { "user:" + folder.lastPathComponent }
  var title: String { manifest.name }
  var models: [String] { manifest.models.flatMap { $0.isEmpty ? nil : $0 } ?? ["default"] }
  var seesImages: Bool { manifest.images ?? false }
  var usesTools: Bool { manifest.tools ?? true }
  var local: Bool { manifest.kind == "stdio" || (manifest.url.flatMap(URL.init(string:))?.host).map { ["localhost", "127.0.0.1", "::1"].contains($0) } == true }
  var capabilities: String {
    [seesImages ? tr("사진 봄", "sees photos") : tr("사진 안 봄", "no photos"),
     usesTools ? tr("도구 호출", "tool calls") : tr("JSON 블록", "JSON blocks"),
     local ? tr("로컬·오프라인", "local, offline") : tr("인터넷", "online")].joined(separator: " · ")
  }

  /// Every add-in folder with a readable manifest, by name.
  static func scan() -> [UserAddIn] {
    let dirs = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
    return dirs.filter { $0.pathExtension == "pemai" }.compactMap { dir in
      guard let data = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
            let m = try? JSONDecoder().decode(Manifest.self, from: data) else { return nil }
      return UserAddIn(folder: dir, manifest: m)
    }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
  }

  static var on: Set<String> {
    get { Set((UserDefaults.standard.string(forKey: onKey) ?? "").split(separator: "\n").map(String.init)) }
    set { UserDefaults.standard.set(newValue.sorted().joined(separator: "\n"), forKey: onKey) }
  }

  static var enabled: [UserAddIn] { let on = on; return scan().filter { on.contains($0.id) } }

  /// Turning one on: say what runs and what it gets.
  // shortcut: approval is for the program as it is now; a changed executable runs without asking again. Hash it when add-ins are shared widely.
  @MainActor func approve() -> Bool {
    let a = NSAlert()
    a.messageText = tr("“\(title)” 애드인을 켤까요?", "Turn on the “\(title)” add-in?")
    var lines = [tr("만든 이: ", "Author: ") + (manifest.author ?? "?")]
    if manifest.kind == "stdio" {
      let exe = folder.appendingPathComponent(manifest.executable ?? "")
      lines.append(tr("실행 파일: ", "Program: ") + exe.path)
      lines.append(tr("서명: ", "Signature: ") + Self.signature(exe))
    } else {
      lines.append(tr("주소: ", "Address: ") + (manifest.url ?? "?"))
    }
    lines.append(tr("대화, 미리보기 캡처, 현재 설정 값(JSON)만 받습니다. 사진 파일이나 다른 파일에는 손대지 않지만, 실행 파일은 이 Mac에서 사용자 권한으로 실행됩니다.",
                    "It gets only the conversation, preview captures and current settings (JSON). PhotoEmul hands it no files, but a program runs on this Mac with your permissions."))
    a.informativeText = lines.joined(separator: "\n")
    a.addButton(withTitle: tr("켜기", "Turn On"))
    a.addButton(withTitle: tr("취소", "Cancel"))
    return a.runModal() == .alertFirstButtonReturn
  }

  static func signature(_ url: URL) -> String {
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code,
          SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess else { return tr("서명 없음", "unsigned") }
    var info: CFDictionary?
    SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
    let team = (info as? [String: Any])?[kSecCodeInfoTeamIdentifier as String] as? String
    return team.map { tr("유효 (팀 \($0))", "valid (team \($0))") } ?? tr("유효 (임시 서명)", "valid (ad hoc)")
  }

  func user(_ text: String, png: String?) -> JSON { OpenAICompatible.user(text, png: seesImages ? png : nil) }

  func results(_ r: [AIResult]) -> [JSON] {
    if usesTools { return OpenAICompatible.results(r, images: seesImages) }
    let text = r.map { "result \($0.id)" + ($0.isError ? " (error)" : "") + ": " + $0.text }.joined(separator: "\n")
    return [OpenAICompatible.user(text, png: seesImages ? r.compactMap(\.png).last : nil)]
  }

  func turn(system: String, messages: [JSON], tools: [JSON], model: String) async throws -> AITurn {
    let system = usesTools ? system : system + "\n\n" + Self.blockPrompt(tools)
    let body = OpenAICompatible.body(system: system, messages: messages, tools: usesTools ? tools : [], model: model)
    let key = manifest.key == true ? Keychain.get(id) : nil
    var t: AITurn
    if manifest.kind == "stdio" {
      t = try OpenAICompatible.parse(await run(body, key: key))
    } else {
      guard let base = manifest.url, let url = URL(string: base.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions"),
            url.scheme?.hasPrefix("http") == true else {
        throw AgentCommands.Failure(message: tr("애드인 주소가 잘못됐습니다: ", "Bad add-in address: ") + (manifest.url ?? ""))
      }
      t = try OpenAICompatible.parse(await AIChat.post(url, body, headers: key.map { ["authorization": "Bearer " + $0] } ?? [:]))
    }
    if !usesTools {
      t.calls = Self.blocks(t.text)
      t.message = ["role": "assistant", "content": t.text]
    }
    return t
  }

  /// Runs the program once: request JSON and a newline on stdin, reply JSON on stdout.
  private func run(_ body: JSON, key: String?) async throws -> JSON {
    let p = Process()
    p.executableURL = folder.appendingPathComponent(manifest.executable ?? "")
    p.currentDirectoryURL = folder
    var env = ProcessInfo.processInfo.environment
    if let key { env["PHOTOEMUL_API_KEY"] = key }
    p.environment = env
    let input = Pipe(), output = Pipe(), errors = Pipe()
    p.standardInput = input; p.standardOutput = output; p.standardError = errors
    let data = try JSONSerialization.data(withJSONObject: body) + Data("\n".utf8)
    return try await withTaskCancellationHandler {
      try await Task.detached {
        try p.run()
        try input.fileHandleForWriting.write(contentsOf: data)
        try input.fileHandleForWriting.close()
        let out = output.fileHandleForReading.readDataToEndOfFile()
        let err = errors.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        try Task.checkCancellation()
        guard p.terminationStatus == 0, let json = try? JSONSerialization.jsonObject(with: out) as? JSON else {
          let tail = String(decoding: (err.isEmpty ? out : err).suffix(300), as: UTF8.self)
          throw AgentCommands.Failure(message: tr("애드인 실행 실패 (\(p.terminationStatus)): ", "Add-in failed (\(p.terminationStatus)): ") + tail)
        }
        return json
      }.value
    } onCancel: {
      if p.isRunning { p.terminate() }
    }
  }

  static func blockPrompt(_ tools: [JSON]) -> String {
    let list = tools.map { t in
      "- \(t["name"] ?? ""): \(t["description"] ?? "") " + (MCP.encode((t["inputSchema"] as? JSON)?["properties"] ?? [:]) ?? "")
    }.joined(separator: "\n")
    return """
    You cannot call tools directly. To use one, write a block like
    ```json
    {"tool": "set", "arguments": {"values": {"filterC": 10}, "label": "Warmer"}}
    ```
    One block per call, several allowed per reply. Results come back in the next message. Reply without blocks when done.
    Tools:
    \(list)
    """
  }

  /// ```json {"tool": …, "arguments": {…}} ``` blocks in a reply, as calls.
  static func blocks(_ text: String) -> [AICall] {
    let parts = text.components(separatedBy: "```")
    return stride(from: 1, to: parts.count, by: 2).compactMap { i -> (String, JSON)? in
      var s = parts[i]
      if s.hasPrefix("json") { s.removeFirst(4) }
      guard let o = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? JSON, let name = o["tool"] as? String else { return nil }
      return (name, o["arguments"] as? JSON ?? [:])
    }.enumerated().map { AICall(id: "b\($0.offset + 1)", name: $0.element.0, input: $0.element.1) }
  }

  /// Copies the bundled examples into the add-ins folder (never over existing ones).
  static func installExamples() {
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    guard let src = Bundle.main.url(forResource: "AI Add-ins Examples", withExtension: nil),
          let items = try? FileManager.default.contentsOfDirectory(at: src, includingPropertiesForKeys: nil) else { return }
    for item in items where item.pathExtension == "pemai" {
      try? FileManager.default.copyItem(at: item, to: directory.appendingPathComponent(item.lastPathComponent))
    }
  }
}
