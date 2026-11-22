import CoreGraphics
import Foundation

/// `--self-test`: checks the settings migration and the batch list reader on scratch data, then exits.
enum SelfTest {
  static func run() -> Int32 {
    var failures = 0
    func check(_ ok: Bool, _ name: String) {
      print(ok ? "ok   \(name)" : "FAIL \(name)")
      if !ok { failures += 1 }
    }

    let files = FileManager.default
    let dir = files.temporaryDirectory.appendingPathComponent("PhotoEmul-selftest-\(UUID().uuidString)")
    try? files.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? files.removeItem(at: dir) }

    // Migration: two old names, the newer one must win, the store's own values must stay.
    let olds: [Rename.Predecessor] = [
      ("com.yandyne.PhotoEmul.selftest.old1", "Old1", "selftestDone1"),
      ("com.yandyne.PhotoEmul.selftest.old2", "Old2", "selftestDone2"),
    ]
    let suite = "com.yandyne.PhotoEmul.selftest.new"
    let scratch = UserDefaults.standard
    scratch.setPersistentDomain(["shared": "old1", "onlyOld1": 1, ExportOptions.nameKey: ExportOptions.legacyDefaultNames[0]],
                                forName: olds[0].domain)
    scratch.setPersistentDomain(["shared": "old2", "kept": "old2"], forName: olds[1].domain)
    scratch.removePersistentDomain(forName: suite)
    defer {
      // Emptied domains still leave a plist behind, so remove the files too.
      let prefs = files.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Preferences")
      for d in olds.map(\.domain) + [suite] {
        scratch.removePersistentDomain(forName: d)
        CFPreferencesAppSynchronize(d as CFString)
        try? files.removeItem(at: prefs.appendingPathComponent("\(d).plist"))
      }
    }
    let store = UserDefaults(suiteName: suite)!
    store.set("mine", forKey: "kept")

