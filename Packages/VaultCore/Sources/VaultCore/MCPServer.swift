import Foundation

/// Minimal MCP server (JSON-RPC 2.0 over stdio, one message per line).
/// Exposes service names and a way to ask the user for a key. Never returns key values.
public final class MCPServer {
  let send: (ControlRequest) throws -> ControlResponse
  let cwd: String
  let requester: String

  public init(cwd: String = FileManager.default.currentDirectoryPath, requester: String = "claude",
              send: @escaping (ControlRequest) throws -> ControlResponse = { try ControlSocket.send($0) }) {
    self.send = send; self.cwd = cwd; self.requester = requester
  }

  static let tools: [[String: Any]] = [
    [
      "name": "status",
      "description": "What keydillo is doing: whether the proxy is up and on which port, which keys exist (names only), and recent refusals with reasons. Check this when a keydillo request fails.",
      "inputSchema": ["type": "object", "properties": [String: Any]()],
    ],
    [
      "name": "list_services",
      "description": "List API services stored in keydillo: names, local proxy base URLs and env var names. Never returns key values.",
      "inputSchema": ["type": "object", "properties": [String: Any]()],
    ],
    [
      "name": "open_project",
      "description": "Ask the user to approve all of a project's keys at once with one Touch ID, instead of one prompt per key. Use it at the start of work that will call several of the project's APIs, or when the user is away and asked you to work unattended. How long it lasts is the user's setting; you can't choose it. Defaults to the project of the current folder.",
      "inputSchema": ["type": "object", "properties": ["project": ["type": "string", "description": "Project name, if not the current folder's"]]],
    ],
    [
      "name": "request_key_change",
      "description": "Ask the user to approve a change to a stored key. A window on their Mac shows exactly what changes and they approve with Touch ID; you never see the key. Use: kind=auth when calls fail because the key is sent the wrong way (header name, Bearer prefix, Basic auth, query parameter) or has no site yet (host); kind=share to use an existing key in another project instead of asking for a second copy; kind=rotate when the provider rejected the key or the user wants a new one (they paste it); kind=move_folder when a project's folder moved or was renamed. You can't ask to show a key, turn off Touch ID prompts or make them less frequent; the user does that in keydillo.",
      "inputSchema": [
        "type": "object",
        "required": ["kind"],
        "properties": [
          "kind": ["type": "string", "enum": ["auth", "share", "rotate", "move_folder"]],
          "service": ["type": "string", "description": "Key name (from list_services); for auth, share and rotate"],
          "project": ["type": "string", "description": "share: the project that should also use the key. move_folder: the project that moved"],
          "header": ["type": "string", "description": "auth: header that carries the key, e.g. Authorization"],
          "prefix": ["type": "string", "description": "auth: value prefix, e.g. 'Bearer '"],
          "basic_auth": ["type": "boolean", "description": "auth: send the key as HTTP Basic auth"],
          "query_param": ["type": "string", "description": "auth: send the key as this query parameter instead of a header"],
          "host": ["type": "string", "description": "auth: the API host this key is for (adds it to the key's sites), e.g. api.together.xyz"],
          "folder": ["type": "string", "description": "move_folder: the project's new folder (absolute path)"],
          "why": ["type": "string", "description": "One sentence shown to the user explaining why"],
        ],
      ],
    ],
    [
      "name": "request_secret",
      "description": "Ask the user to add an API key to keydillo. Opens a window on the user's Mac where they paste the key; you never see it. Fill in the API's real host and auth header. Returns the local base URL and placeholder .env lines to use instead of the key.",
      "inputSchema": [
        "type": "object",
        "required": ["service", "host", "header"],
        "properties": [
          "service": ["type": "string", "description": "Short lowercase name used in the URL, e.g. elevenlabs"],
          "display_name": ["type": "string", "description": "Human name, e.g. ElevenLabs"],
          "host": ["type": "string", "description": "API host the key may be sent to, e.g. api.elevenlabs.io"],
          "header": ["type": "string", "description": "Header that carries the key, e.g. xi-api-key or Authorization"],
          "prefix": ["type": "string", "description": "Value prefix, e.g. 'Bearer ' for Authorization headers"],
          "env_var_name": ["type": "string", "description": "Env var name for the key, e.g. ELEVENLABS_API_KEY"],
          "project": ["type": "string", "description": "Project to file the key under (defaults to the current folder name)"],
          "is_public": ["type": "boolean", "description": "True for keys meant to ship to browsers (Stripe pk_, Supabase anon, Firebase web config, NEXT_PUBLIC_*). Those don't need keydillo."],
          "key_page_url": ["type": "string", "description": "The provider's page where the user creates or rotates this key, e.g. https://elevenlabs.io/app/settings/api-keys"],
        ],
      ],
    ],
  ]

