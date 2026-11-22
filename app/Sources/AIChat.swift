// PhotoEmul - native editor for spektrafilm (GPL-3.0-or-later)
// AI tab: a chat whose add-in talks to a model. The model only gets tool definitions and
// messages; its tool calls run through AgentCommands on the main queue, like the socket's.
import AppKit
import Foundation
import Observation
import Security
import SwiftUI

typealias JSON = AgentCommands.JSON

struct AICall { let id: String; let name: String; let input: JSON }
struct AIResult { let id: String; let text: String; let png: String?; let isError: Bool }
struct AITurn {
  var message: JSON
  var text = ""
  var calls: [AICall] = []
  var input = 0, output = 0
  /// Dollars, when the add-in knows its prices.
  var cost: Double?
}

/// One model service. It never touches EditModel: messages and tools in, text and tool calls out.
protocol AIAddIn {
  var id: String { get }
  var title: String { get }
  var models: [String] { get }
  var seesImages: Bool { get }
  /// The first message of a request, in this service's own format.
  func user(_ text: String, png: String?) -> JSON
  func turn(system: String, messages: [JSON], tools: [JSON], model: String) async throws -> AITurn
  /// Tool results as the message(s) to append.
  func results(_ r: [AIResult]) -> [JSON]
}

/// API keys, one keychain item per add-in.
enum Keychain {
  private static func query(_ account: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: "com.yandyne.PhotoEmul.ai",
     kSecAttrAccount as String: account]
  }
  static func get(_ account: String) -> String? {
    var q = query(account)
    q[kSecReturnData as String] = true
    var out: AnyObject?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return nil }
    return String(decoding: d, as: UTF8.self)
  }
  /// Empty removes.
  static func set(_ account: String, _ value: String) {
    SecItemDelete(query(account) as CFDictionary)
    guard !value.isEmpty else { return }
    var q = query(account)
    q[kSecValueData as String] = Data(value.utf8)
    SecItemAdd(q as CFDictionary, nil)
  }
}

struct ClaudeAPI: AIAddIn {
  let id = "claude", title = "Claude API", seesImages = true
  let models = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]

  func user(_ text: String, png: String?) -> JSON {
    var content: [JSON] = png.map { [Self.image($0)] } ?? []
    content.append(["type": "text", "text": text])
    return ["role": "user", "content": content]
  }

  func turn(system: String, messages: [JSON], tools: [JSON], model: String) async throws -> AITurn {
    guard let key = Keychain.get(id), !key.isEmpty else {
      throw AgentCommands.Failure(message: tr("설정 › AI에 Claude API 키를 넣으세요.", "Enter a Claude API key in Settings › AI."))
    }
    var body: JSON = ["model": model, "max_tokens": 16000, "system": system, "messages": messages,
                      "thinking": ["type": "adaptive"], "cache_control": ["type": "ephemeral"],
                      "tools": tools.map { ["name": $0["name"] ?? "", "description": $0["description"] ?? "", "input_schema": $0["inputSchema"] ?? [:]] }]
    var headers = ["x-api-key": key, "anthropic-version": "2026-10-21"]
    // A declined request is re-run on Anthropic's recommended model; Haiku has no server-side fallback.
    if !model.contains("haiku") {
      body["fallbacks"] = "default"
      headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
    }
    return try Self.parse(await AIChat.post(URL(string: "https://api.anthropic.com/v1/messages")!, body, headers: headers))
  }

  /// Dollars per million tokens.
  static let prices: [String: (input: Double, output: Double)] = [
    "claude-opus-5-5": (4, 20), "claude-sonnet-5-5": (2, 10), "claude-haiku-5-5": (0.1, 0.5)]

  static func parse(_ r: JSON) throws -> AITurn {
    if r["stop_reason"] as? String == "refusal" {
      throw AgentCommands.Failure(message: tr("AI가 이 요청을 거절했습니다.", "The AI declined this request."))
    }
    // Content goes back verbatim (thinking and fallback blocks included).
    let content = r["content"] as? [JSON] ?? []
    let usage = r["usage"] as? JSON ?? [:]
    let n = { (k: String) in Double(usage[k] as? Int ?? 0) }
    var t = AITurn(message: ["role": "assistant", "content": content],
                   input: Int(n("input_tokens") + n("cache_read_input_tokens") + n("cache_creation_input_tokens")),
                   output: Int(n("output_tokens")))
    if let p = prices.first(where: { (r["model"] as? String ?? "").hasPrefix($0.key) })?.value {
      // Cache reads bill at 0.1×, cache writes at 1.25× the input price.
      t.cost = ((n("input_tokens") + 0.1 * n("cache_read_input_tokens") + 1.25 * n("cache_creation_input_tokens")) * p.input
                + n("output_tokens") * p.output) / 1e6
    }
    for b in content {
      switch b["type"] as? String {
      case "text": t.text += b["text"] as? String ?? ""
      case "tool_use": t.calls.append(AICall(id: b["id"] as? String ?? "", name: b["name"] as? String ?? "", input: b["input"] as? JSON ?? [:]))
      default: break
      }
    }
    return t
  }

  /// All results in one user message.
  func results(_ r: [AIResult]) -> [JSON] {
    [["role": "user", "content": r.map { x -> JSON in
      var content: [JSON] = [["type": "text", "text": x.text]]
      if let png = x.png { content.append(Self.image(png)) }
      return ["type": "tool_result", "tool_use_id": x.id, "content": content, "is_error": x.isError]
    }]]
  }

  private static func image(_ png: String) -> JSON {
    ["type": "image", "source": ["type": "base64", "media_type": "image/png", "data": png] as JSON]
  }
}

