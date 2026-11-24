import Foundation

/// Connect for Cursor and Codex: the same three pieces as Claude Code (keydillo's tools, the skill, and the check
/// before each command that puts `kd` in front), written into each tool's own settings. Everything else in those
/// files is kept, and each file is backed up next to itself before the first change.
protocol AgentConnector {
  static var name: String { get }
  /// The tool is on this Mac (so Connect is offered for it).
  static var installed: Bool { get }
  static var status: ClaudeConnector.Status { get }
  static var changes: [String] { get }
  /// Shown after a successful Connect, when the tool needs one more step from the user.
  static var afterConnect: String? { get }
  static func connect() throws
  static func disconnect()
}

extension AgentConnector {
  static var cliPath: String { ClaudeConnector.cliPath }
  static var home: URL { ClaudeConnector.home }
  static var afterConnect: String? { nil }

  /// Connect, refusing a temporary copy of the app (Claude Code's rule too). Returns an error message, or nil.
  static func connectChecked() -> String? {
    if ShellIntegration.isTranslocated { return "Move keydillo to your Applications folder, open it from there, then choose Connect." }
    do { try connect(); return nil } catch { return error.localizedDescription }
  }

  /// Keeps a connected tool current with this copy of keydillo (skill text, paths).
  static func refreshIfConnected() {
    guard !ShellIntegration.isTranslocated, status != .notConnected else { return }
    try? connect()
  }
}

enum AgentFiles {
  static func readJSON(_ url: URL) throws -> [String: Any] {
    guard let d = try? Data(contentsOf: url) else { return [:] }
    guard let obj = try JSONSerialization.jsonObject(with: d) as? [String: Any] else {
      throw NSError(domain: "keydillo", code: 2, userInfo: [NSLocalizedDescriptionKey:
        "\(url.path.replacingOccurrences(of: NSHomeDirectory(), with: "~")) isn't valid JSON, so it was left alone."])
    }
    backUp(url, d)
    return obj
  }

  /// One backup per file, made before keydillo first changes it.
  static func backUp(_ url: URL, _ data: Data) {
    let b = url.appendingPathExtension("keydillo-backup")
    if !FileManager.default.fileExists(atPath: b.path) { try? data.write(to: b) }
  }

  static func writeJSON(_ root: [String: Any], to url: URL) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try out.write(to: url, options: .atomic)
  }

  static func writeSkill(to dir: URL) throws {
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let file = dir.appendingPathComponent("SKILL.md")
    if (try? String(contentsOf: file, encoding: .utf8)) != ClaudeConnector.skill {
      try ClaudeConnector.skill.write(to: file, atomically: true, encoding: .utf8)
    }
  }

  /// Runs keydillo only while the app is installed, so removing keydillo never leaves a failing hook behind.
  static func guarded(_ args: String) -> String {
    "if [ -x '\(ClaudeConnector.cliPath)' ]; then exec '\(ClaudeConnector.cliPath)' \(args); fi"
  }

  static func isOurs(_ command: String?) -> Bool {
    guard let c = command else { return false }
    return c.contains("/keydillo' hook") || c.contains("/keydillo hook")
  }
}

// MARK: - Cursor

enum CursorConnector: AgentConnector {
  static let name = "Cursor"
  static let changes = [
    "Adds keydillo as a tool Cursor's agent can use (it can list your services and ask you for a key, never read one).",
    "Adds the keydillo skill to Cursor, telling the agent to use keydillo instead of asking for keys in chat.",
    "Adds a check before the agent runs a command, so programs in your keydillo projects start with kd.",
  ]

  static var dir: URL { home.appendingPathComponent(".cursor", isDirectory: true) }
  static var mcpURL: URL { dir.appendingPathComponent("mcp.json") }
  static var hooksURL: URL { dir.appendingPathComponent("hooks.json") }
  static var skillDir: URL { dir.appendingPathComponent("skills/keydillo", isDirectory: true) }
  static let hookEvent = "beforeShellExecution"
  static var hookCommand: String { AgentFiles.guarded("hook cursor") }

  static var installed: Bool {
    FileManager.default.fileExists(atPath: "/Applications/Cursor.app") || FileManager.default.fileExists(atPath: dir.path)
  }

  static var status: ClaudeConnector.Status {
    let mcp = ((try? AgentFiles.readJSONQuiet(mcpURL))?["mcpServers"] as? [String: Any])?["keydillo"] as? [String: Any]
    let hooks = (((try? AgentFiles.readJSONQuiet(hooksURL))?["hooks"] as? [String: Any])?[hookEvent] as? [[String: Any]]) ?? []
    let ours = hooks.compactMap { $0["command"] as? String }.filter(AgentFiles.isOurs)
    if mcp == nil && ours.isEmpty { return .notConnected }
    let fine = mcp?["command"] as? String == cliPath && ours.count == 1 && ours[0] == hookCommand
      && FileManager.default.fileExists(atPath: skillDir.appendingPathComponent("SKILL.md").path)
    return fine ? .connected : .needsReconnecting
  }

