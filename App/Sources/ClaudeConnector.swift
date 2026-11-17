import Foundation

/// Hooks keydillo into Claude Code: registers the MCP server, adds a skill, and blocks reading .env files.
enum ClaudeConnector {
  static let changes = [
    "Adds keydillo as a tool Claude can use (it can list your services and ask you for a key, never read one).",
    "Adds a short skill telling Claude to use keydillo instead of asking for keys in chat.",
    "Adds a check that stops Claude calling an API directly when keydillo holds its key, and points it to the keydillo address.",
  ]

  static var cliPath: String {
    Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bin/keydillo").path
  }

  static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

  /// True when the keydillo Claude Code plugin is installed (`/plugin install keydillo@keydillo`).
  static var pluginInstalled: Bool {
    guard let data = try? Data(contentsOf: home.appendingPathComponent(".claude/plugins/installed_plugins.json")),
          let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let plugins = root["plugins"] as? [String: Any] else { return false }
    return plugins.keys.contains { $0.hasPrefix("keydillo@") }
  }

  /// Returns an error message, or nil on success.
  static func connect() async -> String? {
    if pluginInstalled { disconnect(); return nil }   // the plugin already brings the skill, tools and hook
    do {
      try registerMCP()
      try writeSkill()
      try installHook()
      return nil
    } catch {
      return error.localizedDescription
    }
  }

  static func registerMCP() throws {
    // Use the user's login shell so `claude` is found on their PATH.
    let cmd = "claude mcp remove --scope user keydillo >/dev/null 2>&1; claude mcp add --scope user keydillo -- '\(cliPath)' mcp"
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-lc", cmd]
    let err = Pipe(); p.standardError = err; p.standardOutput = Pipe()
    try p.run(); p.waitUntilExit()
    if p.terminationStatus != 0 {
      let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
      throw NSError(domain: "keydillo", code: 1, userInfo: [NSLocalizedDescriptionKey:
        msg.contains("not found") ? "Couldn't find Claude Code. Install it, then try Connect again from Settings." : "Couldn't add keydillo to Claude Code: \(msg)"])
    }
  }

  static var skillURL: URL { home.appendingPathComponent(".claude/skills/keydillo/SKILL.md") }

  /// Keeps an installed skill current with this version of keydillo.
  static func refreshSkillIfInstalled() {
    if pluginInstalled {   // avoid running two copies of the skill, tools and hook
      if FileManager.default.fileExists(atPath: skillURL.path) { disconnect() }
      return
    }
    guard let current = try? String(contentsOf: skillURL, encoding: .utf8) else { return }
    if current != skill { try? skill.write(to: skillURL, atomically: true, encoding: .utf8) }
    try? installHook()   // connected users get the hook and newer settings too
  }

  static var hookCommand: String { "'\(cliPath)' hook" }

  /// Adds (or updates) keydillo's PreToolUse hook in ~/.claude/settings.json, keeping everything else.
  static func installHook() throws {
    let url = home.appendingPathComponent(".claude/settings.json")
    var root: [String: Any] = [:]
    if let d = try? Data(contentsOf: url) {
      guard let obj = try JSONSerialization.jsonObject(with: d) as? [String: Any] else {
        throw NSError(domain: "keydillo", code: 2, userInfo: [NSLocalizedDescriptionKey: "~/.claude/settings.json isn't valid JSON, so it was left alone."])
      }
      root = obj
      try? d.write(to: url.appendingPathExtension("keydillo-backup"))
    }
    var hooks = root["hooks"] as? [String: Any] ?? [:]
    var pre = (hooks["PreToolUse"] as? [[String: Any]] ?? []).filter { entry in
      !((entry["hooks"] as? [[String: Any]]) ?? []).contains { ($0["command"] as? String)?.contains("keydillo") == true && ($0["command"] as? String)?.hasSuffix(" hook") == true }
    }
    pre.append(["matcher": "Bash|WebFetch", "hooks": [["type": "command", "command": hookCommand, "timeout": 5]]])
    hooks["PreToolUse"] = pre
    root["hooks"] = hooks
    // Never touch the user's own permission rules.
    let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try out.write(to: url, options: .atomic)
  }

