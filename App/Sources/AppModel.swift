import Foundation
import SwiftUI
import AppKit
import LocalAuthentication
import ServiceManagement
import VaultCore

enum DefaultApproval: String, CaseIterable {
  case eachRequest, window15, session
  var mode: ApprovalMode {
    switch self {
    case .eachRequest: return .eachRequest
    case .window15: return .window(minutes: 15)
    case .session: return .perProcess
    }
  }
  var label: String {
    switch self {
    case .eachRequest: return "Every time"
    case .window15: return "Every 15 min"
    case .session: return "Once per session"
    }
  }
}

extension ApprovalMode {
  var label: String {
    switch self {
    case .eachRequest: return "Touch ID every time"
    case .window(let m): return "Touch ID every \(m) min"
    case .perProcess: return "Touch ID once per session"
    }
  }
  var asDefault: DefaultApproval {
    switch self {
    case .eachRequest: return .eachRequest
    case .window: return .window15
    case .perProcess: return .session
    }
  }
}

/// What the key window is for: the user adding a key, or an agent asking for one.
struct KeyRequest: Identifiable {
  let id = UUID()
  var service: String
  var displayName: String
  var host: String
  var header: String
  var prefix: String
  var envVarName: String
  var project: String
  var requester: String?
  var cwd: String?
  var keyPageURL: String = ""
  var fromAgent: Bool { requester != nil }
  static let cliRequester = "keydillo CLI"
}

struct PendingApproval: Identifiable {
  let id = UUID()
  let request: ApprovalRequest
  let context: LAContext
  var project: String
}

@MainActor
@Observable
final class AppModel {
  static let shared = AppModel()
  static let accessGroup = "2JARAJYAYY.com.studiokillswitch.keydillo"

  let keychain = KeychainBackend.detect(accessGroup: AppModel.accessGroup)
  var services: [ServiceConfig] = []
  var events: [ActivityEvent] = []
  var pending: [PendingApproval] = []
  var activeGrants: [(service: String, expires: Date?, client: ClientProcess?)] = []
  var proxyState = "starting"
  var paused = false
  var extraProjects: [String] = UserDefaults.standard.stringArray(forKey: "projects") ?? []