  static func connect() throws {
    var mcp = try AgentFiles.readJSON(mcpURL)
    var servers = mcp["mcpServers"] as? [String: Any] ?? [:]
    servers["keydillo"] = ["command": cliPath, "args": ["mcp"]]
    mcp["mcpServers"] = servers
    try AgentFiles.writeJSON(mcp, to: mcpURL)

    var root = try AgentFiles.readJSON(hooksURL)
    var hooks = root["hooks"] as? [String: Any] ?? [:]
    var list = (hooks[hookEvent] as? [[String: Any]] ?? []).filter { !AgentFiles.isOurs($0["command"] as? String) }
    list.append(["command": hookCommand, "timeout": 10])
    hooks[hookEvent] = list
    root["hooks"] = hooks
    if root["version"] == nil { root["version"] = 1 }
    try AgentFiles.writeJSON(root, to: hooksURL)

    try AgentFiles.writeSkill(to: skillDir)
  }

  static func disconnect() {
    if var mcp = try? AgentFiles.readJSONQuiet(mcpURL), var servers = mcp["mcpServers"] as? [String: Any], servers["keydillo"] != nil {
      servers["keydillo"] = nil; mcp["mcpServers"] = servers
      try? AgentFiles.writeJSON(mcp, to: mcpURL)
    }
    if var root = try? AgentFiles.readJSONQuiet(hooksURL), var hooks = root["hooks"] as? [String: Any],
       let list = hooks[hookEvent] as? [[String: Any]] {
      let kept = list.filter { !AgentFiles.isOurs($0["command"] as? String) }
      hooks[hookEvent] = kept.isEmpty ? nil : kept
      root["hooks"] = hooks
      try? AgentFiles.writeJSON(root, to: hooksURL)
    }
    try? FileManager.default.removeItem(at: skillDir)
  }
}

// MARK: - Codex

enum CodexConnector: AgentConnector {
  static let name = "Codex"
  static let changes = [
    "Adds keydillo as a tool Codex can use (it can list your services and ask you for a key, never read one).",
    "Adds the keydillo skill for Codex, telling it to use keydillo instead of asking for keys in chat.",
    "Adds a check before Codex runs a command, so programs in your keydillo projects start with kd.",
  ]
  static let afterConnect: String? = "Codex asks you to review new checks once: type /hooks in Codex and trust keydillo's."

  static var dir: URL {
    ProcessInfo.processInfo.environment["CODEX_HOME"].map { URL(fileURLWithPath: $0, isDirectory: true) }
      ?? home.appendingPathComponent(".codex", isDirectory: true)
  }
  static var configURL: URL { dir.appendingPathComponent("config.toml") }
  static var hooksURL: URL { dir.appendingPathComponent("hooks.json") }
  /// Codex reads user skills from ~/.agents/skills (the folder `npx skills add -g` also uses).
  static var skillDir: URL { home.appendingPathComponent(".agents/skills/keydillo", isDirectory: true) }

  /// Same events and format as Claude Code's hooks.
  static var hookEntries: [(event: String, matcher: String, command: String)] {
    [("PreToolUse", "Bash", AgentFiles.guarded("hook")), ("PostToolUse", "Bash", AgentFiles.guarded("hook post"))]
  }

  static var installed: Bool {
    FileManager.default.fileExists(atPath: dir.path) || FileManager.default.fileExists(atPath: "/Applications/Codex.app")
  }

  static var status: ClaudeConnector.Status {
    let config = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
    let hasServer = config.components(separatedBy: "\n").contains { isOurHeader($0) }
    let hooks = ((try? AgentFiles.readJSONQuiet(hooksURL))?["hooks"] as? [String: Any]) ?? [:]
    let ours = hookEntries.flatMap { e in
      ((hooks[e.event] as? [[String: Any]]) ?? []).flatMap { ($0["hooks"] as? [[String: Any]] ?? []).compactMap { $0["command"] as? String } }
        .filter(AgentFiles.isOurs)
    }
    if !hasServer && ours.isEmpty { return .notConnected }
    let fine = config.contains(serverBlock) && Set(ours) == Set(hookEntries.map(\.command)) && ours.count == hookEntries.count
      && FileManager.default.fileExists(atPath: skillDir.appendingPathComponent("SKILL.md").path)
    return fine ? .connected : .needsReconnecting
  }

  static var serverBlock: String {
    "[mcp_servers.keydillo]\ncommand = \"\(cliPath)\"\nargs = [\"mcp\"]\n"
  }