/// Any `/chat/completions` service: OpenAI, OpenRouter, LM Studio, Ollama.
struct OpenAICompatible: AIAddIn {
  static let urlKey = "aiOpenAI.url", modelKey = "aiOpenAI.model", imagesKey = "aiOpenAI.images"
  static let defaultURL = "http://localhost:11434/v1"
  let id = "openai"
  var title: String { tr("OpenAI 호환", "OpenAI-Compatible") }
  var models: [String] { [UserDefaults.standard.string(forKey: Self.modelKey) ?? ""].filter { !$0.isEmpty } }
  var seesImages: Bool { UserDefaults.standard.object(forKey: Self.imagesKey) as? Bool ?? true }

  func user(_ text: String, png: String?) -> JSON { Self.user(text, png: png) }

  static func user(_ text: String, png: String?) -> JSON {
    ["role": "user", "content": [["type": "text", "text": text]] + (png.map { [image($0)] } ?? [])]
  }

  func turn(system: String, messages: [JSON], tools: [JSON], model: String) async throws -> AITurn {
    let base = (UserDefaults.standard.string(forKey: Self.urlKey) ?? Self.defaultURL).trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
    guard !model.isEmpty, let url = URL(string: base + "/chat/completions"), url.scheme?.hasPrefix("http") == true else {
      throw AgentCommands.Failure(message: tr("설정 › AI에 OpenAI 호환 주소와 모델을 넣으세요.", "Enter the OpenAI-compatible URL and model in Settings › AI."))
    }
    var headers: [String: String] = [:]
    if let key = Keychain.get(id), !key.isEmpty { headers["authorization"] = "Bearer " + key }
    return try Self.parse(await AIChat.post(url, Self.body(system: system, messages: messages, tools: tools, model: model), headers: headers))
  }

  static func body(system: String, messages: [JSON], tools: [JSON], model: String) -> JSON {
    var body: JSON = ["model": model, "messages": [["role": "system", "content": system]] + messages]
    if !tools.isEmpty {
      body["tools"] = tools.map { ["type": "function", "function": ["name": $0["name"] ?? "", "description": $0["description"] ?? "",
                                                                   "parameters": $0["inputSchema"] ?? [:]] as JSON] }
    }
    return body
  }

  static func parse(_ r: JSON) throws -> AITurn {
    guard let m = (r["choices"] as? [JSON])?.first?["message"] as? JSON else {
      throw AgentCommands.Failure(message: tr("AI 응답이 비었습니다.", "The AI sent an empty reply."))
    }
    let usage = r["usage"] as? JSON ?? [:]
    var t = AITurn(message: m, text: m["content"] as? String ?? "",
                   input: usage["prompt_tokens"] as? Int ?? 0, output: usage["completion_tokens"] as? Int ?? 0)
    for c in m["tool_calls"] as? [JSON] ?? [] {
      let f = c["function"] as? JSON ?? [:]
      // OpenAI sends arguments as a JSON string; some local servers send the object.
      let input = f["arguments"] as? JSON
        ?? (f["arguments"] as? String).flatMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? JSON } ?? [:]
      t.calls.append(AICall(id: c["id"] as? String ?? "", name: f["name"] as? String ?? "", input: input))
    }
    return t
  }

  /// One tool message per call; tool messages can't carry images, so captures follow as a user message.
  func results(_ r: [AIResult]) -> [JSON] { Self.results(r, images: seesImages) }

  static func results(_ r: [AIResult], images: Bool) -> [JSON] {
    var out: [JSON] = r.map { ["role": "tool", "tool_call_id": $0.id, "content": $0.text] }
    let pngs = r.compactMap(\.png)
    if !pngs.isEmpty, images {
      out.append(["role": "user", "content": [["type": "text", "text": "Capture from the tool call above."]] + pngs.map(Self.image)])
    }
    return out
  }

  static func image(_ png: String) -> JSON {
    ["type": "image_url", "image_url": ["url": "data:image/png;base64," + png] as JSON]
  }
}

