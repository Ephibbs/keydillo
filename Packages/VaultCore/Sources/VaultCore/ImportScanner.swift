import Foundation

/// Finds API keys in .env files so they can be moved into keydillo.
public enum ImportScanner {
  public struct Known {
    public let service: String
    public let displayName: String
    public let host: String
    public let header: String
    public let prefix: String
    public let keyPage: String?
    /// What the provider's SDK appends after the host, and the env var it reads a base URL from.
    public var sdkBasePath: String? = nil
    public var baseURLEnv: String? = nil
  }

  /// SDK conventions for base URLs, by service.
  public static let sdkConventions: [String: (path: String, env: String?)] = [
    "openai": ("/v1", "OPENAI_BASE_URL"), "anthropic": ("", "ANTHROPIC_BASE_URL"), "elevenlabs": ("", "ELEVENLABS_BASE_URL"),
    "groq": ("/openai/v1", "GROQ_BASE_URL"), "mistral": ("/v1", "MISTRAL_BASE_URL"), "replicate": ("/v1", "REPLICATE_API_BASE_URL"),
    "perplexity": ("", "PERPLEXITY_BASE_URL"), "deepgram": ("", "DEEPGRAM_BASE_URL"), "gemini": ("", "GOOGLE_GEMINI_BASE_URL"),
    "resend": ("", "RESEND_BASE_URL"), "stripe": ("", nil), "revenuecat": ("", nil), "posthog": ("", "POSTHOG_HOST"), "cohere": ("", "CO_API_URL"),
  ]
  public static func convention(for service: String) -> (path: String, env: String?)? {
    let base = service.split(separator: "-").first.map(String.init) ?? service
    return sdkConventions[base]
  }

  /// Services we can set up without asking: matched by env var name.
  public static let known: [(match: String, Known)] = [
    ("ANTHROPIC", Known(service: "anthropic", displayName: "Anthropic", host: "api.anthropic.com", header: "x-api-key", prefix: "", keyPage: "https://console.anthropic.com/settings/keys")),
    ("OPENAI", Known(service: "openai", displayName: "OpenAI", host: "api.openai.com", header: "Authorization", prefix: "Bearer ", keyPage: "https://platform.openai.com/api-keys")),
    ("ELEVENLABS", Known(service: "elevenlabs", displayName: "ElevenLabs", host: "api.elevenlabs.io", header: "xi-api-key", prefix: "", keyPage: "https://elevenlabs.io/app/settings/api-keys")),
    ("XI_API", Known(service: "elevenlabs", displayName: "ElevenLabs", host: "api.elevenlabs.io", header: "xi-api-key", prefix: "", keyPage: "https://elevenlabs.io/app/settings/api-keys")),
    ("STRIPE_SECRET", Known(service: "stripe", displayName: "Stripe", host: "api.stripe.com", header: "Authorization", prefix: "Bearer ", keyPage: "https://dashboard.stripe.com/apikeys")),
    ("RESEND", Known(service: "resend", displayName: "Resend", host: "api.resend.com", header: "Authorization", prefix: "Bearer ", keyPage: "https://resend.com/api-keys")),
    ("GROQ", Known(service: "groq", displayName: "Groq", host: "api.groq.com", header: "Authorization", prefix: "Bearer ", keyPage: "https://console.groq.com/keys")),
    ("MISTRAL", Known(service: "mistral", displayName: "Mistral", host: "api.mistral.ai", header: "Authorization", prefix: "Bearer ", keyPage: "https://console.mistral.ai/api-keys")),
    ("REPLICATE", Known(service: "replicate", displayName: "Replicate", host: "api.replicate.com", header: "Authorization", prefix: "Bearer ", keyPage: "https://replicate.com/account/api-tokens")),
    ("DEEPGRAM", Known(service: "deepgram", displayName: "Deepgram", host: "api.deepgram.com", header: "Authorization", prefix: "Token ", keyPage: "https://console.deepgram.com")),
    ("GEMINI", Known(service: "gemini", displayName: "Gemini", host: "generativelanguage.googleapis.com", header: "x-goog-api-key", prefix: "", keyPage: "https://aistudio.google.com/apikey")),
    ("GOOGLE_AI", Known(service: "gemini", displayName: "Gemini", host: "generativelanguage.googleapis.com", header: "x-goog-api-key", prefix: "", keyPage: "https://aistudio.google.com/apikey")),
    ("REVENUECAT", Known(service: "revenuecat", displayName: "RevenueCat", host: "api.revenuecat.com", header: "Authorization", prefix: "Bearer ", keyPage: "https://app.revenuecat.com")),
    ("POSTHOG_PERSONAL", Known(service: "posthog", displayName: "PostHog", host: "us.posthog.com", header: "Authorization", prefix: "Bearer ", keyPage: "https://us.posthog.com/settings/user-api-keys")),
    ("PERPLEXITY", Known(service: "perplexity", displayName: "Perplexity", host: "api.perplexity.ai", header: "Authorization", prefix: "Bearer ", keyPage: "https://www.perplexity.ai/settings/api")),
    ("COHERE", Known(service: "cohere", displayName: "Cohere", host: "api.cohere.com", header: "Authorization", prefix: "Bearer ", keyPage: "https://dashboard.cohere.com/api-keys")),
  ]

