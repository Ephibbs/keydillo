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
                "serverInfo": ["name": "keydillo", "version": "0.1.0"]]
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
      case "request_secret":
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