  /// Chosen once (7787, or the next free port on first launch), then never changed silently.
  var port: UInt16 {
    get {
      if let p = UInt16(UserDefaults.standard.integer(forKey: "port")).nonZero { return p }
      let p = Ports.firstFree(from: 7787) ?? 7787
      UserDefaults.standard.set(Int(p), forKey: "port")
      return p
    }
    set { UserDefaults.standard.set(Int(newValue), forKey: "port") }
  }
  /// Set when the saved port is taken by something else.
  var portConflict: (port: UInt16, owner: String?, suggestion: UInt16)?
  var setupDone: Bool {
    get { UserDefaults.standard.bool(forKey: "setupDone") }
    set { UserDefaults.standard.set(newValue, forKey: "setupDone") }
  }
  var defaultApproval: DefaultApproval {
    get { DefaultApproval(rawValue: UserDefaults.standard.string(forKey: "defaultApproval") ?? "") ?? .window15 }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: "defaultApproval") }
  }

  @ObservationIgnored private var engine: ProxyEngine!
  @ObservationIgnored private var server: ProxyServer?
  @ObservationIgnored private let snapshot = SnapshotBox([])
  @ObservationIgnored private var keyRequestWaiters: [UUID: CheckedContinuation<ControlResponse, Never>] = [:]

  var projects: [String] {
    Array(Set(services.map(\.project) + extraProjects)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
  }

  private init() {
    services = keychain.load()
    snapshot.value = services
    let approver = ModelApprover(model: self)
    engine = ProxyEngine(services: { [snapshot] in snapshot.value }, secrets: keychain, approver: approver)
    engine.onEvent = { [weak self] e in
      Task { @MainActor in
        guard let self else { return }
        self.events.insert(e, at: 0)
        if self.events.count > 1000 { self.events.removeLast() }
        await self.refreshGrants()
      }
    }
    startProxy()
    startControl()
  }

  // MARK: Proxy

  func startProxy() {
    let p = port
    if !Ports.isFree(p) {
      portConflict = (p, Ports.listener(on: p), Ports.firstFree(from: p + 1) ?? p + 1)
      proxyState = "port \(p) is in use"
      return
    }
    portConflict = nil
    let srv = ProxyServer(port: p, engine: engine)
    srv.onStateChange = { [weak self] s in Task { @MainActor in self?.proxyState = s } }
    server = srv
    do { try srv.start(); paused = false } catch { proxyState = "failed: \(error.localizedDescription)" }
  }

  func movePort(to p: UInt16) {
    server?.stop()
    port = p
    startProxy()
  }

  func togglePause() {
    if paused { startProxy() } else { server?.stop(); paused = true; proxyState = "paused" }
  }

  var proxyRunning: Bool { proxyState == "ready" && !paused }

  func refreshGrants() async { activeGrants = await engine.gate.activeGrants() }

  func endGrant(_ service: String) {
    Task { await engine.gate.revokeAll(service: service); await refreshGrants() }
  }

  // MARK: Approvals (driven by the proxy)

  func showPending(_ p: PendingApproval) { pending.append(p); StatusItem.shared?.flash() }
  func clearPending(_ id: UUID) { pending.removeAll { $0.id == id } }

  /// Popover "Deny": cancels the Touch ID prompt.
  func deny(_ p: PendingApproval) { p.context.invalidate(); clearPending(p.id) }

  /// Popover "15 min": the next Touch ID success also opens a 15-minute window.
  var windowUpgrades: Set<UUID> = []
  func allowWindow(_ p: PendingApproval) { windowUpgrades.insert(p.id) }

  func applyUpgradeIfNeeded(_ id: UUID, service: String, context: LAContext) {
    guard windowUpgrades.remove(id) != nil else { return }
    Task { await engine.gate.grantWindow(service: service, minutes: 15, context: context); await refreshGrants() }
  }

  // MARK: Keys

  func service(named n: String) -> ServiceConfig? { services.first { $0.name == n } }

  func summary(_ s: ServiceConfig) -> ServiceSummary { s.summary(port: port) }

  /// Saves a key after Touch ID. Returns false if the user cancelled.
  func save(_ config: ServiceConfig, secret: String) async throws -> Bool {
    try config.validate()
    let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw VaultError.invalidConfig("Paste the key first") }
    guard await authenticate("save your \(config.displayName) key") != nil else { return false }
    try keychain.setSecret(Data(trimmed.utf8), for: config.name, label: config.displayName)
    try persist(services.filter { $0.name != config.name } + [config])
    return true
  }

  /// Rule edits that change where a key can go need Touch ID too.
  func update(_ config: ServiceConfig) async throws -> Bool {
    try config.validate()
    if let old = service(named: config.name), old.upstreamHost != config.upstreamHost || old.authHeader != config.authHeader {
      guard await authenticate("send your \(config.displayName) key to \(config.upstreamHost)") != nil else { return false }
    }
    try persist(services.map { $0.name == config.name ? config : $0 })
    Task { await engine.gate.revokeAll(service: config.name); await refreshGrants() }
    return true
  }

  func delete(_ name: String) {
    keychain.deleteSecret(name)
    try? persist(services.filter { $0.name != name })
    Task { await engine.gate.revokeAll(service: name); await refreshGrants() }
  }

  func addImported(_ new: [ServiceConfig]) throws {
    guard !new.isEmpty else { return }
    let names = Set(new.map(\.name))
    try persist(services.filter { !names.contains($0.name) } + new)
  }

  /// Folder a project's keys came from, if known.
  func folder(for project: String) -> String? {
    services.first { $0.project == project && $0.folder != nil }?.folder
  }

  func addProject(_ name: String) {
    let n = name.trimmingCharacters(in: .whitespaces)
    guard !n.isEmpty, !projects.contains(n) else { return }
    extraProjects.append(n)
    UserDefaults.standard.set(extraProjects, forKey: "projects")
  }

  private func persist(_ next: [ServiceConfig]) throws {
    try keychain.save(next)
    services = next
    snapshot.value = next
  }

  // MARK: Readout (GUI only)

  /// Values for a project's keys, after Touch ID. Never reachable from the CLI, MCP or proxy.
  func readout(project: String) async -> [(ServiceConfig, String)]? {
    guard let ctx = await authenticate("show the keys for \(project)") else { return nil }
    return services.filter { $0.project == project }.compactMap { s in
      guard let d = try? keychain.secret(for: s.name, context: ctx) else { return nil }
      return (s, String(decoding: d, as: UTF8.self))
    }
  }

  func authenticate(_ reason: String) async -> LAContext? {
    let ctx = LAContext()
    do { return try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) ? ctx : nil }
    catch { return nil }
  }

  // MARK: Control socket (CLI / MCP)

  func startControl() {
    do {
      try ControlSocket.serve { req in
        await MainActor.run { AppModel.shared }.handle(req)
      }
    } catch {
      NSLog("keydillo: control socket failed: \(error)")
    }
  }

  func handle(_ req: ControlRequest) async -> ControlResponse {
    switch req {
    case .listServices:
      return .services(services.map(summary))
    case .status:
      let blocks = events.filter { $0.outcome != .sent }.prefix(10).map { e in
        "\(e.date.formatted(date: .omitted, time: .shortened)) \(e.process) → \(e.service) \(e.method) \(e.path): \(e.outcome.rawValue)\(e.note.map { " (\($0))" } ?? "")"
      }
      return .status(StatusInfo(proxyRunning: proxyRunning, proxyState: proxyState, port: port, storage: storageDescription,
                                services: services.map(summary), recentBlocks: Array(blocks)))
    case .requestSecret(let r):
      guard ServiceConfig.isValidName(r.service) else { return .error("service must be lowercase letters, digits and dashes") }
      let kr = KeyRequest(service: r.service, displayName: r.displayName ?? HostCheck.displayName(r.service), host: r.host,
                          header: r.header, prefix: r.prefix ?? "",
                          envVarName: r.envVarName ?? ServiceConfig(name: r.service, upstreamHost: r.host, authHeader: r.header).envVarName,
                          project: r.project ?? "Personal", requester: r.requester == KeyRequest.cliRequester ? nil : (r.requester ?? "an agent"), cwd: r.cwd,
                          keyPageURL: r.keyPageURL ?? "")
      return await withCheckedContinuation { cont in
        keyRequestWaiters[kr.id] = cont
        WindowManager.shared.showKeyWindow(kr)
      }
    }
  }

  func finishKeyRequest(_ id: UUID, saved: ServiceConfig?) {
    guard let cont = keyRequestWaiters.removeValue(forKey: id) else { return }
    if let saved { let s = summary(saved); cont.resume(returning: .saved(s, envLines: s.placeholderEnvLines)) }
    else { cont.resume(returning: .declined) }
  }

  // MARK: Settings

  /// Starts keydillo at login and restarts it if it ever crashes (a launchd agent with KeepAlive).
  static let agent = SMAppService.agent(plistName: "com.studiokillswitch.keydillo.agent.plist")
  var openAtLogin: Bool {
    get { Self.agent.status == .enabled }
    set { if newValue { try? Self.agent.register() } else { try? Self.agent.unregister() } }
  }

  /// Logs a note if the last run ended without a normal quit.
  func noteUncleanExit() {
    let marker = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("keydillo/running")
    if FileManager.default.fileExists(atPath: marker.path) {
      events.insert(ActivityEvent(date: Date(), service: "keydillo", method: "", path: "", process: "keydillo", pid: getpid(),
                                  outcome: .failed, status: 0, note: "restarted after an unexpected stop"), at: 0)
    }
    FileManager.default.createFile(atPath: marker.path, contents: Data())
  }
  func noteCleanExit() {
    let marker = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("keydillo/running")
    try? FileManager.default.removeItem(at: marker)
  }

  var storageDescription: String {
    switch keychain.mode {
    case .dataProtection: return "Private Keychain group, Touch ID on every read"
    case .legacy: return "Login Keychain, readable only by keydillo"
    }
  }
}