  static func isOurHeader(_ line: String) -> Bool {
    let t = line.trimmingCharacters(in: .whitespaces)
    return t == "[mcp_servers.keydillo]" || t.hasPrefix("[mcp_servers.keydillo.") || t == "[mcp_servers.\"keydillo\"]"
  }

  /// config.toml without keydillo's server tables (each runs from its header to the next table header).
  static func withoutServer(_ text: String) -> String {
    var out: [String] = []
    var skipping = false
    for line in text.components(separatedBy: "\n") {
      let t = line.trimmingCharacters(in: .whitespaces)
      if t.hasPrefix("[") { skipping = isOurHeader(line) }
      if !skipping { out.append(line) }
    }
    while out.last == "" { out.removeLast() }
    return out.joined(separator: "\n")
  }

  static func connect() throws {
    let old = (try? String(contentsOf: configURL, encoding: .utf8)) ?? ""
    if !old.contains(serverBlock) {
      AgentFiles.backUp(configURL, Data(old.utf8))
      let kept = withoutServer(old)
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      try ((kept.isEmpty ? "" : kept + "\n\n") + serverBlock).write(to: configURL, atomically: true, encoding: .utf8)
    }

    var root = try AgentFiles.readJSON(hooksURL)
    var hooks = root["hooks"] as? [String: Any] ?? [:]
    for e in hookEntries {
      var list = (hooks[e.event] as? [[String: Any]] ?? []).filter { !containsOurs($0) }
      list.append(["matcher": e.matcher, "hooks": [["type": "command", "command": e.command, "timeout": 10]]])
      hooks[e.event] = list
    }
    root["hooks"] = hooks
    try AgentFiles.writeJSON(root, to: hooksURL)

    try AgentFiles.writeSkill(to: skillDir)
  }

  static func containsOurs(_ group: [String: Any]) -> Bool {
    (group["hooks"] as? [[String: Any]] ?? []).contains { AgentFiles.isOurs($0["command"] as? String) }
  }

  static func disconnect() {
    if let old = try? String(contentsOf: configURL, encoding: .utf8), old.components(separatedBy: "\n").contains(where: isOurHeader) {
      try? (withoutServer(old) + "\n").write(to: configURL, atomically: true, encoding: .utf8)
    }
    if var root = try? AgentFiles.readJSONQuiet(hooksURL), var hooks = root["hooks"] as? [String: Any] {
      for e in hookEntries {
        if let list = hooks[e.event] as? [[String: Any]] { let kept = list.filter { !containsOurs($0) }; hooks[e.event] = kept.isEmpty ? nil : kept }
      }
      root["hooks"] = hooks
      try? AgentFiles.writeJSON(root, to: hooksURL)
    }
    // Only remove the skill if it's keydillo's own copy (another tool may have put a different one there).
    if (try? String(contentsOf: skillDir.appendingPathComponent("SKILL.md"), encoding: .utf8))?.contains("name: keydillo") == true {
      try? FileManager.default.removeItem(at: skillDir)
    }
  }
}

extension AgentFiles {
  /// Reads without making a backup (for status checks and removal).
  static func readJSONQuiet(_ url: URL) throws -> [String: Any] {
    guard let d = try? Data(contentsOf: url) else { return [:] }
    return try JSONSerialization.jsonObject(with: d) as? [String: Any] ?? [:]
  }
}

/// Every AI tool Connect can set up, for the setup step, Settings and the menu.
enum AgentTools {
  static let changes = [
    "Adds keydillo as a tool your AI tools can use (they can list your services and ask you for a key, never read one).",
    "Adds a short skill telling them to use keydillo instead of asking for keys in chat.",
    "Adds a check before each command they run, so programs in your keydillo projects start with kd and API calls go through keydillo.",
  ]

  struct Tool: Identifiable {
    let name: String
    let installed: Bool
    let status: ClaudeConnector.Status
    let changes: [String]
    let afterConnect: String?
    let connect: () async -> String?
    var id: String { name }
  }

  static var all: [Tool] {
    [Tool(name: "Claude Code", installed: true, status: ClaudeConnector.status, changes: ClaudeConnector.changes, afterConnect: nil,
          connect: { await ClaudeConnector.connect() }),
     tool(CursorConnector.self), tool(CodexConnector.self)]
  }

  static func tool<C: AgentConnector>(_ c: C.Type) -> Tool {
    Tool(name: c.name, installed: c.installed, status: c.status, changes: c.changes, afterConnect: c.afterConnect,
         connect: { await Task.detached { c.connectChecked() }.value })
  }

  static func refresh() {
    CursorConnector.refreshIfConnected()
    CodexConnector.refreshIfConnected()
  }

  static func disconnectAll() {
    ClaudeConnector.disconnect()
    CursorConnector.disconnect()
    CodexConnector.disconnect()
  }
}