/// The AI tab's conversation. API add-ins loop here; Claude Code runs its own loop over `--mcp`.
@MainActor @Observable final class AIChat {
  static let shared = AIChat()
  static let addInKey = "aiAddIn"
  static let claudeCode = "claude-code"
  /// Built-ins, then the user add-ins turned on in Settings › AI (read fresh, so new ones need no restart).
  static var addIns: [AIAddIn] { [ClaudeAPI(), OpenAICompatible()] + UserAddIn.enabled }
  static func title(_ id: String) -> String { id == claudeCode ? "Claude Code" : addIns.first { $0.id == id }?.title ?? id }
  static var ids: [String] { addIns.map(\.id) + [claudeCode] }
  static func models(_ id: String) -> [String] {
    id == claudeCode ? ["default", "opus", "sonnet", "haiku"] : addIns.first { $0.id == id }?.models ?? []
  }
  static func modelKey(_ id: String) -> String { "aiModel." + id }

  struct Line: Identifiable {
    enum Role { case user, ai, tool, error, result }
    let id = UUID()
    let role: Role
    var text: String
    /// Tool lines: the call, each changed value's text before it, and how it went.
    var call: AICall? = nil
    var before: [String: String] = [:]
    var failed: String? = nil
    var skipped = false
    /// Result lines: the picture's look before the request and after its draft.
    var looks: (before: Look, after: Look)? = nil
  }
  private(set) var lines: [Line] = []
  private(set) var busy = false
  /// Tokens and dollars for this conversation; cost covers only the turns whose price is known.
  private(set) var tokensIn = 0
  private(set) var tokensOut = 0
  private(set) var cost = 0.0
  /// A step waiting for 적용 / 건너뛰기 (beginner and standard levels).
  private(set) var suggestion: String?
  @ObservationIgnored private var answer: CheckedContinuation<Bool, Never>?
  @ObservationIgnored private var acceptAll = false
  @ObservationIgnored private var history: [JSON] = []
  @ObservationIgnored private var historyAddIn = ""
  @ObservationIgnored private var task: Task<Void, Never>?
  @ObservationIgnored private var process: Process?

  static let system = """
    You edit one photo in PhotoEmul, a film-emulation darkroom (film stock, development, paper, print).
    The user's request comes with the current state and, when you can see images, a preview.
    Use the tools: each `set` is one draft step the user reviews before anything reaches their history,
    so make a few focused steps, each with a short `label` and a `note` saying why (the user reads it beside the step), and look again with `capture` when it helps.
    When the state shows references above 0, the user wants the look of those photos: see them with
    `reference`, and after your steps call `measure` and work its distance down; tell the user the distance.
    Answer briefly in the user's language.
    """

  /// Tools the model may call; the tab itself begins and finishes the request.
  nonisolated static var tools: [JSON] {
    MCP.tools().filter { !["begin", "finish", "apply", "discard"].contains($0["name"] as? String ?? "") }
  }

  func clear() {
    guard !busy else { return }
    lines = []
    history = []
    tokensIn = 0
    tokensOut = 0
    cost = 0
  }

  func stop() {
    task?.cancel()
    process?.terminate()
    decide(false)
  }

  /// The card's answer; `all` accepts the rest of this request without asking.
  func decide(_ apply: Bool, all: Bool = false) {
    if all { acceptAll = true }
    suggestion = nil
    answer?.resume(returning: apply)
    answer = nil
  }

  private func ask(_ c: AICall) async -> Bool {
    if acceptAll { return true }
    return await withCheckedContinuation { answer = $0; suggestion = Self.card(c) }
  }

  func send(_ text: String, addIn id: String, model name: String) {
    guard !busy, let model = AgentCommands.model else { return }
    lines.append(Line(role: .user, text: text))
    busy = true
    acceptAll = (UserDefaults.standard.string(forKey: ToolLevel.key).flatMap(ToolLevel.init) ?? .standard) == .expert
    task = Task {
      await AgentQueue.settle(model)
      let before = AgentCommands.look(model)
      do {
        if id == Self.claudeCode {
          try await runClaudeCode(text, model: name)
        } else if let addIn = Self.addIns.first(where: { $0.id == id }) {
          try await runAPI(addIn, text, model: name, editor: model)
        }
      } catch is CancellationError {
        lines.append(Line(role: .error, text: tr("멈춤", "Stopped")))
      } catch {
        lines.append(Line(role: .error, text: (error as? AgentCommands.Failure)?.message ?? error.localizedDescription))
      }
      if let before, AgentSession.shared.active, !AgentSession.shared.steps.isEmpty {
        await AgentQueue.settle(model)
        if let after = AgentCommands.look(model) { lines.append(Line(role: .result, text: "", looks: (before, after))) }
      }
      finishDraft(model)
      busy = false
      process = nil
    }
  }