/// Bridges proxy approvals to Touch ID and the popover.
final class ModelApprover: Approver, @unchecked Sendable {
  weak var model: AppModel?
  init(model: AppModel) { self.model = model }

  static var screenLocked: Bool {
    guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return (d["CGSSessionScreenIsLocked"] as? Bool) == true
  }

  func approve(_ request: ApprovalRequest) async -> ApprovalResult {
    if Self.screenLocked { return .unavailable("the Mac is locked") }
    let ctx = LAContext()
    ctx.localizedCancelTitle = "Deny"
    let project = await MainActor.run { model?.service(named: request.service)?.project ?? "" }
    let pending = PendingApproval(request: request, context: ctx, project: project)
    await MainActor.run { model?.showPending(pending) }
    defer { Task { @MainActor in model?.clearPending(pending.id) } }
    do {
      guard try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: request.reason) else { return .denied }
      await MainActor.run { model?.applyUpgradeIfNeeded(pending.id, service: request.service, context: ctx) }
      return .approved(ctx)
    } catch {
      return .denied
    }
  }
}

final class SnapshotBox: @unchecked Sendable {
  private let lock = NSLock()
  private var _value: [ServiceConfig]
  init(_ v: [ServiceConfig]) { _value = v }
  var value: [ServiceConfig] {
    get { lock.lock(); defer { lock.unlock() }; return _value }
    set { lock.lock(); _value = newValue; lock.unlock() }
  }
}

extension UInt16 { var nonZero: UInt16? { self == 0 ? nil : self } }
