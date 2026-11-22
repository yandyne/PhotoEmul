import AppKit
import Foundation

/// `PhotoEmul --mcp`: an MCP server on stdin/stdout that relays each tool call to the app's
/// agent socket (Settings › AI), opening the app first when it is not running.
enum MCP {
  typealias JSON = AgentCommands.JSON

  static func run() -> Never {
    var socket: FileHandle?
    while let line = readLine(strippingNewline: true) {
      guard let reply = handle(line, call: { cmd in
        if socket == nil { socket = connect() }
        guard let s = socket else {
          return ["ok": false, "error": "PhotoEmul is not answering; turn on Settings › AI › Allow Outside AI Connections"]
        }
        guard let r = exchange(s, cmd) else { socket = nil; return ["ok": false, "error": "connection to PhotoEmul closed"] }
        return r
      }) else { continue }
      print(reply)
      fflush(stdout)
    }
    exit(0)
  }

  /// One JSON-RPC line in, the reply line out (nil for notifications).
  static func handle(_ line: String, call: (JSON) -> JSON) -> String? {
    guard let req = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? JSON else {
      return encode(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "parse error"]])
    }
    guard let id = req["id"] else { return nil }
    let params = req["params"] as? JSON ?? [:]
    var out: JSON = ["jsonrpc": "2.0", "id": id]
    switch req["method"] as? String {
    case "initialize":
      out["result"] = ["protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                       "capabilities": ["tools": [:] as JSON],
                       "serverInfo": ["name": "photoemul",
                                      "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"]]
    case "ping": out["result"] = [:] as JSON
    case "tools/list": out["result"] = ["tools": tools()]
    case "tools/call":
      let name = params["name"] as? String ?? ""
      guard tools().contains(where: { $0["name"] as? String == name }) else {
        out["error"] = ["code": -32602, "message": "unknown tool \(name)"]
        break
      }
      let reply = call((params["arguments"] as? JSON ?? [:]).merging(["cmd": name]) { $1 })
      let ok = reply["ok"] as? Bool == true
      var result = reply["result"] ?? reply["error"] ?? NSNull()
      var content: [JSON] = []
      if ok, var r = result as? JSON, let png = r.removeValue(forKey: "png") as? String {
        content.append(["type": "image", "data": png, "mimeType": "image/png"])
        result = r
      }
      content.insert(["type": "text", "text": encode(result) ?? "\(result)"], at: 0)
      out["result"] = ["content": content, "isError": !ok]
    default: out["error"] = ["code": -32601, "message": "method not found"]
    }
    return encode(out)
  }

  static func tools() -> [JSON] {
    let names = Catalog.params.map { d in
      d.maximum > d.minimum ? "\(d.name) (\(d.minimum)…\(d.maximum))" : d.name
    }.joined(separator: ", ")
    func tool(_ name: String, _ text: String, _ props: JSON = [:], _ required: [String] = []) -> JSON {
      ["name": name, "description": text,
       "inputSchema": ["type": "object", "properties": props, "required": required] as JSON]
    }
    let str: JSON = ["type": "string"], obj: JSON = ["type": "object"], num: JSON = ["type": "number"]
    return [
      tool("params", "All adjustable settings: name, label, group, kind, range, default, options (film and paper names)."),
      tool("presets", "Names of the user's saved presets."),
      tool("state", "Current values (the AI draft while a request runs), film, paper, history and view."),
      tool("begin", "Start a request. Changes go to a draft the user sees beside their own photo; nothing reaches their history until they apply it.",
           ["request": str.merging(["description": "Short title shown to the user"]) { $1 }, "agent": str]),
      tool("set", "One draft step; each step is its own tile in the user's history. Work like a person: one step per tool or idea, in the order you would do them (e.g. exposure, then halation, then grain), each with a label and note. Put several values in one step only when they belong to the same tool. Print settings work like an enlarger: more printExposureEv makes the print darker; filterYShift below 0 is yellower/warmer, above 0 bluer; filterMShift below 0 is more magenta, above 0 greener. When unsure of a direction, check with measure or capture. Values are checked first; films and papers by name or index. Settings: " + names,
           ["values": obj, "label": str, "note": str.merging(["description": "Why, shown to the user in the review"]) { $1 }], ["values"]),
      tool("preset", "One draft step from a saved preset.", ["name": str, "note": str], ["name"]),
      tool("history", "undo (the last draft step) or snapshot (save the user's current values).",
           ["action": ["type": "string", "enum": ["undo", "snapshot"]] as JSON, "name": str], ["action"]),
      tool("finish", "Done: the user reviews the steps and applies all, some, or none."),
      tool("apply", "Apply the draft now (optional upTo: only the first n steps).", ["upTo": num]),
      tool("discard", "Drop the draft."),
      tool("view", "Canvas view: compare (mode) and zoom (fit, fill or a scale).", ["compare": str, "zoom": ["type": ["string", "number"]] as JSON]),
      tool("capture", "PNG of the current preview, to look at the result.", ["width": num]),
      tool("reference", "Reference photos to match (the user may drop them on the AI tab; state shows how many). paths replaces them ([] clears); without paths, returns the current ones: each photo's look numbers, their mean and range, and a picture of them.",
           ["paths": ["type": "array", "items": str] as JSON]),
      tool("measure", "Look numbers of the preview (the draft during a request): warmth (red−blue), tint, black/mid/white luminance, contrast, saturation, grain. With reference photos also target, difference (preview − target) and distance (0 = same; work it down step by step)."),
      tool("open", "Open a photo the user named by path.", ["path": str], ["path"]),
      tool("export", "Export to a new file inside the folder set in Settings › AI (.jpg or .tif); never overwrites.", ["path": str], ["path"]),
    ]
  }

  static func encode(_ v: Any) -> String? {
    guard JSONSerialization.isValidJSONObject([v]),
          let data = try? JSONSerialization.data(withJSONObject: v, options: [.sortedKeys, .fragmentsAllowed, .withoutEscapingSlashes]) else { return nil }
    return String(decoding: data, as: UTF8.self)
  }

  /// Connects (opening this copy of the app and waiting up to 20 s if none runs) and says hello with the stored token.
  private static func connect() -> FileHandle? {
    var s = AgentServer.connect()
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
      .filter { $0.processIdentifier != getpid() }
    if s == nil, others.isEmpty {
      let config = NSWorkspace.OpenConfiguration()
      config.createsNewApplicationInstance = true  // this relay process shares the bundle
      NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config)
      for _ in 0..<40 where s == nil {
        Thread.sleep(forTimeInterval: 0.5)
        s = AgentServer.connect()
      }
    }
    guard let s, let hello = exchange(s, ["cmd": "hello", "token": UserDefaults.standard.string(forKey: AgentServer.tokenKey) ?? ""]),
          hello["ok"] as? Bool == true else { return nil }
    return s
  }

  private static func exchange(_ s: FileHandle, _ req: JSON) -> JSON? {
    guard let line = encode(req), (try? s.write(contentsOf: Data((line + "\n").utf8))) != nil else { return nil }
    var got = Data()
    while !got.contains(0x0A) {
      let d = s.availableData
      if d.isEmpty { return nil }
      got.append(d)
    }
    return try? JSONSerialization.jsonObject(with: got) as? JSON
  }
}
