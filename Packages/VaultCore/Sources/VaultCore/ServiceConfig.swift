import Foundation

public enum ApprovalMode: Codable, Equatable, Hashable {
  /// Touch ID for every request.
  case eachRequest
  /// One Touch ID per client process (pid) until it exits or the app restarts.
  case perProcess
  /// One Touch ID, then allowed for `minutes`.
  case window(minutes: Int)
}

/// A rule like `POST /v1/text-to-speech/*`. Method `*` matches any method.
/// Path patterns: `*` at the end matches any suffix; otherwise exact match (query string ignored).
public struct PathRule: Codable, Equatable, Hashable {
  public var method: String
  public var pattern: String
  public init(method: String, pattern: String) { self.method = method.uppercased(); self.pattern = pattern }

  public func matches(method m: String, path: String) -> Bool {
    guard method == "*" || method == m.uppercased() else { return false }
    if pattern.hasSuffix("*") { return path.hasPrefix(String(pattern.dropLast())) }
    return path == pattern
  }
}

/// Everything about a key except its value. Stored as JSON; the value lives only in the Keychain.
public struct ServiceConfig: Codable, Equatable, Identifiable {
  public var id: String { name }
  /// URL segment: localhost:7787/<name>/...
  public var name: String
  public var displayName: String
  public var project: String
  public var upstreamHost: String
  /// "https" always, except loopback upstreams used in tests.
  public var upstreamScheme: String
  public var authHeader: String
  /// Optional prefix such as "Bearer ".
  public var authPrefix: String
  public var envVarName: String
  public var approval: ApprovalMode
  /// Empty means any method and path on the host.
  public var allowed: [PathRule]
  public var maxRequestsPerHour: Int?
  /// Provider page for managing/rotating this key, usually filled in by the agent.
  public var keyPageURL: String?
  /// Folder this key's project came from (import), for "Show in Finder".
  public var folder: String?
  /// Send the key as this query parameter (e.g. "key") instead of a header.
  public var authQueryParam: String?
  /// HTTP Basic auth: the key is the username (Stripe), or "user:password" (Twilio SID:token).
  public var basicAuth: Bool?
  /// More headers that carry the key, e.g. ["Authorization": "Bearer {key}"] for Supabase.
  public var extraHeaders: [String: String]?
  /// Path the provider's SDK expects at the end of its base URL (OpenAI: "/v1").
  public var sdkBasePath: String?
  /// Env var the provider's SDK reads its base URL from (OpenAI: OPENAI_BASE_URL).
  public var baseURLEnvName: String?
  /// Opt-in: allow the key's placeholder anywhere in a request (path, other headers, body), for APIs that need it.
  /// Off by default, because the allowed host could then echo, store or forward the key.
  public var placeholderAnywhere: Bool?
  /// A launch-time key (database URL, JWT secret…): not sent over the network by keydillo, but given to a program
  /// in its environment when `kd` starts it. The program can see the value.
  public var launchTime: Bool?
  /// The user chose this folder in keydillo (with Touch ID), so it counts as the project's folder even without a keydillo .env.
  public var folderChosen: Bool?
  public var isLaunchTime: Bool { launchTime == true }
  /// More hosts this key may be sent to, each one approved by the user with Touch ID naming it.
  public var extraHosts: [String]?

  public init(name: String, displayName: String? = nil, project: String = "Personal", upstreamHost: String,
              upstreamScheme: String = "https", authHeader: String, authPrefix: String = "",
              envVarName: String? = nil, approval: ApprovalMode = .eachRequest, allowed: [PathRule] = [],
              maxRequestsPerHour: Int? = nil) {
    self.name = name
    self.displayName = displayName ?? name.capitalized
    self.project = project
    self.upstreamHost = upstreamHost
    self.upstreamScheme = upstreamScheme
    self.authHeader = authHeader
    self.authPrefix = authPrefix
    self.envVarName = envVarName ?? (name.uppercased().replacingOccurrences(of: "-", with: "_") + "_API_KEY")
    self.approval = approval
    self.allowed = allowed
    self.maxRequestsPerHour = maxRequestsPerHour
  }

  public static func isValidName(_ s: String) -> Bool {
    !s.isEmpty && s.count <= 40 && s.allSatisfy { $0.isLowercase || $0.isNumber || $0 == "-" } && s.first!.isLetter
  }