  private func runAPI(_ addIn: AIAddIn, _ text: String, model name: String, editor: EditModel) async throws {
    if historyAddIn != addIn.id { history = [] }
    historyAddIn = addIn.id
    if !AgentSession.shared.active {
      _ = AgentCommands.run(["cmd": "begin", "request": text, "agent": addIn.title], model: editor)
    }
    let state = (AgentCommands.run(["cmd": "state"], model: editor)["result"]).flatMap { MCP.encode($0) } ?? "{}"
    if addIn.seesImages { await AgentQueue.settle(editor) }
    let png = addIn.seesImages ? (AgentCommands.run(["cmd": "capture", "width": 1024], model: editor)["result"] as? JSON)?["png"] as? String : nil
    history.append(addIn.user(text + "\n\nCurrent state:\n" + state, png: png))
    let tools = Self.tools
    // shortcut: at most 24 round trips per request; raise if real requests need more.
    for _ in 0..<24 {
      try Task.checkCancellation()
      let t = try await addIn.turn(system: Self.system, messages: history, tools: tools, model: name)
      history.append(t.message)
      tokensIn += t.input
      tokensOut += t.output
      cost += t.cost ?? 0
      if !t.text.isEmpty { lines.append(Line(role: .ai, text: t.text)) }
      if t.calls.isEmpty { return }
      var results: [AIResult] = []
      for c in t.calls {
        if ["set", "preset"].contains(c.name), !(await ask(c)) {
          try Task.checkCancellation()
          lines.append(Self.toolLine(c, before: Self.before(c), skipped: true))
          results.append(AIResult(id: c.id, text: "The user skipped this step; it was not applied.", png: nil, isError: false))
          continue
        }
        let before = Self.before(c)
        let reply = await Self.submit(c.input.merging(["cmd": c.name]) { $1 })
        let ok = reply["ok"] as? Bool == true
        var result = reply["result"] ?? reply["error"] ?? NSNull()
        var png: String?
        if var r = result as? JSON, let p = r.removeValue(forKey: "png") as? String { png = p; result = r }
        lines.append(Self.toolLine(c, before: before, error: ok ? nil : reply["error"] as? String ?? "error"))
        results.append(AIResult(id: c.id, text: MCP.encode(result) ?? "\(result)", png: png, isError: !ok))
      }
      history += addIn.results(results)
    }
  }

