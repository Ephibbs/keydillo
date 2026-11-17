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
    // In a keydillo project, programs must start with `kd` so their placeholders get swapped. Catch it before it runs.
    if tool == "Bash", let msg = needsKd(text, cwd: obj["cwd"] as? String) {
      FileHandle.standardError.write(Data(("keydillo: " + msg + "\n").utf8))
      exit(2)
    }
    // If keydillo isn't running, never get in the way.
    guard case .services(let services)? = try? ControlSocket.send(.listServices) else { exit(0) }
    if let msg = verdict(text, tool: tool, services: services, cwd: obj["cwd"] as? String) {
      FileHandle.standardError.write(Data(("keydillo: " + msg + "\n").utf8))
      exit(2)
    }
    exit(0)
  }

  /// PostToolUse: when a program in a keydillo project ran without `kd` and its API refused the key, say why.
  /// (Providers don't echo a rejected key back, so this looks at the command and folder, not for the placeholder.)
  static func post() -> Never {
    let input = FileHandle.standardInput.readDataToEndOfFile()
    guard let obj = try? JSONSerialization.jsonObject(with: input) as? [String: Any], obj["tool_name"] as? String == "Bash",
          let command = (obj["tool_input"] as? [String: Any])?["command"] as? String else { exit(0) }
    let resp = obj["tool_response"]
    let text = ((resp as? [String: Any]).map { "\($0["stdout"] ?? "") \($0["stderr"] ?? "")" } ?? "\(resp ?? "")")
    guard let msg = postAdvice(output: text, command: command, cwd: obj["cwd"] as? String) else { exit(0) }
    let out: [String: Any] = ["hookSpecificOutput": ["hookEventName": "PostToolUse", "additionalContext": msg]]
    FileHandle.standardOutput.write((try? JSONSerialization.data(withJSONObject: out)) ?? Data())
    exit(0)
  }

  static let authFailures = ["401 unauthorized", "status code 401", "status: 401", "error 401", "http 401", " 401 ", "unauthorized",
                             "invalid api key", "invalid_api_key", "incorrect api key", "invalid x-api-key", "authentication_error",
                             "authenticationerror", "api key not valid", "api key is invalid", "invalid authentication", "invalid token", "invalid_request_error: invalid api"]

  static func postAdvice(output: String, command: String, cwd: String?) -> String? {
    guard runsProgram(command), !usesKd(command), keydilloProject(command: command, cwd: cwd) != nil else { return nil }
    let lower = " " + output.lowercased() + " "
    guard authFailures.contains(where: { lower.contains($0) }) else { return nil }
    return "keydillo: this ran without `kd` in a keydillo project, so the API got a placeholder instead of the key. Rerun it as `kd \(command.trimmingCharacters(in: .whitespaces))`. If it still fails, the program skips keydillo (Go, Docker, pinned certificates): call the API through its keydillo base URL from list_services. Don't look for the real key."
  }

  // MARK: Deciding when a command needs kd

  /// Programs that run a project's code (and so may read its .env and call APIs).
  static let runners: Set<String> = ["python", "python3", "node", "bun", "deno", "tsx", "ts-node", "pytest", "uvicorn", "gunicorn",
                                     "flask", "django-admin", "ruby", "rails", "rake", "php", "next", "vite", "nodemon", "jest", "vitest",
                                     "mocha", "playwright", "expo", "wrangler"]
  /// Package managers count only when they run something (not install).
  static let runVerbs: Set<String> = ["run", "start", "dev", "test", "exec", "x", "serve", "preview"]

  static func segments(_ command: String) -> [[String]] {
    command.components(separatedBy: CharacterSet(charactersIn: ";|&\n")).map {
      $0.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init).filter { !$0.contains("=") || $0.hasPrefix("-") }
    }.filter { !$0.isEmpty }
  }

  static func usesKd(_ command: String) -> Bool {
    segments(command).contains { $0.first == "kd" || ($0.first == "keydillo" && $0.dropFirst().first == "run") }
  }

  static func runsProgram(_ command: String) -> Bool {
    for seg in segments(command) {
      guard let first = seg.first.map({ ($0 as NSString).lastPathComponent }) else { continue }
      if runners.contains(first) || first.hasPrefix("python3.") { return true }
      if ["npm", "pnpm", "yarn", "npx", "bunx", "uv", "poetry", "pipenv", "go", "cargo"].contains(first) {
        if first == "npx" || first == "bunx" { return true }
        if let verb = seg.dropFirst().first, runVerbs.contains(verb) { return true }
        if first == "yarn", let verb = seg.dropFirst().first, !["install", "add", "remove", "upgrade", "init"].contains(verb) { return true }
      }
      if first.hasPrefix("./") && !first.hasSuffix(".sh") { return true }
    }
    return false
  }

  /// The keydillo project (folder whose .env has keydillo's header) the command runs in or points into.
  static func keydilloProject(command: String, cwd: String?) -> String? {
    func marked(_ dir: String) -> String? {
      var d = dir
      while !d.isEmpty && d != "/" {
        if let text = try? String(contentsOfFile: d + "/.env", encoding: .utf8), text.contains(ImportScanner.headerStart) { return d }
        d = (d as NSString).deletingLastPathComponent
      }
      return nil
    }
    if let cwd, let p = marked(cwd) { return p }
    for seg in segments(command) {
      for w in seg where w.contains("/") {
        var path = w.hasPrefix("~") ? NSHomeDirectory() + w.dropFirst() : w
        if !path.hasPrefix("/"), let cwd { path = cwd + "/" + path }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { continue }
        if let p = marked(isDir.boolValue ? path : (path as NSString).deletingLastPathComponent) { return p }
      }
    }
    return nil
  }

  /// Before a command runs: a program run in a keydillo project without `kd` would send placeholders unswapped.
  static func needsKd(_ command: String, cwd: String?) -> String? {
    guard runsProgram(command), !usesKd(command), let project = keydilloProject(command: command, cwd: cwd) else { return nil }
    return "\((project as NSString).lastPathComponent) uses keydillo placeholders for its API keys. Put `kd` in front so they're swapped for the real keys: `kd \(command.trimmingCharacters(in: .whitespaces))`. (For a command that doesn't call any API, that's harmless too.)"
  }

  static func verdict(_ text: String, tool: String, services: [ServiceSummary], cwd: String?) -> String? {
    let lower = text.lowercased()
    let viaRun = lower.contains("keydillo run") || usesKd(text)
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
      return "\(s.host) is called through keydillo here. Use \(addrs) in place of https://\(s.host), with no key header; keydillo adds the key after the user approves. Or put `kd` in front of the command (e.g. `kd \(tool == "Bash" ? "python script.py" : "curl …")`). Don't look for the real key."
    }
    if let name = Placeholder.service(in: text), let s = services.first(where: { $0.name == name }) {
      return "keydillo:\(name) is a placeholder, not a key. Call \(s.baseURL) instead (no key needed), or put `kd` in front of the command."
    }
    return nil
  }
}
