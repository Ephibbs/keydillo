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

  public static func isEnvFile(_ name: String) -> Bool {
    if name == ".dev.vars" { return true }   // Cloudflare Workers local secrets
    guard name == ".env" || name.hasPrefix(".env.") else { return false }
    let lower = name.lowercased()
    return !["example", "sample", "template", "dist", "defaults", "schema"].contains { lower.contains($0) }
  }

  public static func scan(roots: [URL] = defaultRoots, maxDepth: Int = 4) -> [FileResult] {
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
    for profile in shellProfiles where !seen.contains(profile.path) {
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
      if looksSecret(name: name, value: value) {
        return Found(file: file, name: name, value: value, service: service(for: name), isPublic: isPublicValue(name: name, value: value, fileVars: names))
      }
      if looksPublicByName(name), value.count >= 12, !value.hasPrefix(Placeholder.prefix), !value.contains("://") {
        return Found(file: file, name: name, value: value, service: nil, isPublic: true)
      }
      return nil
    }
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
      value = String(value.dropFirst().dropLast())
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
    if value.count < 12 || value.hasPrefix(Placeholder.prefix) || value.contains("://") || value.contains(" ") { return false }
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
     "# Secrets in this file are managed by keydillo. Values starting with \"keydillo:\" are",
     "# placeholders, not real keys. To call an API, use its *_BASE_URL (http://localhost:\(port)/...)",
     "# with no key, or run commands with: keydillo run -- <command>",
     "# Never paste real keys here. AI agents: use the keydillo tools (status, list_services).",
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
  public static func rewrite(_ text: String, replacements: [String: (service: String, baseURL: String?, baseURLEnvName: String?)], port: UInt16 = 7787) -> String {
    var lines = text.components(separatedBy: "\n")
    if !lines.contains(headerStart) { lines = header(port: port) + lines }
    var added: [String] = []
    for (i, raw) in lines.enumerated() {
      guard let (name, _) = assignment(raw), let r = replacements[name] else { continue }
      let exported = raw.trimmingCharacters(in: .whitespaces).hasPrefix("export ")
      lines[i] = (exported ? "export " : "") + "\(name)=\(Placeholder.value(for: r.service))"
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
}
