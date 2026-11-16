import Foundation

/// Hooks keydillo into Claude Code: registers the MCP server, adds a skill, and blocks reading .env files.
enum ClaudeConnector {
  static let changes = [
    "Adds keydillo as a tool Claude can use (it can list your services and ask you for a key, never read one).",
    "Adds a short skill telling Claude to use keydillo instead of asking for keys in chat.",
  ]

  static var cliPath: String {
    Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/bin/keydillo").path
  }

  static var home: URL { FileManager.default.homeDirectoryForCurrentUser }

  /// Returns an error message, or nil on success.
  static func connect() async -> String? {
    do {
      try registerMCP()
      try writeSkill()
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

  0. Call the keydillo `status` tool whenever something keydillo-related fails.
  1. Call the keydillo `list_services` tool to see which services are already set up.
  2. If the service is missing, call `request_secret` with the service name, the API's real host and the header that carries the key (plus `prefix: "Bearer "` for Authorization headers, and `key_page_url`: the provider's page where keys are created). A window opens on the user's Mac; wait for it.
  3. Call the API through the local base URL keydillo returns, e.g. `http://localhost:7787/elevenlabs/v1/...`. keydillo adds the key and the user approves with Touch ID.
  4. In code, read the base URL from an env var such as `ELEVENLABS_BASE_URL` and fall back to the real host when it's unset, so production works with a real key set in the host's settings.
  5. In local `.env` files, write only the lines keydillo returns (a base URL and a `keydillo:<name>` placeholder), never a real key. Apps that read the key directly can be started with `keydillo run -- <command>`.

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
