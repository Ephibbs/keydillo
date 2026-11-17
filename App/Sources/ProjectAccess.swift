import Foundation
import LocalAuthentication
import VaultCore

/// How long one Touch ID opens a project's keys for programs working inside that project's folder.
enum ProjectAccess: String, CaseIterable, Identifiable {
  /// No project-wide approval: each key follows its own setting (e.g. once per session).
  case perKey
  case hour1, hours8, untilLock
  /// Open until keydillo quits.
  case always

  var id: String { rawValue }
  var label: String {
    switch self {
    case .perKey: return "Each key's own setting"
    case .hour1: return "1 hour"
    case .hours8: return "8 hours"
    case .untilLock: return "Until the Mac locks"
    case .always: return "Don't ask again"
    }
  }
  /// Phrase used in the Touch ID prompt and the menu bar.
  var span: String {
    switch self {
    case .perKey: return ""
    case .hour1: return "for 1 hour"
    case .hours8: return "for 8 hours"
    case .untilLock: return "until the Mac locks"
    case .always: return "until keydillo quits"
    }
  }
  var duration: TimeInterval? {
    switch self {
    case .hour1: return 3600
    case .hours8: return 8 * 3600
    default: return nil
    }
  }
}

/// Which callers an open project covers.
enum ProjectScope: String, CaseIterable, Identifiable {
  /// Only processes started by Claude Code, verified by Anthropic's code signature.
  case claude
  /// Anything running inside the project's folder, including your Terminal.
  case any
  var id: String { rawValue }
  var label: String { self == .claude ? "Claude Code only" : "Claude Code and my Terminal" }
}

/// A project opened with one Touch ID. While open, its keys are kept in keydillo's memory so they keep
/// working when the Mac locks (the Keychain can't be read while locked). Dropped when the window ends.
final class ProjectUnlockStore: @unchecked Sendable {
  struct Unlock {
    var context: LAContext
    var access: ProjectAccess
    var opened: Date
    var expires: Date?
    var folder: String
    var secrets: [String: SecureBuffer] = [:]
  }
  private var unlocks: [String: Unlock] = [:]
  private let lock = NSLock()
  var onChange: (() -> Void)?

  func valid(_ project: String) -> Unlock? {
    lock.lock(); defer { lock.unlock() }
    guard let u = unlocks[project] else { return nil }
    if let e = u.expires, e <= Date() { unlocks[project] = nil; DispatchQueue.main.async { self.onChange?() }; return nil }
    return u
  }

  /// Opens a project and reads its keys into memory right away, so they keep working if the Mac locks.
  func open(_ project: String, access: ProjectAccess, folder: String, context: LAContext, keys: [String] = [], keychain: KeychainBackend? = nil) {
    var secrets: [String: SecureBuffer] = [:]
    if let keychain { for k in keys { if let d = try? keychain.secret(for: k, context: context) { secrets[k] = SecureBuffer(d) } } }
    lock.lock()
    unlocks[project] = Unlock(context: context, access: access, opened: Date(), expires: access.duration.map { Date().addingTimeInterval($0) },
                              folder: folder, secrets: secrets)
    lock.unlock()
    DispatchQueue.main.async { self.onChange?() }
  }

  func close(_ project: String) {
    lock.lock(); unlocks[project] = nil; lock.unlock()
    DispatchQueue.main.async { self.onChange?() }
  }

  func closeAll(where shouldClose: (Unlock) -> Bool = { _ in true }) {
    lock.lock(); unlocks = unlocks.filter { !shouldClose($0.value) }; lock.unlock()
    DispatchQueue.main.async { self.onChange?() }
  }

  func cached(_ project: String, service: String) -> Data? {
    lock.lock(); defer { lock.unlock() }
    guard let u = unlocks[project], u.expires.map({ $0 > Date() }) ?? true else { return nil }
    return u.secrets[service]?.data
  }

  func remember(_ project: String, service: String, secret: Data) {
    lock.lock(); defer { lock.unlock() }
    unlocks[project]?.secrets[service] = SecureBuffer(secret)
  }

  /// Open projects, soonest to expire first. Expired ones are dropped.
  func list() -> [(project: String, unlock: Unlock)] {
    lock.lock(); defer { lock.unlock() }
    unlocks = unlocks.filter { $0.value.expires.map { $0 > Date() } ?? true }
    return unlocks.map { ($0.key, $0.value) }.sorted { ($0.unlock.expires ?? .distantFuture) < ($1.unlock.expires ?? .distantFuture) }
  }
}

/// Reads keys from the Keychain, or from memory for a project that's currently open.
final class ProjectAwareSecrets: SecretProvider, @unchecked Sendable {
  let keychain: KeychainBackend
  let store: ProjectUnlockStore
  let projectOf: (String) -> String?
  init(keychain: KeychainBackend, store: ProjectUnlockStore, projectOf: @escaping (String) -> String?) {
    self.keychain = keychain; self.store = store; self.projectOf = projectOf
  }

  func secret(for name: String, context: LAContext?) throws -> Data {
    guard let project = projectOf(name), let open = store.valid(project) else { return try keychain.secret(for: name, context: context) }
    if let d = store.cached(project, service: name) { return d }
    let d = try keychain.secret(for: name, context: context ?? open.context)
    store.remember(project, service: name, secret: d)
    return d
  }
}


/// A key held in memory while its project is open: locked into RAM (never written to swap) and
/// overwritten with zeros as soon as it's dropped.
final class SecureBuffer: @unchecked Sendable {
  private let ptr: UnsafeMutableRawPointer
  private let count: Int
  private let length: Int
  init(_ d: Data) {
    length = d.count
    count = max(d.count, 1)
    ptr = UnsafeMutableRawPointer.allocate(byteCount: count, alignment: 16)
    mlock(ptr, count)
    d.withUnsafeBytes { if let b = $0.baseAddress { ptr.copyMemory(from: b, byteCount: d.count) } }
  }
  /// A short-lived copy for one request.
  var data: Data { Data(bytes: ptr, count: length) }
  deinit {
    memset_s(ptr, count, 0, count)
    munlock(ptr, count)
    ptr.deallocate()
  }
}