  public struct Found: Identifiable, Equatable {
    public var id: String { file + "#" + name }
    public let file: String
    public let name: String
    public let value: String
    public let service: Known?
    /// Safe to ship to browsers (publishable/anon keys): listed, but left alone unless the user ticks it.
    public var isPublic: Bool = false
    /// Used by the app itself (signing, encryption, sessions) or signs requests (AWS): a proxy can't put it back,
    /// so it's never imported as a placeholder. Holds the reason shown in the review.
    public var localOnly: String? = nil
    /// A secret whose name makes web frameworks bundle it into browser code (NEXT_PUBLIC_, VITE_, …).
    public var inFrontend: Bool { ImportScanner.exposedToBrowser(name: name, value: value) }
    /// Format prefix kept in the placeholder so startup checks like `startsWith("sk-")` still pass.
    public var keyPrefix: String { ImportScanner.formatPrefix(value) }
    public static func == (a: Found, b: Found) -> Bool { a.id == b.id && a.value == b.value }
  }

  public struct FileResult: Identifiable {
    public var id: String { path }
    public let path: String
    public var folder: String { (path as NSString).deletingLastPathComponent }
    public var project: String { (folder as NSString).lastPathComponent }
    public let keys: [Found]
    public init(path: String, keys: [Found]) { self.path = path; self.keys = keys }
  }

  static let skipDirs: Set<String> = ["node_modules", ".git", "Library", "build", "dist", ".build", "DerivedData", "Pods",
                                      ".next", ".venv", "venv", "vendor", ".cache", "Applications", ".Trash"]