  /// `claude -p` with this app's `--mcp` relay; its edits arrive through the socket.
  // shortcut: no suggestion cards here (its steps reach the socket, not this loop); the draft review still asks. Add if users want per-step cards for Claude Code.
  private func runClaudeCode(_ text: String, model name: String) async throws {
    let server = AgentServer.shared
    if server.listening == nil { server.start() }  // for this session only; the stored setting is untouched
    _ = AgentServer.token
    let config = MCP.encode(["mcpServers": ["photoemul": ["command": Bundle.main.executablePath ?? "", "args": ["--mcp"]]]]) ?? "{}"
    let prompt = Self.system + "\nStart with the photoemul `begin` tool (agent \"Claude Code\", request: a short title), then `state`.\n\nRequest: " + text
    var args = ["-p", prompt, "--output-format", "stream-json", "--verbose", "--strict-mcp-config", "--mcp-config", config,
                "--allowedTools", "mcp__photoemul"]
    if name != "default" { args += ["--model", name] }
    let p = Process()
    // A login shell finds `claude` on the user's PATH, which apps opened from Finder don't get;
    // ~/.local/bin (the native installer's place) is often set only in .zshrc, which -l skips.
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-lc", "PATH=\"$PATH:$HOME/.local/bin:$HOME/.claude/local:/opt/homebrew/bin:/usr/local/bin\" exec claude \"$@\"", "zsh"] + args
    let out = Pipe(), err = Pipe()
    p.standardOutput = out
    p.standardError = err
    p.standardInput = FileHandle.nullDevice
    try p.run()
    process = p
    for try await line in out.fileHandleForReading.bytes.lines {
      guard let event = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? JSON else { continue }
      switch event["type"] as? String {
      case "assistant":
        for b in (event["message"] as? JSON)?["content"] as? [JSON] ?? [] {
          if b["type"] as? String == "text", let s = b["text"] as? String, !s.isEmpty { lines.append(Line(role: .ai, text: s)) }
          if b["type"] as? String == "tool_use", let n = b["name"] as? String {
            let c = AICall(id: "", name: n.replacingOccurrences(of: "mcp__photoemul__", with: ""), input: b["input"] as? JSON ?? [:])
            lines.append(Self.toolLine(c, before: Self.before(c)))
          }
        }
      case "result":
        let usage = event["usage"] as? JSON ?? [:]
        tokensIn += ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"].reduce(0) { $0 + (usage[$1] as? Int ?? 0) }
        tokensOut += usage["output_tokens"] as? Int ?? 0
        cost += event["total_cost_usd"] as? Double ?? 0
        if event["is_error"] as? Bool == true { lines.append(Line(role: .error, text: event["result"] as? String ?? "error")) }
      default: break
      }
    }
    p.waitUntilExit()
    if p.terminationStatus != 0, p.terminationReason == .exit {
      let e = String(decoding: err.fileHandleForReading.readDataToEndOfFile().suffix(400), as: UTF8.self)
      throw AgentCommands.Failure(message: p.terminationStatus == 127
        ? tr("claude 명령을 찾지 못했습니다. Claude Code를 설치하세요.", "The claude command was not found; install Claude Code.")
        : "claude: " + e)
    }
  }

  /// Draft steps go to review (expert level applies them); an empty draft leaves nothing.
  private func finishDraft(_ model: EditModel) {
    let s = AgentSession.shared
    guard s.active, !s.finished else { return }
    if s.steps.isEmpty { s.end(model) } else { s.finish(model) }
  }

  static func submit(_ req: JSON) async -> JSON {
    await withCheckedContinuation { c in AgentQueue.submit(req) { c.resume(returning: $0) } }
  }

  /// The suggestion card: what the step changes and why.
  static func card(_ c: AICall) -> String {
    var s = c.name == "preset" ? tr("프리셋 ", "Preset ") + (c.input["name"] as? String ?? "") : ""
    if let v = c.input["values"] as? JSON {
      s += v.keys.sorted().map { Labels.param($0) + " → " + (MCP.encode(v[$0] ?? "") ?? "") }.joined(separator: "\n")
    }
    if let n = c.input["note"] as? String, !n.isEmpty { s += "\n" + n }
    return s
  }

  private static func toolLine(_ c: AICall, before: [String: String], error: String? = nil, skipped: Bool = false) -> Line {
    var s = c.name
    if let v = c.input["values"] as? JSON { s += " · " + v.keys.sorted().map(Labels.param).joined(separator: ", ") }
    if let n = c.input["note"] as? String, !n.isEmpty { s += " — " + n }
    if let error { s += " ✗ " + error }
    return Line(role: .tool, text: s, call: c, before: before, failed: error, skipped: skipped)
  }

  /// The draft's current text for each value a step is about to change (read before it runs).
  private static func before(_ c: AICall) -> [String: String] {
    let s = AgentSession.shared
    guard s.active, let v = c.input["values"] as? JSON else { return [:] }
    return v.keys.reduce(into: [:]) { out, k in if let old = s.draft[k] { out[k] = valueText(k, AgentCommands.json(old)) } }
  }

  /// A value as the user reads it: stock and option names, short numbers, 켬/끔.
  nonisolated static func valueText(_ k: String, _ v: Any) -> String {
    if let n = v as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() { return n.boolValue ? tr("켬", "on") : tr("끔", "off") }
    if let i = v as? Int {
      if k == "film" || k == "paper" { return FilmInfo.displayName((k == "film" ? Catalog.films : Catalog.papers)[safe: i] ?? "\(i)") }
      if let o = Catalog.params.first(where: { $0.name == k })?.options[safe: i] { return o }
    }
    if let x = (v as? NSNumber)?.doubleValue { return x.formatted(.number.precision(.fractionLength(0...2))) }
    if let t = v as? String { return t }
    return MCP.encode(v) ?? "\(v)"
  }

  static func post(_ url: URL, _ body: JSON, headers: [String: String]) async throws -> JSON {
    var r = URLRequest(url: url, timeoutInterval: 300)
    r.httpMethod = "POST"
    r.httpBody = try JSONSerialization.data(withJSONObject: body)
    r.setValue("application/json", forHTTPHeaderField: "content-type")
    for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
    let (data, response) = try await URLSession.shared.data(for: r)
    let json = (try? JSONSerialization.jsonObject(with: data) as? JSON) ?? [:]
    let code = (response as? HTTPURLResponse)?.statusCode ?? 0
    guard code == 200 else {
      let e = json["error"] as? JSON
      throw AgentCommands.Failure(message: "HTTP \(code): " + (e?["message"] as? String ?? String(decoding: data.prefix(300), as: UTF8.self)))
    }
    return json
  }
}

/// Sidebar AI tab.
struct AIPanel: View {
  @AppStorage(AIChat.addInKey) private var addIn = "claude"
  @AppStorage(ToolLevel.key) private var level = ToolLevel.standard
  @State private var text = ""
  @State private var modelChoice = ""
  private let chat = AIChat.shared