  /// Handles one JSON-RPC line. Returns nil for notifications.
  public func handle(line: String) -> String? {
    guard let data = line.data(using: .utf8),
          let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let method = msg["method"] as? String else { return nil }
    let id = msg["id"]
    if id == nil { return nil }
    var result: [String: Any]
    switch method {
    case "initialize":
      result = ["protocolVersion": (msg["params"] as? [String: Any])?["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [String: Any]()],
                "serverInfo": ["name": "keydillo", "version": "0.1.1"]]
    case "tools/list":
      result = ["tools": Self.tools]
    case "tools/call":
      let params = msg["params"] as? [String: Any] ?? [:]
      result = call(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:])
    case "ping":
      result = [:]
    default:
      return Self.encode(["jsonrpc": "2.0", "id": id!, "error": ["code": -32601, "message": "Method not found"]])
    }
    return Self.encode(["jsonrpc": "2.0", "id": id!, "result": result])
  }

  func text(_ s: String, error: Bool = false) -> [String: Any] {
    ["content": [["type": "text", "text": s]], "isError": error]
  }

  func call(_ name: String, _ args: [String: Any]) -> [String: Any] {
    do {
      switch name {
      case "status":
        guard case .status(let st) = try send(.status) else { return text("Unexpected reply", error: true) }
        var lines = [st.proxyRunning ? "Proxy running at http://localhost:\(st.port)." : "Proxy is not running (\(st.proxyState)). Tell the user; requests will fail until it's back."]
        lines.append("Keys: " + (st.services.isEmpty ? "none yet." : st.services.map { "\($0.name) (\($0.project))" }.joined(separator: ", ")))
        lines.append("Storage: \(st.storage).")
        if !st.recentBlocks.isEmpty { lines.append("Recent refusals:\n" + st.recentBlocks.map { "- " + $0 }.joined(separator: "\n")) }
        return text(lines.joined(separator: "\n"))
      case "list_services":
        guard case .services(let list) = try send(.listServices) else { return text("Unexpected reply", error: true) }
        if list.isEmpty { return text("No services yet. Use request_secret to ask the user for a key.") }
        let lines = list.map { "\($0.name) (\($0.displayName), project \($0.project)): \($0.baseURL)  env: \($0.placeholderEnvLines.joined(separator: ", "))" }
        return text(lines.joined(separator: "\n"))
      case "open_project":
        switch try send(.openProject(OpenProjectRequest(project: args["project"] as? String))) {
        case .opened(let p, let names, let span):
          return text("The user approved \(p)'s keys (\(names.joined(separator: ", "))) \(span), for programs running in that project's folder. Call them through their keydillo base URLs as usual.")
        case .declined: return text("The user declined. Keys will still ask for Touch ID one at a time.")
        case .error(let m): return text(m, error: true)
        default: return text("Unexpected reply", error: true)
        }
      case "request_key_change":
        guard let kind = (args["kind"] as? String).flatMap(ChangeRequest.Kind.init) else { return text("kind must be auth, share, rotate or move_folder", error: true) }
        let r = ChangeRequest(kind: kind, service: args["service"] as? String, project: args["project"] as? String, header: args["header"] as? String,
                              prefix: args["prefix"] as? String, basicAuth: args["basic_auth"] as? Bool, queryParam: args["query_param"] as? String,
                              folder: args["folder"] as? String, host: args["host"] as? String, why: args["why"] as? String)
        switch try send(.requestChange(r)) {
        case .changed(let what): return text("The user approved: \(what)")
        case .declined: return text("The user declined the change. Don't ask again unless they bring it up.")
        case .error(let m): return text(m, error: true)
        default: return text("Unexpected reply", error: true)
        }
      case "request_secret":
        if args["is_public"] as? Bool == true {
          return text("Public keys (publishable/anon/browser keys) don't need keydillo. Ask the user to put it in the project's .env directly; it's safe to see.")
        }
        guard let service = args["service"] as? String, let host = args["host"] as? String, let header = args["header"] as? String else {
          return text("service, host and header are required", error: true)
        }
        let req = SecretRequest(service: service.lowercased(), displayName: args["display_name"] as? String, host: host,
                                header: header, prefix: args["prefix"] as? String, envVarName: args["env_var_name"] as? String,
                                project: args["project"] as? String ?? URL(fileURLWithPath: cwd).lastPathComponent,
                                cwd: cwd, requester: requester, keyPageURL: args["key_page_url"] as? String)
        switch try send(.requestSecret(req)) {
        case .saved(let s, let lines):
          return text("""
          Saved by the user. Call the API through \(s.baseURL) instead of https://\(s.host); keydillo adds the key and asks the user for Touch ID.
          Add these lines to the project's local .env (they contain no secret):
          \(lines.joined(separator: "\n"))
          In code, read \(s.baseURLEnvName) and fall back to https://\(s.host) when it's unset, so production keeps working with a real key.
          """)
        case .declined: return text("The user declined to add the key.")
        case .error(let m): return text(m, error: true)
        default: return text("Unexpected reply", error: true)
        }
      default:
        return text("Unknown tool \(name)", error: true)
      }
    } catch {
      return text(error.localizedDescription, error: true)
    }
  }

  static func encode(_ obj: [String: Any]) -> String {
    let d = (try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes])) ?? Data()
    return String(decoding: d, as: UTF8.self)
  }

  /// Runs until stdin closes.
  public func run() {
    while let line = readLine(strippingNewline: true) {
      if let out = handle(line: line) {
        FileHandle.standardOutput.write(Data((out + "\n").utf8))
      }
    }
  }
}
