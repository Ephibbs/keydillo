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
    if let msg = verdict(text, tool: tool, services: services, cwd: obj["cwd"] as? String) {
      FileHandle.standardError.write(Data(("keydillo: " + msg + "\n").utf8))
      exit(2)
    }
    exit(0)
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