  var body: some View {
    VStack(spacing: 0) {
      HStack {
        Picker("", selection: $addIn) { ForEach(AIChat.ids, id: \.self) { Text(AIChat.title($0)).tag($0) } }
          .labelsHidden()
        Picker("", selection: $modelChoice) { ForEach(AIChat.models(addIn), id: \.self) { Text($0).tag($0) } }
          .labelsHidden()
        Button { chat.clear() } label: { Image(systemName: "square.and.pencil") }
          .buttonStyle(.borderless).disabled(chat.busy).help(tr("새 대화", "New Conversation"))
      }
      .controlSize(.small)
      .padding(8)
      if let u = AIChat.addIns.first(where: { $0.id == addIn }) as? UserAddIn {
        Text(u.capabilities + (u.usesTools ? "" : tr(" · 도구 호출 대신 JSON 블록이라 정확도가 낮을 수 있습니다", " · JSON blocks instead of tool calls, so less reliable")))
          .font(.caption2).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 8).padding(.bottom, 4)
      }
      Divider()
      references
      ScrollViewReader { scroll in
        ScrollView {
          LazyVStack(alignment: .leading, spacing: 8) {
            if chat.lines.isEmpty {
              Text(level == .expert
                   ? tr("원하는 느낌을 적으세요. 전문가 수준에서는 AI의 단계가 바로 적용됩니다.", "Describe the look you want. At Expert level the AI's steps apply directly.")
                   : tr("원하는 느낌을 적으세요. AI가 단계마다 제안하면 적용·건너뛰기를 고르고, 끝나면 사진 옆 초안에서 검토합니다.",
                        "Describe the look you want. Apply or skip each step the AI suggests, then review the draft beside your photo."))
                .font(.caption).foregroundStyle(.secondary)
              Text(tr("맞추고 싶은 사진이 있으면 여기로 끌어 놓으세요. AI가 그 느낌과의 차이를 재며 맞춥니다.",
                      "Drop photos here whose look you want; the AI measures the difference and works it down."))
                .font(.caption).foregroundStyle(.secondary)
            }
            ForEach(blocks, id: \.first!.id) { block in
              let line = block[0]
              Group {
                switch line.role {
                case .tool: AIWorkBox(lines: block, live: chat.busy && block.last?.id == chat.lines.last?.id)
                case .user:
                  Text(line.text).font(.callout).foregroundStyle(.white)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(Color.accentColor, in: UnevenRoundedRectangle(topLeadingRadius: 12, bottomLeadingRadius: 12, bottomTrailingRadius: 3, topTrailingRadius: 12))
                    .padding(.leading, 40)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                case .ai:
                  HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "sparkle").font(.caption).foregroundStyle(.secondary)
                    Text(line.text).font(.callout).frame(maxWidth: .infinity, alignment: .leading)
                  }
                case .result: if let l = line.looks { AIResultNumbers(before: l.before, after: l.after) }
                case .error:
                  Label(line.text, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red)
                    .padding(6).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
                }
              }
              .textSelection(.enabled)
              .id(line.id)
            }
          }
          .padding(10)
        }
        .onChange(of: chat.lines.count) { if let last = blocks.last?.first { scroll.scrollTo(last.id, anchor: .bottom) } }
      }
      reviewStrip
      if let s = chat.suggestion {
        VStack(alignment: .leading, spacing: 6) {
          Text(s).font(.callout).textSelection(.enabled)
          HStack {
            Button(tr("적용", "Apply")) { chat.decide(true) }
            Button(tr("건너뛰기", "Skip")) { chat.decide(false) }
            Spacer()
            Button(tr("전부 적용", "Apply All")) { chat.decide(true, all: true) }
          }
          .controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        .padding(8)
      }
      if chat.tokensIn + chat.tokensOut > 0 {
        Text(tr("토큰 ", "Tokens ") + "\(chat.tokensIn.formatted()) / \(chat.tokensOut.formatted())"
             + (chat.cost > 0 ? tr(" · 약 ", " · about ") + chat.cost.formatted(.currency(code: "USD").precision(.fractionLength(2...3))) : ""))
          .font(.caption2).foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, alignment: .trailing)
          .padding(.horizontal, 8)
      }
      Divider()
      HStack(alignment: .bottom) {
        TextField(tr("요청", "Request"), text: $text, axis: .vertical)
          .lineLimit(1...5).textFieldStyle(.roundedBorder)
          .onSubmit(send)
        if chat.busy {
          Button { chat.stop() } label: { Image(systemName: "stop.circle") }.buttonStyle(.borderless)
            .help(tr("멈추기", "Stop"))
        } else {
          Button(action: send) { Image(systemName: "arrow.up.circle.fill") }.buttonStyle(.borderless)
            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
      }
      .padding(8)
    }
    .dropDestination(for: URL.self) { urls, _ in
      let paths = AgentSession.shared.references.map(\.url.path) + urls.filter(\.isFileURL).map(\.path)
      let r = AgentCommands.run(["cmd": "reference", "paths": paths], model: AgentCommands.model)
      if let e = r["error"] as? String { NSSound.beep(); print(e) }
      return r["ok"] as? Bool == true
    }
    .onAppear(perform: loadModel)
    .onChange(of: addIn) { loadModel() }
    .onChange(of: modelChoice) { if !modelChoice.isEmpty { UserDefaults.standard.set(modelChoice, forKey: AIChat.modelKey(addIn)) } }
  }

  /// Reference photos to match, and how close the draft got (first → latest measure).
  @ViewBuilder private var references: some View {
    let s = AgentSession.shared
    if !s.references.isEmpty {
      HStack(spacing: 4) {
        ForEach(Array(s.references.enumerated()), id: \.offset) { _, r in
          Image(decorative: r.image, scale: 1).resizable().scaledToFill()
            .frame(width: 32, height: 32).clipShape(RoundedRectangle(cornerRadius: 3))
            .help(r.url.lastPathComponent)
        }
        VStack(alignment: .leading, spacing: 1) {
          Text(tr("참고 사진 \(s.references.count)장", "\(s.references.count) reference photo(s)")).font(.caption)
          if let first = s.distances.first, let last = s.distances.last {
            Text(tr("\(s.steps.count)단계 · 차이 ", "\(s.steps.count) steps · difference ") + String(format: "%.2f → %.2f", first, last))
              .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
          }
        }
        Spacer()
        Button { s.setReferences([]) } label: { Image(systemName: "xmark.circle") }
          .buttonStyle(.borderless).help(tr("참고 사진 빼기", "Remove Reference Photos"))
      }
      .padding(.horizontal, 8).padding(.vertical, 4)
      Divider()
    }
  }

  /// The finished draft waits for the user: same apply / discard as the canvas bar, which also lets them pick steps.
  @ViewBuilder private var reviewStrip: some View {
    let s = AgentSession.shared
    if s.active, s.finished, !s.steps.isEmpty, let model = AgentCommands.model {
      let picked = s.steps.count - s.skipped.count
      HStack(spacing: 8) {
        Image(systemName: "checklist").foregroundStyle(Color.accentColor)
        VStack(alignment: .leading, spacing: 1) {
          Text(tr("검토 대기 · \(s.steps.count)단계 중 \(picked)개 고름", "Waiting for review · \(picked) of \(s.steps.count) steps ticked"))
            .font(.caption.weight(.semibold))
          Text(tr("사진 위에서 단계를 넘겨 보고 고를 수 있습니다", "Step through and tick steps on the photo"))
            .font(.caption2).foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        Button(tr("버리기", "Discard")) { s.end(model) }
        Button(tr("적용", "Apply")) { s.apply(model, ask: true, pick: .picked) }
          .buttonStyle(.borderedProminent).disabled(picked == 0)
      }
      .controlSize(.small)
      .padding(8)
      .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
      .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.accentColor.opacity(0.4)))
      .padding(8)
    }
  }

  /// Lines with each run of tool calls gathered into one work box.
  private var blocks: [[AIChat.Line]] {
    chat.lines.reduce(into: []) { b, l in
      if l.role == .tool, b.last?.first?.role == .tool { b[b.count - 1].append(l) } else { b.append([l]) }
    }
  }

  private func loadModel() {
    let models = AIChat.models(addIn)
    modelChoice = UserDefaults.standard.string(forKey: AIChat.modelKey(addIn)).flatMap { models.contains($0) ? $0 : nil } ?? models.first ?? ""
  }

  private func send() {
    let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !t.isEmpty, !chat.busy else { return }
    text = ""
    chat.send(t, addIn: addIn, model: modelChoice)
  }
}

