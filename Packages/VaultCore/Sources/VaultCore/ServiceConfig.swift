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
    guard !upstreamHost.contains("/"), !upstreamHost.contains(" ") else { throw VaultError.invalidConfig("Host must be a bare hostname, like api.example.com") }
    let loopback = upstreamHost.hasPrefix("127.0.0.1") || upstreamHost.hasPrefix("localhost")
    guard upstreamScheme == "https" || (upstreamScheme == "http" && loopback) else {
      throw VaultError.invalidConfig("Upstreams must use https")
    }
    // An empty host/header means "stored, not set up for the proxy yet" (e.g. imported, unknown service).
    guard !authHeader.contains(":"), !authHeader.contains(" ") else {
      throw VaultError.invalidConfig("Bad header name")
    }
  }

  public var isProxyReady: Bool { !upstreamHost.isEmpty && !authHeader.isEmpty }

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