  static func removeHook() {
    let url = home.appendingPathComponent(".claude/settings.json")
    guard let d = try? Data(contentsOf: url), var root = try? JSONSerialization.jsonObject(with: d) as? [String: Any],
          var hooks = root["hooks"] as? [String: Any], let pre = hooks["PreToolUse"] as? [[String: Any]] else { return }
    hooks["PreToolUse"] = pre.filter { entry in
      !((entry["hooks"] as? [[String: Any]]) ?? []).contains { ($0["command"] as? String)?.hasSuffix(" hook") == true && ($0["command"] as? String)?.contains("keydillo") == true }
    }
    root["hooks"] = hooks
    if let out = try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]) { try? out.write(to: url, options: .atomic) }
  }

  static func disconnect() {
    removeHook()
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-lc", "claude mcp remove --scope user keydillo >/dev/null 2>&1"]
    try? p.run(); p.waitUntilExit()
    try? FileManager.default.removeItem(at: skillURL.deletingLastPathComponent())
  }

  static func writeSkill() throws {
    let dir = home.appendingPathComponent(".claude/skills/keydillo", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    try skill.write(to: dir.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
  }

  static func addDenyRules() throws {
    let url = home.appendingPathComponent(".claude/settings.json")
    var root: [String: Any] = [:]
    if let d = try? Data(contentsOf: url) {
      guard let obj = try JSONSerialization.jsonObject(with: d) as? [String: Any] else {
        throw NSError(domain: "keydillo", code: 2, userInfo: [NSLocalizedDescriptionKey: "~/.claude/settings.json isn't valid JSON, so it was left alone."])
      }
      root = obj
      try? d.write(to: url.appendingPathExtension("keydillo-backup"))
    }
    var perms = root["permissions"] as? [String: Any] ?? [:]
    var deny = perms["deny"] as? [String] ?? []
    for rule in ["Read(**/.env)", "Read(**/.env.*)"] where !deny.contains(rule) { deny.append(rule) }
    perms["deny"] = deny
    root["permissions"] = perms
    let out = try JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try out.write(to: url, options: .atomic)
  }

  static let skill = """
  ---
  name: keydillo
  description: Use whenever code needs an API key or secret (OpenAI, Anthropic, ElevenLabs, Stripe, Supabase, etc.), when a .env file needs a key, or when the user offers to paste a key. keydillo keeps keys on the user's Mac and lets you call APIs through a local proxy without ever seeing the value.
  ---

  # Using API keys with keydillo

  Never ask the user to paste an API key into the chat, and never read, print or log a key value.

  `.env` values that start with `keydillo:` are placeholders, not keys. Don't ask the user for the "real" key and don't call the provider with a placeholder: call the matching `*_BASE_URL` (http://localhost:7787/<name>/...) with no key, or run the command with `keydillo run -- <command>`.

  0. Call the keydillo `status` tool whenever something keydillo-related fails.
  1. Call the keydillo `list_services` tool to see which services are already set up.
  2. Several keys can exist for one service (e.g. `openai` for one project, `openai-notes-app` for another). Use the one whose project matches the folder you're working in; `list_services` shows each key's project. If none matches, request a new one rather than borrowing another project's key.
  3. If the service is missing, call `request_secret` with the service name, the API's real host and the header that carries the key (plus `prefix: "Bearer "` for Authorization headers, and `key_page_url`: the provider's page where keys are created). A window opens on the user's Mac; wait for it.
  4. Call the API through the local base URL keydillo returns, e.g. `http://localhost:7787/elevenlabs/v1/...`. keydillo adds the key and the user approves with Touch ID.
  5. In code, read the base URL from an env var such as `ELEVENLABS_BASE_URL` and fall back to the real host when it's unset, so production works with a real key set in the host's settings.
  6. In local `.env` files, write only the lines keydillo returns (a base URL and a `keydillo:<name>` placeholder), never a real key. Apps that read the key directly can be started with `keydillo run -- <command>`.

  ## When keydillo says no

  keydillo errors are JSON with `error`, `code` and `hint`. Follow the hint:
  - `denied`: the user declined. Stop and tell them; don't retry unless they ask.
  - `approval_unavailable`: the Mac is locked or the user is away. Tell the user it's waiting for them.
  - `unknown_service`: no key stored yet. Call `request_secret`.
  - `path_not_allowed` / `rate_limited`: tell the user what you need; they can change it in keydillo.
  - Connection refused on the keydillo port: keydillo is restarting or not running. Wait a few seconds and retry once, then call `status` and tell the user.

  If you see `[redacted by keydillo: ... key]`, a key value was hidden from you on purpose. Never try to recover it.
  Never work around a keydillo block: don't look for the key in files, the Keychain, shell history or environment variables, and don't call the provider directly with a key from anywhere else. Keeping keys safe matters more than finishing the task; ask the user instead.
  """
}