    let support = dir.appendingPathComponent("Support"), caches = dir.appendingPathComponent("Caches")
    for (base, name) in [(support, "Old2"), (support, "Old1"), (caches, "Old1")] {
      try? files.createDirectory(at: base.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    files.createFile(atPath: support.appendingPathComponent("Old2/from2").path, contents: Data())

    Rename.migrate(from: olds, into: store, support: support, caches: caches)
    check(store.string(forKey: "shared") == "old2", "migrate: newest name wins")
    check(store.integer(forKey: "onlyOld1") == 1, "migrate: older name fills gaps")
    check(store.string(forKey: "kept") == "mine", "migrate: existing value kept")
    check(store.object(forKey: ExportOptions.nameKey) == nil, "migrate: legacy export name dropped")
    check(files.fileExists(atPath: support.appendingPathComponent("\(Rename.folder)/from2").path), "migrate: newest folder copied")
    check(!files.fileExists(atPath: caches.appendingPathComponent("Old1").path), "migrate: old cache removed")
    check(store.bool(forKey: "selftestDone1") && store.bool(forKey: "selftestDone2"), "migrate: done flags set")

    // Batch list: tabs, blank lines, missing key, empty fields.
    let list = dir.appendingPathComponent("list.txt")
    try? "/a.jpg\t/a.tif\tkeyA\n\n/b.jpg\t/b.tif\n/c.jpg\t\tkeyC\n/d.jpg\n/e.jpg\t/e.tif\t\n"
      .write(to: list, atomically: true, encoding: .utf8)
    let items = BatchItem.readList(list)
    check(items.map(\.input.path) == ["/a.jpg", "/b.jpg", "/e.jpg"], "readList: bad lines skipped")
    check(items.map(\.key) == ["keyA", "/b.jpg", "/e.jpg"], "readList: key falls back to input")
    check(items.first?.output.path == "/a.tif", "readList: output read")
    check(BatchItem.readList(dir.appendingPathComponent("missing.txt")).isEmpty, "readList: missing file is empty")

    // Process scope: film kind x process mode -> mode the engine runs, film/paper used, conflict.
    let kinds: [(String, (String) -> Bool)] = [
      ("negative", { FilmInfo.category($0) == .negative }), ("cine", { FilmInfo.category($0) == .cine }),
      ("bw negative", { FilmInfo.category($0) == .bw && !FilmInfo.isPositive($0) }),
      ("slide", { FilmInfo.category($0) == .slide }), ("instant", { FilmInfo.category($0) == .instant }),
      ("bw reversal", { FilmInfo.category($0) == .bw && FilmInfo.isPositive($0) }),
    ]
    for (kind, match) in kinds {
      guard let film = Catalog.films.firstIndex(where: match) else { check(false, "scope: \(kind) stock exists"); continue }
      let positive = FilmInfo.isPositive(Catalog.films[film])
      for process in 0...2 {
        let v: [String: ParamValue] = ["film": .int(film), "process": .int(process)]
        let mode = positive && process == 0 ? 1 : process
        check(ProcessScope.mode(v) == mode && ProcessScope.usesFilm(v) == (mode != 2)
              && ProcessScope.usesPaper(v) == (mode != 1) && (ProcessScope.conflict(v) != nil) == (positive && process == 2),
              "scope: \(kind) process \(process)")
      }
    }

    // Tool levels: the process mode stays reachable at beginner in both layouts; Film Prep has nothing for a beginner.
    for key in [PanelLayouts.classicKey, PanelLayouts.workflowKey] {
      let stages = PanelLayouts.resolve(PanelLayouts.layout(key)!, key: key).stages
      let basic = stages.flatMap(\.specs).filter { $0.level == .beginner }
      check(basic.contains { PanelLayouts.shown($0).contains("process") }, "level: \(key) process at beginner")
      if key == PanelLayouts.workflowKey {
        check(stages.first { $0.id == "film" }?.specs.allSatisfy { $0.level > .beginner } == true, "level: film prep hidden at beginner")
      }
    }

    // Beginner rows name real params of their module.
    for spec in Modules.all where !spec.basic.isEmpty {
      let bad = spec.basic.filter { n in Catalog.byName[n].map { !spec.groups.contains($0.group) && !spec.names.contains(n) } ?? true }
      check(bad.isEmpty, "level: \(spec.id) basic rows \(bad)")
    }
    check(PanelLayouts.resolve(PanelLayouts.layout(PanelLayouts.classicKey)!, key: PanelLayouts.classicKey).stages
            .flatMap(\.specs).first { $0.id == "print" }?.basic.isEmpty == false, "level: basic rows survive layout")

    // Soft proof: mid grey passes through sRGB unchanged; pure P3 green is out of gamut and lands on sRGB green.
    let proof = SoftProof.lut(CGColorSpace(name: CGColorSpace.sRGB)!, intent: .perceptual)
    let n = SoftProof.size, mid = (n - 1) / 2
    func entry(_ r: Int, _ g: Int, _ b: Int) -> ArraySlice<UInt16> { let i = ((b * n + g) * n + r) * 4; return proof[i..<i + 4] }
    let grey = entry(mid, mid, mid)
    check(grey.prefix(3).allSatisfy { abs(Int($0) - 32768) < 300 } && grey.last == 0, "proof: grey unchanged")
    let green = entry(0, n - 1, 0)
    check(green.last == 65535 && green.first! > 20000, "proof: P3 green flagged and mapped")

    // Agent commands work on a draft: the user's history stays put until apply, which adds one
    // AI group (one undo), keeps the user's value where both changed, and survives the session file.
    let agentModel = EditModel(input: nil, output: nil)
    func agent(_ req: AgentCommands.JSON) -> AgentCommands.JSON { AgentCommands.run(req, model: agentModel) }
    if let d = Catalog.params.first(where: { $0.kind == .double && $0.maximum > $0.minimum }) {
      let before = agentModel.value(d.name), mid = (d.minimum + d.maximum) / 2
      let target = abs((before.doubleValue ?? 0) - mid) > 1e-6 ? mid : d.minimum
      let mine = [d.minimum, d.maximum, mid].first { abs($0 - (before.doubleValue ?? 0)) > 1e-6 && $0 != target } ?? d.maximum
      let film = Catalog.films.count > 1 ? Catalog.films[1] : Catalog.films[0]
      check(agent(["cmd": "begin", "request": "test", "agent": "SelfTest"])["ok"] as? Bool == true, "agent: begin")
      check(agent(["cmd": "set", "values": [d.name: target, "film": FilmInfo.displayName(film)], "label": "agent", "note": "why"])["ok"] as? Bool == true,
            "agent: set")
      let state = agent(["cmd": "state"])["result"] as? AgentCommands.JSON
      let values = state?["values"] as? AgentCommands.JSON
      check(values?[d.name] as? Double == target && values?["film"] as? Int == Catalog.films.firstIndex(of: film),
            "agent: state reads back the draft")
      check(agentModel.value(d.name) == before && agentModel.historyCount == 0, "agent: user's values and history untouched")
      _ = agent(["cmd": "set", "values": ["film": 0]])
      let undone = agent(["cmd": "history", "action": "undo"])["result"] as? AgentCommands.JSON
      check(AgentSession.shared.steps.count == 1 && undone?["steps"] as? Int == 1, "agent: undo drops the last draft step")
      let bad = agent(["cmd": "set", "values": [d.name: d.maximum + 1, "noSuchParam": 1]])
      check(bad["ok"] as? Bool == false && AgentSession.shared.steps.count == 1, "agent: bad values refused, nothing changed")
      agentModel.set(d.name, .double(mine))
      agentModel.commit(label: "mine")
      let kept = agent(["cmd": "apply"])["result"] as? AgentCommands.JSON
      check(kept?["kept"] as? [String] == [d.name] && agentModel.value(d.name) == .double(mine)
              && agentModel.value("film") == .int(Catalog.films.firstIndex(of: film) ?? -1),
            "agent: apply keeps the user's value where both changed")
      let last = agentModel.historyEntry(agentModel.historyCount)
      check(last.source == "ai:SelfTest" && last.note == "why" && last.group != nil && !AgentSession.shared.active,
            "agent: applied as a marked AI group")
      let stored = StoredHistory(undo: agentModel.undoStack, redo: [], base: agentModel.values).stacks(base: agentModel.values)
      check(stored.undo.last?.source == "ai:SelfTest" && stored.undo.last?.note == "why", "agent: source and note saved")
      agentModel.undo()
      check(agentModel.historyEntry(agentModel.historyPosition).label == "mine", "agent: one undo removes the AI group")

      // Review: apply only the first of two steps; the lesson carries the agent's reasons.
      let count = agentModel.historyPosition, had = agentModel.value(d.name)
      _ = agent(["cmd": "begin", "request": "review", "agent": "SelfTest"])
      let other = agentModel.value("film") == .int(0) ? 1 : 0
      _ = agent(["cmd": "set", "values": ["film": other], "note": "first"])
      _ = agent(["cmd": "set", "values": [d.name: d.maximum], "note": "second"])
      check(AgentSession.shared.lesson().contains("first") && AgentSession.shared.lesson().contains("second"), "agent: lesson has the reasons")
      _ = agent(["cmd": "apply", "upTo": 1])
      check(agentModel.historyPosition == count + 1 && agentModel.value("film") == .int(other) && agentModel.value(d.name) == had
              && agentModel.historyEntry(agentModel.historyCount).group?.name.contains("1") == true,
            "agent: apply up to a step skips the rest")
    }
    check((try? AgentCommands.parse("film", "999999")) == nil, "agent: stock index range checked")
    check(agent(["cmd": "export", "path": "/tmp/x.tif"])["ok"] as? Bool == false, "agent: export outside folder refused")
    check(JSONSerialization.isValidJSONObject(AgentCommands.params()), "agent: params are JSON")

    // Socket: a wrong first line closes the connection; after hello, commands answer with their id.
    AgentCommands.model = agentModel  // the socket drives this model, as it would an editor window
    let server = AgentServer(token: "selftest"), sock = URL(fileURLWithPath: "/tmp/photoemul-test-\(getpid()).sock")  // the scratch folder path is too long for a socket
    server.start(at: sock)
    var lines: [String] = []
    let talked = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
      func talk(_ text: String) -> String {
        guard let h = AgentServer.connect(sock) else { return "no connection" }
        try? h.write(contentsOf: Data(text.utf8))
        var got = Data()
        while case let d = h.availableData, !d.isEmpty { got.append(d); if got.filter({ $0 == 0x0A }).count >= text.filter({ $0 == "\n" }).count { break } }
        return String(decoding: got, as: UTF8.self)
      }
      lines = [talk("{\"cmd\":\"params\"}\n"),
               talk("{\"cmd\":\"hello\",\"token\":\"selftest\"}\n{\"cmd\":\"presets\",\"id\":7}\n")]
      // A client that drops mid-request must not lock the draft for the next one.
      _ = talk("{\"cmd\":\"hello\",\"token\":\"selftest\"}\n{\"cmd\":\"begin\",\"request\":\"dropped\"}\n")
      Thread.sleep(forTimeInterval: 0.3)
      lines.append(talk("{\"cmd\":\"hello\",\"token\":\"selftest\"}\n{\"cmd\":\"discard\"}\n"))
      talked.signal()
    }
    let deadline = Date().addingTimeInterval(10)
    while talked.wait(timeout: .now()) == .timedOut, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    server.stop()
    check(lines.first?.contains("hello") == true, "socket: hello required first")
    check(lines.count > 1 && lines[1].contains("\"id\":7") && lines[1].contains("\"ok\":true"), "socket: command answered with its id")
    check(lines.count == 3 && !lines[2].contains("busy") && lines[2].contains("\"ok\":true"), "socket: dropped client frees the draft")
    check(!FileManager.default.fileExists(atPath: sock.path), "socket: file removed on stop")

    // MCP relay: handshake and tool list answer locally; a call is relayed as {"cmd": tool, …arguments}.
    let initReply = MCP.handle(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18"}}"#) { _ in [:] }
    check(initReply?.contains("\"tools\"") == true && initReply?.contains("2025-06-18") == true, "mcp: initialize")
    check(MCP.handle(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) { _ in [:] } == nil, "mcp: notification gets no reply")
    let toolList = MCP.handle(#"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#) { _ in [:] } ?? ""
    check(toolList.contains("\"set\"") && toolList.contains("\"export\""), "mcp: tools listed")
    var relayed: AgentCommands.JSON = [:]
    let called = MCP.handle(#"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"capture","arguments":{"width":64}}}"#) {
      relayed = $0
      return ["ok": true, "result": ["png": "AAAA", "width": 64]]
    } ?? ""
    check(relayed["cmd"] as? String == "capture" && relayed["width"] as? Int == 64 && called.contains("image/png")
            && called.contains("\"isError\":false"), "mcp: call relayed, image returned")

    // AI tab: a Claude reply's text and tool calls are read, and results go back in one user message.
    let claudeReply: AgentCommands.JSON = ["stop_reason": "tool_use", "usage": ["input_tokens": 10, "cache_read_input_tokens": 5, "output_tokens": 3],
      "content": [["type": "thinking", "thinking": "", "signature": "s"], ["type": "text", "text": "Warmer."],
                  ["type": "tool_use", "id": "t1", "name": "set", "input": ["values": ["film": 0]]]]]
    let turn = try? ClaudeAPI.parse(claudeReply)
    check(turn?.text == "Warmer." && turn?.calls.first?.name == "set" && turn?.calls.first?.id == "t1" && turn?.input == 15
            && (turn?.message["content"] as? [Any])?.count == 3, "ai: claude reply parsed, content kept verbatim")
    check((try? ClaudeAPI.parse(["stop_reason": "refusal", "content": []])) == nil, "ai: refusal reported")
    let back = ClaudeAPI().results([AIResult(id: "t1", text: "{}", png: "AAAA", isError: false), AIResult(id: "t2", text: "bad", png: nil, isError: true)])
    let blocks = back.first?["content"] as? [AgentCommands.JSON]
    check(back.count == 1 && blocks?.map { $0["tool_use_id"] as? String } == ["t1", "t2"] && blocks?.last?["is_error"] as? Bool == true,
          "ai: tool results in one message")
    check(!AIChat.tools.contains { $0["name"] as? String == "begin" } && AIChat.tools.contains { $0["name"] as? String == "set" },
          "ai: tab owns begin/finish")
    let priced = try? ClaudeAPI.parse(claudeReply.merging(["model": "claude-opus-5-5"]) { $1 })
    check(turn?.cost == nil && abs((priced?.cost ?? 0) - 0.000102) < 1e-9, "ai: cost from model price, cache reads at 0.1×")
    let openAIReply: AgentCommands.JSON = ["usage": ["prompt_tokens": 7, "completion_tokens": 2],
      "choices": [["message": ["role": "assistant", "content": NSNull(), "tool_calls": [
        ["id": "c1", "type": "function", "function": ["name": "set", "arguments": #"{"values":{"film":1}}"#]],
        ["id": "c2", "type": "function", "function": ["name": "state", "arguments": ["x": 1]]]]]]]]
    let oTurn = try? OpenAICompatible.parse(openAIReply)
    check(oTurn?.text == "" && oTurn?.calls.map(\.id) == ["c1", "c2"] && (oTurn?.calls.first?.input["values"] as? AgentCommands.JSON)?["film"] as? Int == 1
            && oTurn?.calls.last?.input["x"] as? Int == 1 && oTurn?.input == 7, "ai: openai reply parsed, string or object arguments")
    check((try? OpenAICompatible.parse(["choices": []])) == nil, "ai: openai empty reply reported")
    let oBack = OpenAICompatible().results([AIResult(id: "c1", text: "{}", png: "AAAA", isError: false), AIResult(id: "c2", text: "x", png: nil, isError: true)])
    check(oBack.prefix(2).map { $0["tool_call_id"] as? String } == ["c1", "c2"] && oBack.prefix(2).allSatisfy { $0["role"] as? String == "tool" },
          "ai: openai tool messages per call")

    // Look numbers (reference matching).
    if let ctx = CGContext(data: nil, width: 64, height: 64, bitsPerComponent: 8, bytesPerRow: 256,
                           space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) {
      ctx.setFillColor(CGColor(srgbRed: 0.8, green: 0.55, blue: 0.3, alpha: 1))
      ctx.fill(CGRect(x: 0, y: 0, width: 64, height: 64))
      let look = ctx.makeImage().flatMap(Look.init)
      check(look.map { $0.warmth > 0.3 && $0.distance($0) == 0 && $0.grain < 0.01 } == true, "look: warm flat patch")
    }
    // AI tab step values read as the user sees them (a JSON 1 is a number, true is 켬/on).
    check(AIChat.valueText("printGamma", 1.1) == 1.1.formatted(.number.precision(.fractionLength(0...2)))
          && AIChat.valueText("x", true) == tr("켬", "on") && AIChat.valueText("film", 0) == FilmInfo.displayName(Catalog.films[0]), "ai tab: value text")
    // User add-ins: JSON blocks and a stdio program.
    let calls = UserAddIn.blocks("ok\n```json\n{\"tool\": \"set\", \"arguments\": {\"values\": {\"filterC\": 5}}}\n```\nand ```{\"tool\":\"finish\"}```")
    check(calls.map(\.name) == ["set", "finish"] && (calls[0].input["values"] as? JSON)?["filterC"] as? Int == 5, "add-in: json blocks")
    let addInDir = FileManager.default.temporaryDirectory.appendingPathComponent("pemai-\(getpid()).pemai")
    try? FileManager.default.createDirectory(at: addInDir, withIntermediateDirectories: true)
    let script = addInDir.appendingPathComponent("run.sh")
    try? "#!/bin/sh\ncat > /dev/null\necho '{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":\"```json {\\\"tool\\\":\\\"state\\\"} ```\"}}]}'\n"
      .write(to: script, atomically: true, encoding: .utf8)
    try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
    let addIn = UserAddIn(folder: addInDir, manifest: .init(name: "t", kind: "stdio", executable: "run.sh", tools: false))
    let done = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var got: AITurn?
    Task.detached { got = try? await addIn.turn(system: "s", messages: [addIn.user("hi", png: nil)], tools: [], model: "default"); done.signal() }
    done.wait()
    check(got?.calls.first?.name == "state", "add-in: stdio turn")
    try? FileManager.default.removeItem(at: addInDir)
    print(failures == 0 ? "self-test passed" : "self-test: \(failures) failed")
    return failures == 0 ? 0 : 1
  }
}
