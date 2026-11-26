import Foundation
import LocalAuthentication

/// A sign-in page a login has been approved for: the page and where its form sends.
public struct LoginPage: Codable, Equatable, Sendable {
  public var page: String
  public var action: String
  public init(page: String, action: String) { self.page = page; self.action = action }
}

/// A saved website login, without its password.
public struct LoginRecord: Codable, Equatable, Sendable {
  public var name: String
  /// Origin, e.g. https://github.com
  public var site: String
  public var username: String
  public var hasTotp: Bool
  public var pages: [LoginPage]
  public var created: Date?
  public init(name: String, site: String, username: String, hasTotp: Bool = false, pages: [LoginPage] = [], created: Date? = Date()) {
    self.name = name; self.site = site; self.username = username; self.hasTotp = hasTotp; self.pages = pages; self.created = created
  }
  public var host: String { URL(string: site)?.host ?? site }
}

public struct LoginSecret: Codable, Equatable, Sendable {
  public var password: String
  public var totp: String?
  public init(password: String, totp: String? = nil) { self.password = password; self.totp = totp }
}

/// Where logins live. The Keychain backend keeps passwords next to API keys, behind Touch ID.
public protocol LoginPersistence: AnyObject {
  func loadLogins() -> [LoginRecord]
  func saveLogins(_ logins: [LoginRecord]) throws
  func setLoginSecret(_ secret: LoginSecret, for name: String) throws
  func loginSecret(for name: String, context: LAContext?) throws -> LoginSecret
  func deleteLoginSecret(_ name: String)
}

extension KeychainBackend: LoginPersistence {
  public static let loginService = "keydillo.login"
  static let loginsAccount = "logins"

  public func loadLogins() -> [LoginRecord] {
    guard let d = setting(Self.loginsAccount), !d.isEmpty else { return [] }
    return (try? JSONDecoder().decode([LoginRecord].self, from: d)) ?? []
  }

  public func saveLogins(_ logins: [LoginRecord]) throws {
    try setSetting(Self.loginsAccount, try JSONEncoder().encode(logins))
  }

  public func setLoginSecret(_ secret: LoginSecret, for name: String) throws {
    try setSecret(try JSONEncoder().encode(secret), for: name, label: "login \(name)", service: Self.loginService)
  }

  public func loginSecret(for name: String, context: LAContext?) throws -> LoginSecret {
    let d = try secret(for: name, context: context, service: Self.loginService)
    return try JSONDecoder().decode(LoginSecret.self, from: d)
  }

  public func deleteLoginSecret(_ name: String) { deleteSecret(name, service: Self.loginService) }
}

/// In memory, for tests.
public final class MemoryLogins: LoginPersistence {
  public var logins: [LoginRecord] = []
  public var secrets: [String: LoginSecret] = [:]
  public init() {}
  public func loadLogins() -> [LoginRecord] { logins }
  public func saveLogins(_ l: [LoginRecord]) throws { logins = l }
  public func setLoginSecret(_ s: LoginSecret, for name: String) throws { secrets[name] = s }
  public func loginSecret(for name: String, context: LAContext?) throws -> LoginSecret {
    guard let s = secrets[name] else { throw VaultError.keyNotFound(name) }
    return s
  }
  public func deleteLoginSecret(_ name: String) { secrets[name] = nil }
}

public enum LoginRules {
  /// `https://host[:port]`, or http for localhost. nil when not acceptable.
  public static func normalizeSite(_ s: String) -> String? {
    let raw = s.contains("://") ? s : "https://" + s
    guard let u = URL(string: raw), let scheme = u.scheme?.lowercased(), let host = u.host?.lowercased(), !host.isEmpty else { return nil }
    let local = host == "localhost" || host == "127.0.0.1"
    guard scheme == "https" || (scheme == "http" && local) else { return nil }
    return "\(scheme)://\(host)" + (u.port.map { ":\($0)" } ?? "")
  }

  public static func origin(of s: String) -> String? {
    guard let u = URL(string: s), let scheme = u.scheme?.lowercased(), let host = u.host?.lowercased() else { return nil }
    return "\(scheme)://\(host)" + (u.port.map { ":\($0)" } ?? "")
  }

  public static func isValidName(_ n: String) -> Bool {
    n.range(of: #"^[a-z0-9][a-z0-9._-]{0,40}$"#, options: [.regularExpression, .caseInsensitive]) != nil
  }
}
