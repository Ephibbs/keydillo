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
  /// The private Keychain group this binary is entitled to, read from its own signature (works for anyone's team ID).
  static let accessGroup: String? = {
    guard let task = SecTaskCreateFromSelf(nil),
          let v = SecTaskCopyValueForEntitlement(task, "keychain-access-groups" as CFString, nil) as? [String] else { return nil }
    return v.first
  }()

  let keychain = AppModel.accessGroup.map { KeychainBackend.detect(accessGroup: $0) } ?? KeychainBackend(mode: .legacy)
  /// False when this build can't use a private Keychain group. keydillo then refuses to store keys rather than
  /// quietly falling back to the login Keychain, where other programs could change a key's rules.
  var storageSecure: Bool { if case .dataProtection = keychain.mode { return true }; return false }
  static let insecureMessage = "This copy of keydillo isn't signed with a Keychain access group, so it won't store keys. Build it with your own Apple team ID (see the README), or install a signed release."
  var services: [ServiceConfig] = []
  var events: [ActivityEvent] = []
  var pending: [PendingApproval] = []
  var activeGrants: [(service: String, expires: Date?, client: ClientProcess?)] = []
  var proxyState = "starting"
  var paused = false
  var extraProjects: [String] = UserDefaults.standard.stringArray(forKey: "projects") ?? []
  /// Keys the provider answered 401 for; cleared when the key is replaced.
  var rejected: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "rejectedKeys") ?? [])
  /// Imported .env files that have real key values in them again (e.g. after `vercel env pull`).
  var realKeyFiles: [String] = []

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
    get { DefaultApproval(rawValue: UserDefaults.standard.string(forKey: "defaultApproval") ?? "") ?? .session }
    set { UserDefaults.standard.set(newValue.rawValue, forKey: "defaultApproval") }
  }

  @ObservationIgnored private var engine: ProxyEngine!
  @ObservationIgnored private var server: ProxyServer?
  @ObservationIgnored private let snapshot = SnapshotBox([])
  @ObservationIgnored private var keyRequestWaiters: [UUID: CheckedContinuation<ControlResponse, Never>] = [:]

  var projects: [String] {
    Array(Set(services.map(\.project) + extraProjects)).sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
  }

  /// False until the key list has been read. While the Mac is locked the Keychain can't be read, so keydillo
  /// waits for unlock instead of showing (and later saving) an empty list.
  private(set) var servicesLoaded = false { didSet { loadedFlag.value = servicesLoaded } }
  @ObservationIgnored let loadedFlag = FlagBox()

  /// Reads the key list; returns false if the Keychain isn't readable yet.
  @discardableResult func loadServices() -> Bool {
    guard let list = keychain.loadChecked() else { return false }
    services = list
    snapshot.value = list
    if !servicesLoaded {
      servicesLoaded = true
      ImportModel.migrateFileBackups(model: self)
      ImportModel.migrateBaseURLs(model: self)
    }
    return true
  }

  private init() {
    let approver = ModelApprover(model: self)
    let secrets = ProjectAwareSecrets(keychain: keychain, store: unlocks, projectOf: { [snapshot] name in snapshot.value.first { $0.name == name }?.project })
    engine = ProxyEngine(services: { [snapshot] in snapshot.value }, secrets: secrets, approver: approver)
    unlocks.onChange = { [weak self] in self?.refreshOpenProjects() }
    Task { @MainActor in   // drop expired projects from the menu bar
      while true { try? await Task.sleep(for: .seconds(30)); self.refreshOpenProjects() }
    }
    engine.notReady = { [weak self] in
      guard let self else { return nil }
      return self.loadedFlag.value ? nil : "keydillo can't read keys until the Mac is unlocked"
    }
    engine.onEvent = { [weak self] e in
      Task { @MainActor in
        guard let self else { return }
        self.events.insert(e, at: 0)
        if self.events.count > 1000 { self.events.removeLast() }
        if e.note?.hasPrefix("key rejected") == true { self.rejected.insert(e.service); self.saveRejected() }
        await self.refreshGrants()
      }
    }
    if !loadServices() {
      Task { @MainActor in
        while !self.loadServices() { try? await Task.sleep(for: .seconds(3)) }
      }
    }
    startProxy()
    startControl()
    ImportModel.addHeadersToTrackedFiles(port: port)
    ImportModel.migratePlaceholders()
    ClaudeConnector.refreshSkillIfInstalled()
    ShellIntegration.refreshLinks()
    Task { @MainActor in
      while true {
        let paths = ImportModel.trackedFiles
        let found = await Task.detached { ImportModel.filesWithRealKeys(paths) }.value
        if found != self.realKeyFiles { self.realKeyFiles = found }
        try? await Task.sleep(for: .seconds(60))
      }
    }
  }

  // MARK: Project access (one Touch ID opens a project's keys for programs in its folder)

  @ObservationIgnored let unlocks = ProjectUnlockStore()
  /// Projects open right now, for the menu bar. Refreshed when one opens, closes or expires.
  private(set) var openProjects: [(project: String, unlock: ProjectUnlockStore.Unlock)] = []
  func refreshOpenProjects() { openProjects = unlocks.list() }

  /// What new projects use, chosen in Settings. Ships as "each key's own setting".
  var projectAccessDefault: ProjectAccess = ProjectAccess(rawValue: UserDefaults.standard.string(forKey: "projectAccessDefault") ?? "") ?? .perKey {
    didSet { UserDefaults.standard.set(projectAccessDefault.rawValue, forKey: "projectAccessDefault") }
  }
  /// Per-project choices that differ from the default.
  var projectAccessOverrides: [String: String] = AppModel.loadAccessOverrides() {
    didSet { UserDefaults.standard.set(projectAccessOverrides, forKey: "projectAccess") }
  }
  private static func loadAccessOverrides() -> [String: String] {
    var o = UserDefaults.standard.dictionary(forKey: "projectAccess") as? [String: String] ?? [:]
    // Earlier versions had a single "Don't ask for Touch ID" switch.
    for p in UserDefaults.standard.stringArray(forKey: "trustedProjects") ?? [] where o[p] == nil { o[p] = ProjectAccess.always.rawValue }
    UserDefaults.standard.removeObject(forKey: "trustedProjects")
    return o
  }
  func access(for project: String) -> ProjectAccess { projectAccessOverrides[project].flatMap(ProjectAccess.init) ?? projectAccessDefault }
  func accessOverride(for project: String) -> ProjectAccess? { projectAccessOverrides[project].flatMap(ProjectAccess.init) }
  /// nil goes back to the default. Changing it closes the project if it's open.
  func setAccess(_ project: String, _ access: ProjectAccess?) {
    projectAccessOverrides[project] = access?.rawValue
    unlocks.close(project)
    let now = self.access(for: project)
    events.insert(ActivityEvent(date: Date(), service: project, method: "", path: "", process: "you", pid: getpid(), outcome: .sent, status: 0,
                                note: "\(project): Touch ID \(now == .perKey ? "follows each key's setting" : "isn't asked for in its folder " + now.span)"), at: 0)
  }
  func closeProject(_ project: String) {
    unlocks.close(project)
    events.insert(ActivityEvent(date: Date(), service: project, method: "", path: "", process: "you", pid: getpid(), outcome: .sent, status: 0,
                                note: "closed \(project); its keys ask for Touch ID again"), at: 0)
  }
  func logProjectUse(_ r: ApprovalRequest, project: String) {
    events.insert(ActivityEvent(date: Date(), service: r.service, method: r.method, path: r.path, process: r.client.displayName, pid: r.client.pid,
                                outcome: .sent, status: 0, note: "no prompt: \(project) is open for its folder"), at: 0)
  }
  func inFolder(_ cwd: String?, of project: String) -> String? {
    guard let folder = folder(for: project), let cwd else { return nil }
    return cwd == folder || cwd.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/") ? folder : nil
  }

  func saveRejected() { UserDefaults.standard.set(Array(rejected), forKey: "rejectedKeys") }
  func clearRejected(_ name: String) { if rejected.remove(name) != nil { saveRejected() } }

  /// The stored key an .env entry corresponds to: same env var name, same folder.
  func existing(for key: ImportScanner.Found) -> ServiceConfig? {
    let folder = (key.file as NSString).deletingLastPathComponent
    return services.first { $0.envVarName == key.name && $0.folder == folder }
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

  func applyUpgradeIfNeeded(_ id: UUID, service: String, context: LAContext, client: ClientProcess) {
    guard windowUpgrades.remove(id) != nil else { return }
    Task { await engine.gate.grantWindow(service: service, minutes: 15, context: context, client: client); await refreshGrants() }
  }

  // MARK: Keys

  func service(named n: String) -> ServiceConfig? { services.first { $0.name == n } }

  func summary(_ s: ServiceConfig) -> ServiceSummary { s.summary(port: port) }

  /// Saves a key after Touch ID. Returns false if the user cancelled.
  func save(_ config: ServiceConfig, secret: String) async throws -> Bool {
    guard storageSecure else { throw VaultError.invalidConfig(Self.insecureMessage) }
    try config.validate()
    let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw VaultError.invalidConfig("Paste the key first") }
    guard await authenticate("save your \(config.displayName) key") != nil else { return false }
    try keychain.setSecret(Data(trimmed.utf8), for: config.name, label: config.displayName)
    try persist(services.filter { $0.name != config.name } + [config])
    clearRejected(config.name)
    return true
  }

  /// Rule edits that change where a key can go need Touch ID too.
  func update(_ config: ServiceConfig) async throws -> Bool {
    try config.validate()
    // Anything that changes where or how the key is sent, or how often you're asked, needs Touch ID.
    if let old = service(named: config.name),
       old.upstreamHost != config.upstreamHost || old.authHeader != config.authHeader || old.authPrefix != config.authPrefix
        || old.upstreamScheme != config.upstreamScheme || old.authQueryParam != config.authQueryParam || old.basicAuth != config.basicAuth
        || old.extraHeaders != config.extraHeaders || old.placeholderAnywhere != config.placeholderAnywhere || old.approval != config.approval {
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
    guard servicesLoaded else { throw VaultError.invalidConfig("Unlock your Mac first: keydillo can't read your keys while it's locked.") }
    try keychain.save(next)
    services = next
    snapshot.value = next
  }

  // MARK: Readout (GUI only)

  /// Values for a project's keys, after Touch ID. Never reachable from the CLI, MCP or proxy.
  func readout(project: String) async -> [(ServiceConfig, String)]? {
    guard let ctx = await authenticate("show the keys for \(project)") else { return nil }
    NSApp.activate()
    return services.filter { $0.project == project }.compactMap { s in
      guard let d = try? keychain.secret(for: s.name, context: ctx) else { return nil }
      return (s, String(decoding: d, as: UTF8.self))
    }
  }

  /// One key's value for the Reveal button. Always a fresh Touch ID, never reachable from CLI, MCP or proxy.
  func reveal(_ s: ServiceConfig) async -> String? {
    guard let ctx = await authenticate("show your \(s.displayName) key") else { return nil }
    guard let d = try? keychain.secret(for: s.name, context: ctx) else { return nil }
    events.insert(ActivityEvent(date: Date(), service: s.name, method: "", path: "", process: "you", pid: getpid(),
                                outcome: .sent, status: 0, note: "key revealed in keydillo"), at: 0)
    return String(decoding: d, as: UTF8.self)
  }

  func copyConcealed(_ text: String) {
    let pb = NSPasteboard.general
    // This Mac only: keep keys off Universal Clipboard.
    pb.prepareForNewContents(with: .currentHostOnly)
    pb.setString(text, forType: .string)
    pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    let change = pb.changeCount
    DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
      if NSPasteboard.general.changeCount == change { NSPasteboard.general.clearContents() }
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
      try ControlSocket.serve { req, caller in
        await MainActor.run { AppModel.shared }.handle(req, caller: caller)
      }
    } catch {
      NSLog("keydillo: control socket failed: \(error)")
    }
  }

  func handle(_ req: ControlRequest, caller: ClientProcess = .unknown) async -> ControlResponse {
    switch req {
    case .listServices:
      return .services(services.map(summary))
    case .status:
      let rejectedLines = rejected.sorted().map { "\($0): the provider rejected this key. Ask the user to rotate it in keydillo." }
      let blocks = rejectedLines + events.filter { $0.outcome != .sent }.prefix(10).map { e in
        "\(e.date.formatted(date: .omitted, time: .shortened)) \(e.process) → \(e.service) \(e.method) \(e.path): \(e.outcome.rawValue)\(e.note.map { " (\($0))" } ?? "")"
      }
      return .status(StatusInfo(proxyRunning: proxyRunning, proxyState: proxyState, port: port, storage: storageDescription,
                                services: services.map(summary), recentBlocks: Array(blocks)))
    case .openProject(let r):
      guard servicesLoaded else { return .error("The Mac is locked, so keydillo can't open keys yet. Tell the user and retry after they unlock.") }
      let name = r.project ?? projects.first { inFolder(caller.cwd, of: $0) != nil }
      guard let name, projects.contains(name) else { return .error("No keydillo project matches \(r.project ?? "this folder"). Call list_services to see the projects.") }
      let keys = services.filter { $0.project == name }
      guard !keys.isEmpty else { return .error("\(name) has no keys yet.") }
      let access = self.access(for: name)
      let who = caller.agent != nil ? caller.friendlyName : (caller.identified ? caller.name : "a program")
      let list = keys.map(\.displayName).joined(separator: ", ")
      let ctx = LAContext(); ctx.localizedCancelTitle = "Deny"
      if access == .perKey {
        // No project window: approve each key for this caller's session only.
        guard caller.identified else { return .error("keydillo couldn't identify the caller, so it can't approve keys in advance.") }
        let reason = "let \(who) use \(name)'s keys (\(list)) for this session"
        guard (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true else { return .declined }
        for k in keys { await engine.gate.grantWindow(service: k.name, minutes: 24 * 60, context: ctx, client: caller) }
        await refreshGrants()
        return .opened(project: name, services: keys.map(\.name), span: "for this session")
      }
      guard let folder = folder(for: name) else { return .error("keydillo doesn't know \(name)'s folder yet, so it can't open it for that folder.") }
      let reason = "let programs in \((folder as NSString).abbreviatingWithTildeInPath) use \(name)'s keys (\(list)) \(access.span)"
      guard (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) == true else { return .declined }
      unlocks.open(name, access: access, folder: folder, context: ctx, keys: keys.map(\.name), keychain: keychain)
      events.insert(ActivityEvent(date: Date(), service: name, method: "", path: "", process: who, pid: caller.pid, outcome: .sent, status: 0,
                                  note: "opened \(name) \(access.span)"), at: 0)
      return .opened(project: name, services: keys.map(\.name), span: access.span)
    case .requestSecret(let r):
      guard servicesLoaded else { return .error("The Mac is locked, so keydillo can't read or add keys yet. Tell the user and retry after they unlock.") }
      guard ServiceConfig.isValidName(r.service) else { return .error("service must be lowercase letters, digits and dashes") }
      let kr = KeyRequest(service: r.service, displayName: r.displayName ?? HostCheck.displayName(r.service), host: r.host,
                          header: r.header, prefix: r.prefix ?? "",
                          envVarName: r.envVarName ?? ServiceConfig(name: r.service, upstreamHost: r.host, authHeader: r.header).envVarName,
                          project: r.project ?? "Personal",
                          // Who's asking comes from the kernel's view of the caller, not from what the request says.
                          requester: r.requester == KeyRequest.cliRequester && caller.agent == nil ? nil : (caller.agent != nil ? caller.friendlyName : (caller.identified ? caller.name : "an unidentified program")),
                          cwd: caller.cwd ?? r.cwd,
                          keyPageURL: Self.safeKeyPage(r.keyPageURL) ?? "")
      return await withCheckedContinuation { cont in
        keyRequestWaiters[kr.id] = cont
        WindowManager.shared.showKeyWindow(kr)
      }
    }
  }

  /// Key pages must be plain https links.
  static func safeKeyPage(_ s: String?) -> String? {
    guard let s, let u = URL(string: s), u.scheme == "https", let h = u.host, !h.isEmpty, u.user == nil else { return nil }
    return s
  }

  func finishKeyRequest(_ id: UUID, saved: ServiceConfig?) {
    guard let cont = keyRequestWaiters.removeValue(forKey: id) else { return }
    if let saved { let s = summary(saved); cont.resume(returning: .saved(s, envLines: s.placeholderEnvLines)) }
    else { cont.resume(returning: .declined) }
  }

  // MARK: Settings

  /// Removes keydillo from this Mac's setup. The app itself is moved to the Trash by the caller.
  func uninstall(restoreEnvFiles: Bool, deleteKeys: Bool) async -> String? {
    if restoreEnvFiles {
      let r = await ImportModel.restoreRealValues(model: self)
      if r == "Cancelled." { return "Cancelled. Nothing was removed." }
    }
    ClaudeConnector.disconnect()
    ShellIntegration.remove()
    try? FileManager.default.removeItem(at: ShellIntegration.binDir)
    try? await Self.agent.unregister()
    if deleteKeys {
      for s in services { keychain.deleteSecret(s.name) }
      try? keychain.save([])
      for a in keychain.accounts(service: ImportModel.backupService) { keychain.deleteSecret(a, service: ImportModel.backupService) }
    }
    try? FileManager.default.removeItem(at: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("keydillo"))
    if let domain = Bundle.main.bundleIdentifier { UserDefaults.standard.removePersistentDomain(forName: domain) }
    return nil
  }

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
    case .dataProtection: return servicesLoaded ? "Private Keychain group, Touch ID on every read"
      : "Private Keychain group. Keys can't be read until the Mac is unlocked; keydillo loads them as soon as it is"
    case .legacy: return "NOT SECURE: no private Keychain group in this build, so keydillo won't store keys"
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
    // A project opened for its folder: callers working inside that folder don't get a prompt.
    let open = await MainActor.run { () -> (project: String, folder: String, access: ProjectAccess, names: String)? in
      guard let m = model, let svc = m.service(named: request.service) else { return nil }
      let access = m.access(for: svc.project)
      guard access != .perKey, let folder = m.inFolder(request.client.cwd, of: svc.project) else { return nil }
      return (svc.project, folder, access, m.services.filter { $0.project == svc.project }.map(\.displayName).joined(separator: ", "))
    }
    if let open {
      if let u = model?.unlocks.valid(open.project) {
        await MainActor.run { model?.logProjectUse(request, project: open.project) }
        return .approved(u.context)
      }
      if Self.screenLocked { return .unavailable("the Mac is locked and \(open.project) isn't open. The user can open it with one Touch ID before leaving the Mac") }
      let ctx = LAContext()
      ctx.localizedCancelTitle = "Deny"
      let reason = "let programs in \((open.folder as NSString).abbreviatingWithTildeInPath) use \(open.project)'s keys (\(open.names)) \(open.access.span)"
      do {
        guard try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) else { return .denied }
        let keys = await MainActor.run { model?.services.filter { $0.project == open.project }.map(\.name) ?? [] }
        if let m = model { m.unlocks.open(open.project, access: open.access, folder: open.folder, context: ctx, keys: keys, keychain: m.keychain) }
        return .approved(ctx)
      } catch { return .denied }
    }
    if Self.screenLocked { return .unavailable("the Mac is locked") }
    let ctx = LAContext()
    ctx.localizedCancelTitle = "Deny"
    let project = await MainActor.run { model?.service(named: request.service)?.project ?? "" }
    let pending = PendingApproval(request: request, context: ctx, project: project)
    await MainActor.run { model?.showPending(pending) }
    defer { Task { @MainActor in model?.clearPending(pending.id) } }
    do {
      guard try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: request.reason) else { return .denied }
      await MainActor.run { model?.applyUpgradeIfNeeded(pending.id, service: request.service, context: ctx, client: request.client) }
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

/// Thread-safe Bool read by the proxy off the main thread.
final class FlagBox: @unchecked Sendable {
  private let lock = NSLock()
  private var v = false
  var value: Bool {
    get { lock.lock(); defer { lock.unlock() }; return v }
    set { lock.lock(); v = newValue; lock.unlock() }
  }
}