  public func validate() throws {
    guard Self.isValidName(name) else { throw VaultError.invalidConfig("Name must be lowercase letters, digits and dashes") }
    if !upstreamHost.isEmpty {
      guard UpstreamTarget(self) != nil else { throw VaultError.invalidConfig("Host must be a bare hostname, like api.example.com") }
    }
    let loopback = UpstreamTarget(self).map { ["127.0.0.1", "localhost", "::1"].contains($0.host) } ?? false
    guard upstreamScheme == "https" || (upstreamScheme == "http" && loopback) else {
      throw VaultError.invalidConfig("Upstreams must use https")
    }
    // An empty host/header means "stored, not set up for the proxy yet" (e.g. imported, unknown service).
    guard !authHeader.contains(":"), !authHeader.contains(" ") else {
      throw VaultError.invalidConfig("Bad header name")
    }
  }

  /// A host is enough: without a header or query parameter, the key goes wherever its placeholder appears.
  public var isProxyReady: Bool { !upstreamHost.isEmpty }

  /// Every host the key may go to (lowercased; host[:port] as stored).
  public var allHosts: [String] {
    ([upstreamHost] + (extraHosts ?? [])).filter { !$0.isEmpty }.map { $0.lowercased() }
  }

  /// Words from the key's name that a host for an unknown provider likely contains ("together" for TOGETHER_API_KEY).
  /// kd looks inside traffic to such hosts so a key without a host yet can be locked to its host on first use.
  public var hostTokens: [String] {
    let generic: Set<String> = ["api", "key", "keys", "token", "secret", "access", "auth", "private", "service", "role", "rest", "app",
                                "client", "id", "prod", "dev", "test", "live", "local", "url", "base", "v1", "v2", "the"]
    let words = (name + "-" + envVarName).lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    return Array(Set(words.filter { $0.count >= 4 && !generic.contains($0) })).sorted()
  }

  public func permits(method: String, path: String) -> Bool {
    allowed.isEmpty || allowed.contains { $0.matches(method: method, path: path) }
  }
}

public enum VaultError: Error, Equatable, LocalizedError {
  case invalidConfig(String)
  case keyNotFound(String)
  case keychain(OSStatus)
  case denied
  public var errorDescription: String? {
    switch self {
    case .invalidConfig(let m): return m
    case .keyNotFound(let n): return "No key stored for \(n)"
    case .keychain(let s): return "Keychain error \(s): \(SecCopyErrorMessageString(s, nil) as String? ?? "")"
    case .denied: return "Request was not approved"
    }
  }
}

public protocol ConfigPersistence {
  func load() -> [ServiceConfig]
  func save(_ services: [ServiceConfig]) throws
}

/// File-backed store, used by tests only. The app keeps configs in the Keychain so an agent
/// cannot edit a service's upstream host to redirect a key.
public final class FileConfigStore: ConfigPersistence {
  public let url: URL
  public init(url: URL) { self.url = url }
  public func load() -> [ServiceConfig] {
    guard let d = try? Data(contentsOf: url) else { return [] }
    return (try? JSONDecoder().decode([ServiceConfig].self, from: d)) ?? []
  }
  public func save(_ services: [ServiceConfig]) throws {
    try JSONEncoder().encode(services).write(to: url, options: .atomic)
  }
}


/// A service's upstream, parsed strictly: lowercase host[:port], nothing else.
public struct UpstreamTarget: Equatable {
  public let host: String
  public let port: UInt16
  public let tls: Bool
  public var defaultPort: UInt16 { tls ? 443 : 80 }
  public var origin: String { "\(tls ? "https" : "http")://\(host)\(port == defaultPort ? "" : ":\(port)")" }

  static let pattern = try! NSRegularExpression(pattern: "^[a-z0-9]([a-z0-9.-]*[a-z0-9])?(:[0-9]{1,5})?$")

  public init?(_ svc: ServiceConfig) {
    let h = svc.upstreamHost.lowercased()
    guard h.allSatisfy({ $0.isASCII }), !h.contains(".."),
          Self.pattern.firstMatch(in: h, range: NSRange(h.startIndex..., in: h)) != nil else { return nil }
    tls = svc.upstreamScheme != "http"
    let parts = h.split(separator: ":", maxSplits: 1)
    host = String(parts[0])
    if parts.count == 2 {
      guard let p = UInt16(parts[1]), p > 0 else { return nil }
      port = p
    } else { port = tls ? 443 : 80 }
  }
}