/// One run of AI tool calls: draft steps always show what changed and why; reads and checks fold away.
struct AIWorkBox: View {
  let lines: [AIChat.Line]
  let live: Bool
  @State private var open = false

  private static let names = ["state": ("상태 읽기", "Read state"), "measure": ("측정", "Measure"), "capture": ("캡처로 확인", "Capture"),
                              "reference": ("참고 사진", "References"), "params": ("설정 목록", "Settings list"), "presets": ("프리셋 목록", "Presets"),
                              "begin": ("요청 시작", "Begin"), "finish": ("끝내기", "Finish"), "view": ("보기 바꾸기", "View"),
                              "history": ("기록", "History"), "open": ("사진 열기", "Open"), "export": ("내보내기", "Export")]

  private func isStep(_ l: AIChat.Line) -> Bool { ["set", "preset"].contains(l.call?.name ?? "") }

  var body: some View {
    let steps = lines.filter(isStep), others = lines.count - steps.count
    let failed = lines.filter { $0.failed != nil }.count
    VStack(alignment: .leading, spacing: 6) {
      Button { open.toggle() } label: {
        HStack(spacing: 5) {
          Image(systemName: open ? "chevron.down" : "chevron.right").font(.caption2.weight(.bold))
          Text(tr("작업 \(lines.count)개", "\(lines.count) actions")).fontWeight(.semibold)
          Text(tr("· 단계 \(steps.count) · 확인 \(others)", "· \(steps.count) steps · \(others) checks"))
          Spacer()
          if live { ProgressView().controlSize(.mini) }
          else if failed > 0 { Text(tr("오류 \(failed)", "\(failed) failed")).foregroundStyle(.red) }
          else { Text(tr("완료", "Done")).foregroundStyle(.green) }
        }
        .font(.caption).foregroundStyle(.secondary).contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      ForEach(lines) { l in
        if isStep(l) { step(l, number: (steps.firstIndex { $0.id == l.id } ?? 0) + 1) }
        else if open || l.failed != nil { other(l) }
      }
    }
    .padding(8)
    .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
  }

  private func step(_ l: AIChat.Line, number: Int) -> some View {
    let c = l.call!
    let values = c.input["values"] as? JSON ?? [:]
    let label = (c.input["label"] as? String).flatMap { $0.isEmpty ? nil : $0 }
      ?? (c.name == "preset" ? tr("프리셋 ", "Preset ") + (c.input["name"] as? String ?? "") : values.keys.sorted().first.map(Labels.param) ?? c.name)
    return VStack(alignment: .leading, spacing: 3) {
      HStack(spacing: 6) {
        Text("\(number)").font(.caption2.weight(.bold)).padding(.horizontal, 4)
          .background(Color.secondary.opacity(0.25), in: RoundedRectangle(cornerRadius: 3))
        Text(label).font(.callout.weight(.semibold)).strikethrough(l.skipped)
        if l.skipped { Text(tr("건너뜀", "skipped")).font(.caption2).foregroundStyle(.secondary) }
      }
      ForEach(values.keys.sorted(), id: \.self) { k in
        Text(Labels.param(k) + "  " + (l.before[k].map { $0 + " → " } ?? "→ ") + AIChat.valueText(k, values[k] ?? ""))
          .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
      }
      if let n = c.input["note"] as? String, !n.isEmpty {
        (Text(tr("이유  ", "Why  ")).fontWeight(.semibold).foregroundColor(.secondary) + Text(n))
          .font(.caption).fixedSize(horizontal: false, vertical: true)
      }
      if let e = l.failed { Text(e).font(.caption).foregroundStyle(.red) }
    }
    .opacity(l.skipped ? 0.6 : 1)
    .padding(7)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
  }

  private func other(_ l: AIChat.Line) -> some View {
    let name = l.call?.name ?? ""
    let title = Self.names[name].map { tr($0.0, $0.1) } ?? name
    let detail = name == "history" ? (l.call?.input["action"] as? String == "undo" ? tr(" · 되돌리기", " · undo") : tr(" · 스냅샷", " · snapshot")) : ""
    return HStack(alignment: .firstTextBaseline, spacing: 6) {
      Image(systemName: l.failed == nil ? "checkmark" : "xmark").font(.caption2.weight(.bold))
        .foregroundStyle(l.failed == nil ? Color.green : .red)
      Text(title + detail + (l.failed.map { " · " + $0 } ?? "")).font(.caption).foregroundStyle(l.failed == nil ? Color.secondary : .red)
    }
  }
}

/// Before → after numbers of a finished request: what the steps did to the picture as a whole.
struct AIResultNumbers: View {
  let before: Look
  let after: Look

  var body: some View {
    let items: [(String, Double, Double)] = [(tr("밝기", "Brightness"), before.mid, after.mid),
                                             (tr("따뜻함", "Warmth"), before.warmth, after.warmth),
                                             (tr("대비", "Contrast"), before.contrast, after.contrast),
                                             (tr("채도", "Saturation"), before.saturation, after.saturation)]
    LazyVGrid(columns: [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)], spacing: 6) {
      ForEach(items, id: \.0) { name, a, b in
        VStack(alignment: .leading, spacing: 2) {
          Text(name).font(.caption2).foregroundStyle(.secondary)
          (Text(String(format: "%.2f → ", a)) + Text(String(format: "%.2f", b)).fontWeight(.semibold))
            .font(.caption.monospacedDigit())
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.2)))
      }
    }
    .help(tr("요청 전 사진과 AI 초안의 전체 수치 (0…1, 따뜻함은 빨강−파랑)", "The whole picture before the request and in the AI draft (0…1; warmth is red − blue)"))
  }
}