  /// Default places people keep code.
  public static var defaultRoots: [URL] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return ["Desktop", "Developer", "Projects", "projects", "code", "Code", "src", "dev", "GitHub", "repos", "Sites", "Documents"]
      .map { home.appendingPathComponent($0) }
      .filter { FileManager.default.fileExists(atPath: $0.path) }
  }

  /// Folders the user added with "Scan another folder…", on top of the defaults (paths, kept in preferences).
  public static let extraRootsKey = "scanFolders"
  public static var extraRoots: [URL] {
    (UserDefaults.standard.stringArray(forKey: extraRootsKey) ?? [])
      .filter { FileManager.default.fileExists(atPath: $0) }.map { URL(fileURLWithPath: $0) }
  }
  /// Remembers a folder to scan. The filesystem root is refused (too big to walk).
  @discardableResult public static func addExtraRoot(_ path: String) -> Bool {
    let p = (path as NSString).standardizingPath
    guard p != "/", !p.isEmpty else { return false }
    var list = UserDefaults.standard.stringArray(forKey: extraRootsKey) ?? []
    if !list.contains(p) { list.append(p); UserDefaults.standard.set(list, forKey: extraRootsKey) }
    return true
  }

  /// Env files in `folder` and its subfolders, `maxDepth` levels down, skipping dependency and build folders.
  public static func envFiles(in folder: String, maxDepth: Int = 2) -> [String] {
    var out: [String] = []
    func walk(_ dir: String, _ depth: Int) {
      guard let items = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return }
      for name in items.sorted() {
        let path = dir + "/" + name
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir) else { continue }
        if isDir.boolValue {
          if depth < maxDepth, !skipDirs.contains(name), !name.hasPrefix("."),
             (try? FileManager.default.destinationOfSymbolicLink(atPath: path)) == nil { walk(path, depth + 1) }
        } else if isEnvFile(name) { out.append(path) }
      }
    }
    walk(folder, 0)
    return out
  }

  public static func isEnvFile(_ name: String) -> Bool {
    if name == ".dev.vars" { return true }   // Cloudflare Workers local secrets
    guard name == ".env" || name.hasPrefix(".env.") else { return false }
    let lower = name.lowercased()
    return !["example", "sample", "template", "dist", "defaults", "schema"].contains { lower.contains($0) }
  }

  public static var includeShellProfiles = false

  public static func scan(roots: [URL] = defaultRoots + extraRoots, maxDepth: Int = 4) -> [FileResult] {
    var results: [FileResult] = []
    var seen = Set<String>()
    func walk(_ dir: URL, _ depth: Int) {
      guard depth <= maxDepth,
            let items = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey]) else { return }
      for item in items {
        let name = item.lastPathComponent
        let vals = try? item.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        if vals?.isSymbolicLink == true { continue }
        if vals?.isDirectory == true {
          if skipDirs.contains(name) || (name.hasPrefix(".") && name != ".config") { continue }
          walk(item, depth + 1)
        } else if isEnvFile(name), !seen.contains(item.path), let text = try? String(contentsOf: item, encoding: .utf8) {
          seen.insert(item.path)
          let keys = parse(text, file: item.path)
          if !keys.isEmpty { results.append(FileResult(path: item.path, keys: keys)) }
        }
      }
    }
    roots.forEach { walk($0, 0) }
    // Shell profiles (~/.zshrc …) aren't offered for import yet: rewriting them safely is planned for after launch
    // (docs/roadmap.md). Until then keydillo never edits them.
    for profile in shellProfiles where includeShellProfiles && !seen.contains(profile.path) {
      if let text = try? String(contentsOf: profile, encoding: .utf8) {
        let keys = parse(text, file: profile.path).filter { !$0.isPublic }
        if !keys.isEmpty { results.append(FileResult(path: profile.path, keys: keys)) }
      }
    }
    return results.sorted { $0.path < $1.path }
  }

  /// Secret-looking assignments in a .env file (public ones are included, flagged `isPublic`).
  public static func parse(_ text: String, file: String) -> [Found] {
    let pairs = text.split(separator: "\n", omittingEmptySubsequences: false).compactMap { assignment(String($0)) }
    let names = Set(pairs.map { $0.0.uppercased() })
    return pairs.compactMap { name, value in
      if value.contains("${") || value.contains("$(") { return nil }   // interpolation, not a key
      if looksSecret(name: name, value: value) {
        var f = Found(file: file, name: name, value: value, service: service(for: name), isPublic: isPublicValue(name: name, value: value, fileVars: names))
        f.localOnly = localUse(name: name, value: value)
        return f
      }
      if looksPublicByName(name), value.count >= 12, !Placeholder.isPlaceholder(value), !value.contains("://") {
        return Found(file: file, name: name, value: value, service: nil, isPublic: true)
      }
      return nil
    }
  }

  /// Secrets the app uses itself, which never travel to an API in a form a proxy could fill in.
  public static func localUse(name: String, value: String) -> String? {
    let n = name.uppercased()
    if value.hasPrefix("whsec_") || n.contains("WEBHOOK") || n.contains("SIGNING") || n.contains("SIGNATURE") || n.contains("HMAC") {
      return "verifies webhooks or signatures locally"
    }
    if n.contains("SECRET_ACCESS_KEY") || n.hasPrefix("AWS_") || n.contains("CLOUDINARY_API_SECRET") { return "signs requests (AWS-style)" }
    // Service-account files (raw or base64 JSON) are used to sign tokens locally, so a placeholder can't stand in.
    if n.contains("CREDENTIALS") || n.contains("KEYFILE") || value.hasPrefix("{") && value.contains("private_key")
        || (value.hasPrefix("eyJ") && value.count > 200 && (Data(base64Encoded: value).flatMap { String(data: $0, encoding: .utf8) }?.contains("private_key") ?? false)) {
      return "a credentials file your app signs with"
    }
    if ["JWT", "NEXTAUTH", "AUTH_SECRET", "SESSION", "COOKIE", "CSRF", "ENCRYPTION", "ENCRYPT", "CRON", "PASSWORD", "PASSWD",
        "PASSPHRASE", "SALT", "PRIVATE_KEY", "MASTER_KEY", "SERVICE_ACCOUNT", "DATABASE_URL", "DB_"].contains(where: { n.contains($0) }) {
      return "used by your app itself"
    }
    return nil
  }

  /// "sk-proj-abc…" → "sk-proj-", "sk_live_x" → "sk_live_", "xai-…" → "xai-". Letters-only segments, at most two.
  public static func formatPrefix(_ value: String) -> String {
    var out = ""; var segments = 0; var current = ""
    for ch in value {
      if ch == "-" || ch == "_" {
        guard !current.isEmpty, current.allSatisfy({ $0.isLetter || $0.isNumber }), current.count <= 6, current.first!.isLetter else { break }
        out += current + String(ch); current = ""; segments += 1
        if segments == 3 { break }
      } else { current.append(ch); if current.count > 6 { break } }
    }
    return out
  }

  /// Name prefixes that web frameworks copy into the JavaScript they send to browsers.
  public static let browserPrefixes = ["NEXT_PUBLIC_", "NUXT_PUBLIC_", "EXPO_PUBLIC_", "REACT_APP_", "GATSBY_", "VITE_", "PUBLIC_"]
  public static func browserPrefix(_ name: String) -> String? {
    let n = name.uppercased()
    return browserPrefixes.first { n.hasPrefix($0) }
  }
  static let secretValuePrefixes = ["sk-", "sk_live_", "sk_test_", "rk_live_", "rk_test_", "whsec_", "ghp_", "gho_", "github_pat_", "xoxb-", "xoxp-", "glpat-", "re_", "phx_", "AKIA"]

  /// True for a real secret under a browser prefix: anyone can read it in the deployed site's JavaScript.
  /// Keys meant for browsers (Stripe pk_, Supabase anon, Firebase and Maps keys, "publishable") don't count.
  public static func exposedToBrowser(name: String, value: String) -> Bool {
    guard let prefix = browserPrefix(name), value.count >= 12, !Placeholder.isPlaceholder(value), !value.contains("://") else { return false }
    let bare = String(name.uppercased().dropFirst(prefix.count))
    if isPublicValue(name: bare, value: value, fileVars: []) { return false }
    if secretValuePrefixes.contains(where: { value.hasPrefix($0) }) { return true }
    if value.hasPrefix("eyJ") { return jwtRole(value) == "service_role" }
    if ["PUBLISHABLE", "ANON", "PUBLIC", "MAPS", "FIREBASE", "MEASUREMENT", "SITE_KEY", "CLIENT_ID", "DSN"].contains(where: { bare.contains($0) }) { return false }
    return service(for: bare) != nil || ["SECRET", "PRIVATE", "PASSWORD", "SERVICE_ROLE"].contains { bare.contains($0) }
  }

  /// Plain explanation for a secret under a browser prefix.
  public static func frontendNote(_ name: String) -> String {
    "Names starting with \(browserPrefix(name) ?? "this prefix") are built into your site's JavaScript, so anyone can read this key in production. Rename it without the prefix and call the API from a server route instead."
  }

  static let publicMarkers = ["PUBLIC", "NEXT_PUBLIC_", "EXPO_PUBLIC_", "VITE_", "REACT_APP_", "PUBLISHABLE", "ANON"]
  static func looksPublicByName(_ name: String) -> Bool {
    let n = name.uppercased()
    return publicMarkers.contains { n.contains($0) } && ["KEY", "TOKEN", "SECRET"].contains { n.contains($0) }
  }

  /// Known public formats: Stripe pk_, Supabase anon JWTs, Firebase web config keys.
  public static func isPublicValue(name: String, value: String, fileVars: Set<String>) -> Bool {
    if value.hasPrefix("pk_live_") || value.hasPrefix("pk_test_") { return true }
    if value.hasPrefix("AIza") && fileVars.contains { $0.contains("AUTH_DOMAIN") || $0.contains("PROJECT_ID") } { return true }
    if value.hasPrefix("eyJ"), let role = jwtRole(value) { return role == "anon" }
    return false
  }

  static func jwtRole(_ jwt: String) -> String? {
    let parts = jwt.split(separator: ".")
    guard parts.count >= 2 else { return nil }
    var b = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while b.count % 4 != 0 { b += "=" }
    guard let d = Data(base64Encoded: b), let obj = try? JSONSerialization.jsonObject(with: d) as? [String: Any] else { return nil }
    return obj["role"] as? String
  }

  /// Shell profiles that may export keys (they override .env for anything started from a terminal).
  public static var shellProfiles: [URL] {
    let home = FileManager.default.homeDirectoryForCurrentUser
    return [".zshrc", ".zprofile", ".zshenv", ".bashrc", ".bash_profile", ".profile"].map { home.appendingPathComponent($0) }
      .filter { FileManager.default.fileExists(atPath: $0.path) }
  }

  static func assignment(_ line: String) -> (String, String)? {
    var l = line.trimmingCharacters(in: .whitespaces)
    if l.hasPrefix("#") || l.isEmpty { return nil }
    if l.hasPrefix("export ") { l = String(l.dropFirst(7)) }
    guard let eq = l.firstIndex(of: "=") else { return nil }
    let name = l[..<eq].trimmingCharacters(in: .whitespaces)
    var value = l[l.index(after: eq)...].trimmingCharacters(in: .whitespaces)
    if let q = value.first, q == "\"" || q == "'", value.count >= 2, value.last == q {
      value = unquote(value)
    } else if let hash = value.range(of: " #") {
      value = value[..<hash.lowerBound].trimmingCharacters(in: .whitespaces)
    }
    guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else { return nil }
    return (name, value)
  }

  public static func looksSecret(name: String, value: String) -> Bool {
    let n = name.uppercased()
    if publicMarkers.contains(where: { n.contains($0) }) { return false }
    if n.hasSuffix("_URL") || n.hasSuffix("_HOST") || n.hasSuffix("_PORT") || n.hasSuffix("_ID") && !n.contains("SECRET") { return false }
    let secretMarkers = ["KEY", "SECRET", "TOKEN", "PASSWORD", "PASS", "PRIVATE", "CREDENTIAL", "AUTH"]
    guard secretMarkers.contains(where: { n.contains($0) }) else { return false }
    if value.count < 12 || Placeholder.isPlaceholder(value) || value.contains("://") || value.contains(" ") { return false }
    return true
  }

  public static func service(for name: String) -> Known? {
    let n = name.uppercased()
    return known.first { n.contains($0.match) }?.1
  }

  // MARK: Rewriting

  public static let headerStart = "# --- keydillo ---"
  public static let headerEnd = "# --- end keydillo ---"
  public static func header(port: UInt16) -> [String] {
    [headerStart,
     "# Values starting with \"keydillo:\" are placeholders, not real keys. keydillo swaps in the real",
     "# key when a program sends one to its API. Put kd in front of commands that use these keys:",
     "# kd npm run dev. Claude Code does this for you.",
     "# If an API still says the key is invalid, the program skipped keydillo: call its *_BASE_URL",
     "# (http://localhost:\(port)/...) instead. Launch-time keys (database URLs, JWT secrets) are given to",
     "# the program by kd as it starts; it can see them. Never paste real keys here. AI agents: use keydillo.",
     headerEnd]
  }

  /// Removes everything keydillo added (header block and added base-URL lines).
  public static func stripKeydilloLines(_ text: String) -> String {
    var out: [String] = []; var inHeader = false; var skipAdded = false
    for line in text.components(separatedBy: "\n") {
      if line == headerStart { inHeader = true; continue }
      if line == headerEnd { inHeader = false; continue }
      if inHeader { continue }
      if line.hasPrefix("# Added by keydillo") { skipAdded = true; continue }
      if skipAdded {
        if line.isEmpty { skipAdded = false; continue }
        if let (_, v) = assignment(line), v.contains("://localhost:") || v.contains("://127.0.0.1:") { continue }
        skipAdded = false
      }
      out.append(line)
    }
    return out.joined(separator: "\n")
  }

  /// Replaces imported values with placeholders and adds base-URL lines. Returns the new file text.
  public static func rewrite(_ text: String, replacements: [String: (service: String, baseURL: String?, baseURLEnvName: String?)], port: UInt16 = 7787,
                             prefixes: [String: String] = [:], launchNames: Set<String> = []) -> String {
    var lines = text.components(separatedBy: "\n")
    if !lines.contains(headerStart) { lines = header(port: port) + lines }
    var added: [String] = []
    for (i, raw) in lines.enumerated() {
      guard let (name, _) = assignment(raw), let r = replacements[name] else { continue }
      let exported = raw.trimmingCharacters(in: .whitespaces).hasPrefix("export ")
      let placeholder = launchNames.contains(name) ? Placeholder.launchValue(for: r.service) : Placeholder.value(for: r.service)
      lines[i] = (exported ? "export " : "") + "\(name)=\(prefixes[name] ?? "")\(placeholder)"
      if let base = r.baseURL, let envName = r.baseURLEnvName,
         !lines.contains(where: { assignment($0)?.0 == envName }), !added.contains(where: { $0.hasPrefix(envName + "=") }) {
        added.append("\(envName)=\(base)")
      }
    }
    if !added.isEmpty {
      if lines.last == "" { lines.removeLast() }
      lines.append("")
      lines.append("# Added by keydillo: call these instead of the real API; keydillo adds the key.")
      lines.append(contentsOf: added)
      lines.append("")
    }
    return lines.joined(separator: "\n")
  }

  /// Keys keydillo had replaced with a placeholder that now hold a real value again (e.g. after `vercel env pull`).
  /// Values the user chose to leave in the file (unticked, public, launch-time keys they skipped) don't count.
  public static func keysBack(_ text: String, file: String, managed: Set<String>) -> [String] {
    parse(text, file: file).filter { managed.contains($0.name) && !$0.value.contains(Placeholder.prefix) }.map(\.name)
  }

  /// The value part of `NAME=value` for writing a real value back into an env file. Reuses the original text when it
  /// still means the same value (so the file's own quoting is kept); otherwise quotes only when needed.
  public static func envValueText(_ value: String, original: String? = nil) -> String {
    if let o = original, unquote(o) == value { return o }
    let plain = value.allSatisfy { $0.isLetter || $0.isNumber || "-_./:@+,%=~".contains($0) }
    if plain && !value.isEmpty { return value }
    if !value.contains("'") && !value.contains("\n") { return "'" + value + "'" }
    let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
      .replacingOccurrences(of: "\n", with: "\\n")
    return "\"" + escaped + "\""
  }

  /// What a dotenv loader reads from a value's text: quotes removed, \n and \" unescaped in double quotes.
  public static func unquote(_ text: String) -> String {
    let t = text.trimmingCharacters(in: .whitespaces)
    if t.count >= 2, t.hasPrefix("'"), t.hasSuffix("'") { return String(t.dropFirst().dropLast()) }
    if t.count >= 2, t.hasPrefix("\""), t.hasSuffix("\"") {
      return String(t.dropFirst().dropLast()).replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\\"", with: "\"")
        .replacingOccurrences(of: "\\\\", with: "\\")
    }
    if let hash = t.range(of: " #") { return String(t[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces) }
    return t
  }

  /// True when some line still holds a keydillo placeholder (comments, like the header's own text, don't count).
  public static func hasPlaceholders(_ text: String) -> Bool {
    text.components(separatedBy: "\n").contains { line in assignment(line).map { Placeholder.isPlaceholder($0.1) } ?? false }
  }

  /// After real values are written back: once no placeholders are left, remove keydillo's header and the
  /// base-URL lines it added, so the file is as it was before import. Lines the user wrote stay.
  public static func afterPutBack(_ text: String, droppingAdded names: Set<String> = []) -> String {
    if !hasPlaceholders(text) { return stripKeydilloLines(text) }
    guard !names.isEmpty else { return text }
    // Some keys are still locked away: keep the header, drop only the added base-URL lines for keys put back.
    var out: [String] = []; var inAdded = false
    for line in text.components(separatedBy: "\n") {
      if line.hasPrefix("# Added by keydillo") { inAdded = true; out.append(line); continue }
      if inAdded, line.isEmpty { inAdded = false }
      if inAdded, let (n, _) = assignment(line), names.contains(n) { continue }
      out.append(line)
    }
    return out.joined(separator: "\n")
  }
}
