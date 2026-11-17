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
    if tool == "Bash", !keydilloQuit, let msg = needsKd(text, cwd: obj["cwd"] as? String) {
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

  static let certFailures = ["x509", "certificate is not trusted", "certificate verify failed", "unknown authority",
                              "self signed certificate", "self-signed certificate", "tsi_protocol_failure", "handshake failed"]

  /// The user quit keydillo from its menu: keys aren't available until they open it again.
  static var keydilloQuit: Bool {
    FileManager.default.fileExists(atPath: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("keydillo/quit-by-user").path)
  }

  static func postAdvice(output: String, command: String, cwd: String?) -> String? {
    let found = programs(command, cwd: cwd)
    guard !found.isEmpty else { return nil }
    let lower = " " + output.lowercased() + " "
    let authFailed = authFailures.contains(where: { lower.contains($0) })
    if keydilloQuit && (authFailed || lower.contains("keydillo was quit")) {
      return "keydillo: the user quit keydillo, so this project's keys aren't available. Ask them to open keydillo, then rerun with kd."
    }
    if found.contains(where: { nativeRunner($0.seg) }) && (authFailed || certFailures.contains(where: { lower.contains($0) })) {
      return "keydillo: " + baseURLAdvice
    }
    if usesKd(command) {
      guard certFailures.contains(where: { lower.contains($0) }) else { return nil }
      return "keydillo: " + baseURLAdvice
    }
    guard authFailed else { return nil }
    return "keydillo: rerun with kd: `kd \(command.trimmingCharacters(in: .whitespaces))`. No need to mention it."
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

  /// Languages whose programs ignore kd's certificate; for these the fix is the base URL, not kd.
  static func nativeRunner(_ seg: [String]) -> Bool {
    guard let first = seg.first.map({ ($0 as NSString).lastPathComponent }) else { return false }
    return (first == "go" || first == "cargo") && ["run", "test"].contains(seg.dropFirst().first ?? "")
  }

  static func isProgram(_ seg: [String]) -> Bool {
    guard let first = seg.first.map({ ($0 as NSString).lastPathComponent }) else { return false }
    if runners.contains(first) || first.hasPrefix("python3.") { return true }
    if first == "npx" || first == "bunx" { return true }
    if ["npm", "pnpm", "yarn", "uv", "poetry", "pipenv", "go", "cargo"].contains(first) {
      if let verb = seg.dropFirst().first, runVerbs.contains(verb) { return true }
      if first == "yarn", let verb = seg.dropFirst().first, !["install", "add", "remove", "upgrade", "init"].contains(verb) { return true }
    }
    let raw = seg[0]
    return raw.hasPrefix("./") && !raw.hasSuffix(".sh")
  }

  static func runsProgram(_ command: String) -> Bool { segments(command).contains(where: isProgram) }

  /// The folder (and its parents) holds an env file keydillo has rewritten: .env, .env.local, .env.development, .dev.vars …
  static func marked(_ dir: String) -> String? {
    var d = dir
    while !d.isEmpty && d != "/" {
      let names = (try? FileManager.default.contentsOfDirectory(atPath: d)) ?? []
      for n in names where ImportScanner.isEnvFile(n) {
        if let text = try? String(contentsOfFile: d + "/" + n, encoding: .utf8), text.contains(ImportScanner.headerStart) { return d }
      }
      d = (d as NSString).deletingLastPathComponent
    }
    return nil
  }

  static func resolve(_ w: String, from cwd: String?) -> String {
    var path = w.hasPrefix("~") ? NSHomeDirectory() + w.dropFirst() : w
    if !path.hasPrefix("/"), let cwd { path = cwd + "/" + path }
    return (path as NSString).standardizingPath
  }

  /// Each program the command runs, with the folder it runs in (following `cd`) and the keydillo project it's in
  /// or points into, if any.
  static func programs(_ command: String, cwd: String?) -> [(seg: [String], project: String)] {
    var here = cwd
    var out: [(seg: [String], project: String)] = []
    for raw in segments(command) {
      var seg = raw
      if seg.first == "kd" { seg.removeFirst() }
      if seg.first == "keydillo" && seg.dropFirst().first == "run" { seg.removeFirst(2); if seg.first == "--" { seg.removeFirst() } }
      if seg.first == "cd" || seg.first == "pushd" {
        here = seg.count > 1 ? resolve(seg[1], from: here) : NSHomeDirectory(); continue
      }
      guard isProgram(seg) else { continue }
      if let h = here, let p = marked(h) { out.append((seg, p)); continue }
      for w in seg where w.contains("/") {
        let path = resolve(w, from: here)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { continue }
        if let p = marked(isDir.boolValue ? path : (path as NSString).deletingLastPathComponent) { out.append((seg, p)); break }
      }
    }
    return out
  }

  static func keydilloProject(command: String, cwd: String?) -> String? { programs(command, cwd: cwd).first?.project }

  static let baseURLAdvice = "This program doesn't go through kd (Go, Rust, gRPC or pinned certificates). Point it at the key's *_BASE_URL from list_services instead, with no key. Don't mention this to the user unless it keeps failing."

  /// Before a command runs: a program run in a keydillo project without `kd` would send placeholders unswapped.
  static func needsKd(_ command: String, cwd: String?) -> String? {
    guard !usesKd(command) else { return nil }
    let found = programs(command, cwd: cwd)
    guard let first = found.first(where: { !nativeRunner($0.seg) }) else { return nil }
    let project = first.project
    return "Rerun as `kd \(command.trimmingCharacters(in: .whitespaces))` (this project's keys need kd). Just rerun it; no need to mention this to the user."
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
      return "Use \(addrs) instead of https://\(s.host), with no key header, or put `kd` in front of the command. Just do it; no need to mention it."
    }
    if let name = Placeholder.service(in: text), let s = services.first(where: { $0.name == name }) {
      return "Call \(s.baseURL) instead (no key needed), or put `kd` in front of the command. Just do it; no need to mention it."
    }
    return nil
  }
}
