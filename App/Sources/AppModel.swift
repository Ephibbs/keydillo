import Foundation
import SwiftUI
import VaultCore

@MainActor
@Observable
final class AppModel {
  static let accessGroup = "2JARAJYAYY.com.studiokillswitch.agentvault"
  let keychain = KeychainBackend.detect(accessGroup: AppModel.accessGroup)
  var services: [ServiceConfig] = []
  var events: [ActivityEvent] = []
  var proxyState = "starting"
  var port: UInt16 = 8787
  @ObservationIgnored private var engine: ProxyEngine!
  @ObservationIgnored private var server: ProxyServer!

  var storageDescription: String {
    switch keychain.mode {
    case .dataProtection: return "Private Keychain group, Touch ID on read"
    case .legacy: return "Login keychain, app-only access list"
    }
  }

  init() {
    services = keychain.load()
    let snapshot = SnapshotBox(services)
    engine = ProxyEngine(services: { snapshot.value }, secrets: keychain, approver: TouchIDApprover())
    engine.onEvent = { [weak self] e in
      Task { @MainActor in
        self?.events.insert(e, at: 0)
        if (self?.events.count ?? 0) > 500 { self?.events.removeLast() }
      }
    }
    self.snapshot = snapshot
    server = ProxyServer(port: port, engine: engine)
    server.onStateChange = { [weak self] s in Task { @MainActor in self?.proxyState = s } }
    do { try server.start() } catch { proxyState = "failed: \(error.localizedDescription)" }
  }

  @ObservationIgnored private var snapshot: SnapshotBox!

  var projects: [String] {
    Array(Set(services.map(\.project))).sorted()
  }

  func add(_ config: ServiceConfig, secret: String) throws {
    try config.validate()
    let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw VaultError.invalidConfig("Paste the key first") }
    var next = services.filter { $0.name != config.name }
    next.append(config)
    try keychain.setSecret(Data(trimmed.utf8), for: config.name, label: config.displayName)
    try keychain.save(next)
    services = next
    snapshot.value = next
  }

  func delete(_ name: String) {
    keychain.deleteSecret(name)
    services.removeAll { $0.name == name }
    try? keychain.save(services)
    snapshot.value = services
    Task { await engine.gate.revokeAll(service: name) }
  }
}

/// Thread-safe holder so the proxy (off the main actor) reads the current configs.
final class SnapshotBox: @unchecked Sendable {
  private let lock = NSLock()
  private var _value: [ServiceConfig]
  init(_ v: [ServiceConfig]) { _value = v }
  var value: [ServiceConfig] {
    get { lock.lock(); defer { lock.unlock() }; return _value }
    set { lock.lock(); _value = newValue; lock.unlock() }
  }
}
