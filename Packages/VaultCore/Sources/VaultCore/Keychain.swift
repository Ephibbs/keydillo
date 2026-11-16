import Foundation
import Security
import LocalAuthentication

/// Where secrets and configs live.
///
/// - `.dataProtection(group)`: the modern keychain, scoped to an access group only binaries signed by
///   this team with that entitlement can use. Invisible to `security` and other apps. Secrets also carry
///   `.userPresence`, so even this app needs Touch ID (or the login password) to read them.
/// - `.legacy`: the login keychain. The default ACL trusts only the creating app; any other process
///   (including `security find-generic-password`) gets a macOS password prompt. The app enforces
///   Touch ID itself before reading.
public enum KeychainMode: Equatable {
  case dataProtection(accessGroup: String)
  case legacy
}

public final class KeychainBackend: ConfigPersistence {
  public let mode: KeychainMode
  public static let secretService = "keydillo.secret"
  static let configService = "keydillo.config"
  static let configAccount = "services"

  public init(mode: KeychainMode) { self.mode = mode }

  /// Picks data protection when the binary carries the access group entitlement, else legacy.
  public static func detect(accessGroup: String) -> KeychainBackend {
    let probe = KeychainBackend(mode: .dataProtection(accessGroup: accessGroup))
    var q = probe.base(service: "keydillo.probe", account: "probe")
    q[kSecReturnAttributes as String] = true
    let status = SecItemCopyMatching(q as CFDictionary, nil)
    if status == errSecMissingEntitlement { return KeychainBackend(mode: .legacy) }
    return probe
  }

  func base(service: String, account: String) -> [String: Any] {
    var q: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service,
      kSecAttrAccount as String: account,
    ]
    if case .dataProtection(let group) = mode {
      q[kSecUseDataProtectionKeychain as String] = true
      q[kSecAttrAccessGroup as String] = group
    }
    return q
  }

  // MARK: Secrets

  public func setSecret(_ value: Data, for name: String, label: String, service: String = KeychainBackend.secretService) throws {
    SecItemDelete(base(service: service, account: name) as CFDictionary)
    var q = base(service: service, account: name)
    q[kSecValueData as String] = value
    q[kSecAttrLabel as String] = "keydillo: \(label)"
    if case .dataProtection = mode {
      var err: Unmanaged<CFError>?
      guard let ac = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, .userPresence, &err) else {
        throw VaultError.keychain(errSecParam)
      }
      q[kSecAttrAccessControl as String] = ac
    } else {
      q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
    }
    let s = SecItemAdd(q as CFDictionary, nil)
    guard s == errSecSuccess else { throw VaultError.keychain(s) }
  }

  /// Reads a secret. Pass an `LAContext` already evaluated by `Approver` so data-protection items
  /// don't prompt a second time.
  public func secret(for name: String, context: LAContext?) throws -> Data {
    try secret(for: name, context: context, service: Self.secretService)
  }

  public func secret(for name: String, context: LAContext?, service: String) throws -> Data {
    var q = base(service: service, account: name)
    q[kSecReturnData as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitOne
    if let context { q[kSecUseAuthenticationContext as String] = context }
    var out: CFTypeRef?
    let s = SecItemCopyMatching(q as CFDictionary, &out)
    if s == errSecItemNotFound { throw VaultError.keyNotFound(name) }
    if s == errSecUserCanceled || s == errSecAuthFailed { throw VaultError.denied }
    guard s == errSecSuccess, let d = out as? Data else { throw VaultError.keychain(s) }
    return d
  }

  public func hasSecret(_ name: String) -> Bool {
    var q = base(service: Self.secretService, account: name)
    q[kSecReturnAttributes as String] = true
    let ctx = LAContext(); ctx.interactionNotAllowed = true
    q[kSecUseAuthenticationContext as String] = ctx
    let s = SecItemCopyMatching(q as CFDictionary, nil)
    return s == errSecSuccess || s == errSecInteractionNotAllowed
  }

  public func deleteSecret(_ name: String, service: String = KeychainBackend.secretService) {
    SecItemDelete(base(service: service, account: name) as CFDictionary)
  }

  /// Account names stored under a service (no values, no prompt).
  public func accounts(service: String) -> [String] {
    var q = base(service: service, account: "")
    q.removeValue(forKey: kSecAttrAccount as String)
    q[kSecReturnAttributes as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitAll
    let ctx = LAContext(); ctx.interactionNotAllowed = true
    q[kSecUseAuthenticationContext as String] = ctx
    var out: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return [] }
    return items.compactMap { $0[kSecAttrAccount as String] as? String }
  }

  // MARK: Configs (ConfigPersistence)

  public func load() -> [ServiceConfig] {
    var q = base(service: Self.configService, account: Self.configAccount)
    q[kSecReturnData as String] = true
    var out: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let d = out as? Data else { return [] }
    return (try? JSONDecoder().decode([ServiceConfig].self, from: d)) ?? []
  }

  public func save(_ services: [ServiceConfig]) throws {
    let data = try JSONEncoder().encode(services)
    let q = base(service: Self.configService, account: Self.configAccount)
    let s = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
    if s == errSecItemNotFound {
      var add = q
      add[kSecValueData as String] = data
      add[kSecAttrLabel as String] = "keydillo: service rules"
      let a = SecItemAdd(add as CFDictionary, nil)
      guard a == errSecSuccess else { throw VaultError.keychain(a) }
    } else if s != errSecSuccess {
      throw VaultError.keychain(s)
    }
  }
}
