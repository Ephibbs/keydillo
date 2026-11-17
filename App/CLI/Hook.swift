import Foundation
import VaultCore

/// Claude Code PreToolUse hook. Reads the tool call as JSON on stdin.
/// Exit 0 lets it run; exit 2 blocks it and shows stderr to the agent.
enum Hook {
  static func run() -> Never {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let obj = try? JSONSerialization.jsonObject(with: input) as? [String: Any],
          let tool = obj["tool_name"] as? String, let args = obj["tool_input"] as? [String: Any] else { exit(0) }
    let text: String
    switch tool {
    case "Bash": text = args["command"] as? String ?? ""
    case "WebFetch": text = args["url"] as? String ?? ""
    default: exit(0)
    }
    // If keydillo isn't running, never get in the way.
    guard case .services(let services)? = try? ControlSocket.send(.listServices) else { exit(0) }
    // This Claude Code session's commands already go through keydillo (session-start hook): direct calls get swapped.
    if let owner = ProcessLookup.describe(getpid()).agentPid,
       FileManager.default.fileExists(atPath: Runner.sessionsDir.appendingPathComponent("\(owner).env").path) { exit(0) }
    if let msg = verdict(text, tool: tool, services: services, cwd: obj["cwd"] as? String) {
      FileHandle.standardError.write(Data(("keydillo: " + msg + "\n").utf8))
      exit(2)
    }
    exit(0)
  }

  /// SessionStart: route every command this Claude Code session runs through a keydillo proxy that only this
  /// session's processes can use, by writing the settings to Claude Code's session env file.
  static func sessionStart() -> Never {
    _ = FileHandle.standardInput.readDataToEndOfFile()
    guard let envFile = ProcessInfo.processInfo.environment["CLAUDE_ENV_FILE"],
          let owner = ProcessLookup.describe(getpid()).agentPid else { exit(0) }
    guard let lines = Runner.shellEnv(owner: owner) else {
      print("keydillo isn't running, so API calls that use keydillo placeholders will fail until the user opens the keydillo app.")
      exit(0)
    }
    if let h = FileHandle(forWritingAtPath: envFile) { h.seekToEndOfFile(); h.write(Data(lines.utf8)); try? h.close() }
    print("keydillo routes this session's commands: when a program sends a keydillo placeholder to its API, keydillo swaps in the real key after the user approves. You don't need `keydillo run` or `kd`.")
    exit(0)
  }

  /// PostToolUse: when a provider rejected a placeholder, tell Claude why and what to do instead.
  static func post() -> Never {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let obj = try? JSONSerialization.jsonObject(with: input) as? [String: Any], obj["tool_name"] as? String == "Bash" else { exit(0) }
    let resp = obj["tool_response"]
    let text = ((resp as? [String: Any]).map { "\($0["stdout"] ?? "") \($0["stderr"] ?? "")" } ?? "\(resp ?? "")")
    guard let msg = postAdvice(text) else { exit(0) }
    let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PostToolUse", "additionalContext": msg]]
    FileHandle.standardOutput.write((try? JSONSerialization.data(withJSONObject: out)) ?? Data())
    exit(0)
  }

  static func postAdvice(_ output: String) -> String? {
    let lower = output.lowercased()
    guard lower.contains("keydillo:") || lower.contains("keydillo%3a") else { return nil }
    let rejected = ["401", "403", "unauthorized", "invalid api key", "invalid_api_key", "incorrect api key", "invalid x-api-key",
                    "authentication", "invalid key", "api key not valid", "invalid token"].contains { lower.contains($0) }
    guard rejected else { return nil }
    return "keydillo: the provider rejected a keydillo placeholder, so this program's request didn't go through keydillo (it may ignore HTTPS_PROXY, pin certificates, or run in Docker or Go). Rerun it with `kd <command>`. If it still fails, call the API through the keydillo base URL from list_services. If neither works, tell the user; don't look for the real key."
  }

  static func verdict(_ text: String, tool: String, services: [ServiceSummary], cwd: String?) -> String? {
    let lower = text.lowercased()
    let viaRun = lower.contains("keydillo run")
    let viaProxy = services.contains { lower.contains($0.baseURL.lowercased()) } || lower.contains("localhost:") && lower.contains("/")
      && services.contains { lower.contains("/\($0.name)/") }
    if viaRun || viaProxy { return nil }
    let looksLikeCall = tool == "WebFetch" || ["curl", "wget", "http", "fetch(", "requests.", "httpx", "axios", "node -e", "python", "bun ", "deno "]
      .contains { lower.contains($0) }
    guard looksLikeCall else { return nil }
    let project = cwd.map { ($0 as NSString).lastPathComponent.lowercased() }
    func pick(_ host: String) -> [ServiceSummary] {
      let all = services.filter { $0.host.lowercased() == host }
      let mine = all.filter { $0.project.lowercased() == project }
      return mine.isEmpty ? all : mine
    }
    for s in services where lower.contains(s.host.lowercased()) {
      let options = pick(s.host.lowercased())
      let addrs = options.map { "\($0.baseURL) (\($0.project))" }.joined(separator: " or ")
      return "\(s.host) is called through keydillo here. Use \(addrs) in place of https://\(s.host), with no key header; keydillo adds the key after the user approves. Or prefix the command with `keydillo run --`. Don't look for the real key."
    }
    if let name = Placeholder.service(in: text), let s = services.first(where: { $0.name == name }) {
      return "keydillo:\(name) is a placeholder, not a key. Call \(s.baseURL) instead (no key needed), or prefix the command with `keydillo run --`."
    }
    return nil
  }
}
