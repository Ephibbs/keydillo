import Foundation
import SwiftUI
import AppKit
import LocalAuthentication
import ServiceManagement
import PhoneLink
import VaultCore

enum DefaultApproval: String, CaseIterable {
  case eachRequest, session
  var mode: ApprovalMode {
    switch self {
    case .eachRequest: return .eachRequest
    case .session: return .perProcess
    }
  }
  var label: String {
    switch self {
    case .eachRequest: return "Every time"
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
    case .window: return .session
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
  /// "Once per app": approving this also trusts this app from now on.
  var trustApp: String? = nil
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
  @ObservationIgnored private var secretReader: ProjectAwareSecrets!
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
    refreshSnapshot()
    if !servicesLoaded {
      loadAccessSettings()
      servicesLoaded = true
      if !Self.devHarness && !UserDefaults.standard.bool(forKey: "repairedPlaceholders1") {
        Task { @MainActor in
          try? await Task.sleep(for: .seconds(2))
          let r = await self.repairPlaceholderValues()
          if r != nil && r != "Not checked (Touch ID cancelled)." { UserDefaults.standard.set(true, forKey: "repairedPlaceholders1") }
          if let r { try? r.write(to: FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("keydillo/repair-report.txt"), atomically: true, encoding: .utf8) }
        }
      }
      foldIntoGeneral()
      ImportModel.migrateFileBackups(model: self)
      ImportModel.migrateBaseURLs(model: self)
      if !Self.devHarness { ImportModel.randomizeLaunchPlaceholders(model: self) }
    }
    return true
  }

  /// Keys whose project has no lasting folder (the old "Personal" group, a scratch folder, a deleted folder) belong
  /// in General, where any folder can use them. Logged so the move is visible.
  func foldIntoGeneral() {
    let (next, folded) = GeneralKeys.fold(services, userNamed: Set(extraProjects))
    guard !folded.isEmpty, (try? persist(next)) != nil else { return }
    // The folded projects' own Touch ID settings go with them; General keeps its own.
    if folded.contains(where: { projectAccessOverrides[$0] != nil }) {
      for f in folded { projectAccessOverrides[f] = nil }
      try? saveAccessSettings()
    }
    events.insert(ActivityEvent(date: Date(), service: GeneralKeys.project, method: "", path: "", process: "keydillo", pid: getpid(), outcome: .sent, status: 0,
                                note: "moved \(folded.joined(separator: ", ")) to General: no lasting project folder"), at: 0)
  }

  static let devHarness = ProcessInfo.processInfo.environment["KEYDILLO_DEV"] == "1"
    && (UserDefaults.standard.string(forKey: "kdPreview") != nil || UserDefaults.standard.string(forKey: "kdSelfTest") != nil)

  private init() {
    let approver = ModelApprover(model: self)
    let secrets = ProjectAwareSecrets(keychain: keychain, store: unlocks, projectOf: { [snapshot] name in snapshot.value.first { $0.name == name }?.project })
    secretReader = secrets
    engine = ProxyEngine(services: { [snapshot] in snapshot.value }, secrets: secrets, approver: approver)
    unlocks.onChange = { [weak self] in self?.refreshOpenProjects() }
    Task { @MainActor in   // drop expired projects from the menu bar
      while true { try? await Task.sleep(for: .seconds(30)); self.refreshOpenProjects() }
    }
    engine.notReady = { [weak self] in
      guard let self else { return nil }
      return self.loadedFlag.value ? nil : "keydillo can't read keys until the Mac is unlocked"
    }
    engine.onHostAdded = { [weak self] name, host in
      Task { @MainActor in self?.addHost(host, to: name) }
    }
    engine.onKindAdded = { [weak self] name, kind in
      Task { @MainActor in self?.addKind(kind, to: name) }
    }
    engine.onEvent = { [weak self] e in
      Task { @MainActor in
        guard let self else { return }
        self.events.insert(e, at: 0)
        if self.events.count > 1000 { self.events.removeLast() }
        self.noteAgent(e.process)
        if e.note?.hasPrefix("key rejected") == true { self.rejected.insert(e.service); self.saveRejected() }
        await self.refreshGrants()
      }
    }
    if !loadServices() {
      Task { @MainActor in
        while !self.loadServices() { try? await Task.sleep(for: .seconds(3)) }
      }
    }
    // Development previews and UI self-tests run next to the real app: they must not take its port or control
    // socket, or touch the user's files.
    guard !Self.devHarness else { return }
    try? FileManager.default.removeItem(at: Self.quitMarker)
    startProxy()
    startControl()
    ImportModel.addHeadersToTrackedFiles(port: port)
    ImportModel.migratePlaceholders()
    ClaudeConnector.refreshSkillIfInstalled()
    AgentTools.refresh()
    ShellIntegration.refreshLinks()
    Task { @MainActor in
      while true {
        await self.checkRealKeys()
        try? await Task.sleep(for: .seconds(60))
      }
    }
  }

  // MARK: Project access (one Touch ID opens a project's keys for programs in its folder)

  @ObservationIgnored let unlocks = ProjectUnlockStore()
  /// Projects open right now, for the menu bar. Refreshed when one opens, closes or expires.
  private(set) var openProjects: [(project: String, unlock: ProjectUnlockStore.Unlock)] = []
  func refreshOpenProjects() { openProjects = unlocks.list() }

  /// What projects use unless set on their own page. Ships as "each key's own setting".
  /// Both settings live in the private Keychain group, not in preferences, so no other program can switch them,
  /// and turning "ask once per project" on needs Touch ID.
  private(set) var projectAccessDefault: ProjectAccess = .perKey
  private(set) var projectAccessOverrides: [String: String] = [:]

  struct AccessSettings: Codable { var defaultAccess: String; var overrides: [String: String] }

  // MARK: Trusted apps

  /// Kept in the private Keychain group like the other access settings, so no other program can change it.
  struct TrustSettings: Codable { var agents: [String]; var perApp: Bool? }
  /// "Once per app": the first request from a verified AI app asks one Touch ID that trusts that app.
  private(set) var askOncePerApp = false { didSet { Self.perAppBox.value = askOncePerApp ? ["on"] : [] } }
  /// AI apps (by verified name, e.g. "Claude Code") that use keys without asking. Only apps whose code signature
  /// keydillo checks can be listed, so a program can't get in by naming itself "claude".
  private(set) var trustedAgents: [String] = [] { didSet { Self.trustedBox.value = trustedAgents } }
  /// Keys are stored without the Keychain's Touch ID lock while any app is trusted.
  var neverAsk: Bool { !trustedAgents.isEmpty }
  /// Read by the proxy off the main thread.
  nonisolated static let trustedBox = StringsBox()
  static let trustableAgents = ProcessLookup.verifiedAgentNames

  /// A caller started by a trusted app (verified by code signature).
  nonisolated static func isTrusted(_ c: ClientProcess) -> Bool {
    TrustRule.allows(c, trusted: trustedBox.value)
  }

  func loadTrust() {
    if let d = keychain.setting("trustedApps"), !d.isEmpty, let s = try? JSONDecoder().decode(TrustSettings.self, from: d) {
      trustedAgents = s.agents.filter { Self.trustableAgents.contains($0) }
      askOncePerApp = s.perApp ?? !trustedAgents.isEmpty
    }
    keychain.requirePresence = !neverAsk
  }

  /// Trusting an app takes Touch ID. The first one also saves every key again without the Keychain's Touch ID lock
  /// (keydillo then asks for Touch ID itself for everyone else). Removing the last one puts the lock back.
  /// Still Touch ID even for trusted apps: a new key, a new site, launch-time values, and showing a key.
  /// Returns an error message, or nil when done or cancelled.
  func setTrusted(_ agent: String, _ on: Bool, context: LAContext? = nil) async -> String? {
    guard Self.trustableAgents.contains(agent), on != trustedAgents.contains(agent) else { return nil }
    guard servicesLoaded else { return "Unlock your Mac first." }
    let next = on ? trustedAgents + [agent] : trustedAgents.filter { $0 != agent }
    let services = [KeychainBackend.secretService, ImportModel.backupService]
    if on {
      var ctx = context
      if ctx == nil { ctx = await authenticate("let \(agent) use your keys without asking (new keys, new sites and showing a key still ask)") }
      guard let ctx else { return nil }
      do {
        if !neverAsk { for svc in services { try keychain.relock(service: svc, presence: false, context: ctx) } }
        try keychain.setSetting("trustedApps", JSONEncoder().encode(TrustSettings(agents: next, perApp: true)))
      } catch {
        if !neverAsk { for svc in services { _ = try? keychain.relock(service: svc, presence: true, context: ctx) } }
        return "Couldn't change how your keys are stored, so nothing changed (\(error.localizedDescription))."
      }
    } else {
      do {
        if next.isEmpty { for svc in services { try keychain.relock(service: svc, presence: true, context: nil) } }
        try keychain.setSetting("trustedApps", JSONEncoder().encode(TrustSettings(agents: next, perApp: askOncePerApp)))
      } catch {
        return "Couldn't put the Touch ID lock back on every key (\(error.localizedDescription)). Try again."
      }
    }
    trustedAgents = next
    if on { askOncePerApp = true }
    keychain.requirePresence = !neverAsk
    events.insert(ActivityEvent(date: Date(), service: "Touch ID", method: "", path: "", process: "you", pid: getpid(), outcome: .sent, status: 0,
                                note: on ? "trusted \(agent): it uses keys without asking" : "stopped trusting \(agent)"), at: 0)
    Task { await engine.gate.revokeAll(); await refreshGrants() }
    return nil
  }

  /// The Settings menu's choice. "Once per app" is the per-session default plus trusting each verified AI app once.
  enum AskMode: String, CaseIterable, Identifiable {
    case everyTime, perSession, perApp, perProject
    var id: String { rawValue }
    var label: String {
      switch self {
      case .everyTime: return "Every time"
      case .perSession: return "Once per session"
      case .perApp: return "Once per app"
      case .perProject: return "Once per project"
      }
    }
    var access: ProjectAccess { self == .everyTime ? .everyTime : self == .perProject ? .always : .perKey }
  }
  var askMode: AskMode {
    if askOncePerApp { return .perApp }
    switch projectAccessDefault { case .everyTime: return .everyTime; case .perKey: return .perSession; case .always: return .perProject }
  }

  /// Turning on "Once per app" takes Touch ID; leaving it stops trusting every app.
  func setAskMode(_ m: AskMode) async -> String? {
    if m == askMode { return nil }
    if m == .perApp {
      guard servicesLoaded else { return "Unlock your Mac first." }
      guard await authenticate("trust each AI app after one Touch ID") != nil else { return nil }
      do { try keychain.setSetting("trustedApps", JSONEncoder().encode(TrustSettings(agents: trustedAgents, perApp: true))) }
      catch { return "Couldn't save that (\(error.localizedDescription))." }
      askOncePerApp = true
      if projectAccessDefault != .perKey { projectAccessDefault = .perKey; try? saveAccessSettings(); refreshSnapshot() }
      Task { await engine.gate.revokeAll(); await refreshGrants() }
      return nil
    }
    if askOncePerApp {
      for a in trustedAgents { if let err = await setTrusted(a, false) { return err } }
      do { try keychain.setSetting("trustedApps", JSONEncoder().encode(TrustSettings(agents: [], perApp: false))) }
      catch { return "Couldn't save that (\(error.localizedDescription))." }
      askOncePerApp = false
    }
    if m.access != projectAccessDefault { _ = await setDefaultAccess(m.access) }
    return nil
  }

  /// "Once per app": a verified AI app that isn't trusted yet, whose next approval trusts it.
  nonisolated static let perAppBox = StringsBox()
  nonisolated static func trustCandidate(_ c: ClientProcess) -> String? {
    guard !perAppBox.value.isEmpty, c.identified, c.agentVerified, let name = ProcessLookup.verifiedName(c.agent),
          ProcessLookup.verifiedAgentNames.contains(name), !trustedBox.value.contains(name) else { return nil }
    return name
  }

  /// Previews only: shows Claude Code as trusted without touching the Keychain.
  func previewTrusted() { if Self.devHarness { trustedAgents = ["Claude Code"]; askOncePerApp = true; Self.trustedBox.value = []; Self.perAppBox.value = [] } }

  /// A change that would send a key to a site it hasn't been sent to. Always Touch ID, even in Never ask mode.
  func addsSite(_ r: ChangeRequest) -> Bool {
    guard r.kind == .auth, let h = r.host?.lowercased().trimmingCharacters(in: .whitespaces), !h.isEmpty else { return false }
    return !(r.service.flatMap(service(named:))?.allHosts.contains(h) ?? false)
  }

  func logNoPrompt(_ r: ApprovalRequest, note: String) {
    events.insert(ActivityEvent(date: Date(), service: r.service, method: r.method, path: r.path, process: r.client.displayName, pid: r.client.pid,
                                outcome: .sent, status: 0, note: note), at: 0)
  }

  func loadAccessSettings() {
    loadTrust()
    // Older builds kept these in preferences, where any program could change them: drop them, never trust them.
    for k in ["projectAccessDefault", "projectAccess", "trustedProjects"] { UserDefaults.standard.removeObject(forKey: k) }
    let oldKeyDefault = UserDefaults.standard.string(forKey: "defaultApproval")
    UserDefaults.standard.removeObject(forKey: "defaultApproval")
    if let d = keychain.setting("projectAccess"), !d.isEmpty, let s = try? JSONDecoder().decode(AccessSettings.self, from: d) {
      projectAccessDefault = ProjectAccess(rawValue: s.defaultAccess) ?? .perKey
      projectAccessOverrides = s.overrides
    }
    // Earlier builds had a separate "Ask for Touch ID (new keys)" choice; "every time" carries over, 15 minutes becomes once per session.
    if oldKeyDefault == "eachRequest" && projectAccessDefault == .perKey { projectAccessDefault = .everyTime; try? saveAccessSettings() }
  }

  private func saveAccessSettings() throws {
    let d = try JSONEncoder().encode(AccessSettings(defaultAccess: projectAccessDefault.rawValue, overrides: projectAccessOverrides))
    try keychain.setSetting("projectAccess", d)
  }

  /// Changes the default for all projects. Turning on "ask once per project" needs Touch ID.
  @discardableResult func setDefaultAccess(_ a: ProjectAccess) async -> Bool {
    if a.rank > projectAccessDefault.rank {
      let what = a == .always ? "stop asking for Touch ID in every project's folder" : "ask for Touch ID only once per session"
      guard await authenticate(what) != nil else { return false }
    }
    let old = projectAccessDefault
    projectAccessDefault = a
    do { try saveAccessSettings() } catch { projectAccessDefault = old; return false }
    unlocks.closeAll()
    refreshSnapshot()
    Task { await engine.gate.revokeAll(); await refreshGrants() }
    return true
  }
  func access(for project: String) -> ProjectAccess { projectAccessOverrides[project].flatMap(ProjectAccess.init) ?? projectAccessDefault }
  func accessOverride(for project: String) -> ProjectAccess? { projectAccessOverrides[project].flatMap(ProjectAccess.init) }
  /// nil goes back to the default. Changing it closes the project if it's open. Turning on "ask once per project" needs Touch ID.
  @discardableResult func setAccess(_ project: String, _ access: ProjectAccess?) async -> Bool {
    let next = access ?? projectAccessDefault
    if next.rank > self.access(for: project).rank {
      let what = next == .always ? "stop asking for Touch ID for programs in \(project)'s folder" : "ask for Touch ID once per session for \(project)"
      guard await authenticate(what) != nil else { return false }
    }
    let old = projectAccessOverrides
    projectAccessOverrides[project] = access?.rawValue
    do { try saveAccessSettings() } catch { projectAccessOverrides = old; return false }
    unlocks.close(project)
    let now = self.access(for: project)
    events.insert(ActivityEvent(date: Date(), service: project, method: "", path: "", process: "you", pid: getpid(), outcome: .sent, status: 0,
                                note: "\(project): Touch ID \(now.label.lowercased())"), at: 0)
    refreshSnapshot()
    Task { await engine.gate.revokeAll(); await refreshGrants() }
    return true
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
    // Too broad to stand for one project: everything would count as "in the folder".
    let f = (folder as NSString).standardizingPath
    if f == "/" || f == NSHomeDirectory() || f == NSHomeDirectory() + "/Desktop" || f == NSHomeDirectory() + "/Documents" { return nil }
    // Only a folder that really is a keydillo project: you chose it in keydillo, or it holds an env file keydillo rewrote.
    let names = (try? FileManager.default.contentsOfDirectory(atPath: f)) ?? []
    let chosen = services.contains { $0.project == project && $0.folderChosen == true }
    guard chosen || names.contains(where: { ImportScanner.isEnvFile($0)
      && ((try? String(contentsOfFile: f + "/" + $0, encoding: .utf8))?.contains(ImportScanner.headerStart) ?? false) }) else { return nil }
    return cwd == folder || cwd.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/") ? folder : nil
  }

  /// Finds stored keys whose value is a keydillo placeholder (an earlier import could store one) and restores the real
  /// value from keydillo's own .env backups. Reports key names only. Needs one Touch ID.
  func repairPlaceholderValues() async -> String? {
    guard servicesLoaded, !services.isEmpty else { return nil }
    guard let ctx = await authenticate("check your keys for a problem from an earlier keydillo import, and repair them") else { return "Not checked (Touch ID cancelled)." }
    let bad = services.filter { s in
      guard let d = try? keychain.secret(for: s.name, context: ctx) else { return false }
      return Placeholder.isPlaceholder(String(decoding: d, as: UTF8.self))
    }
    guard !bad.isEmpty else { return "All \(services.count) keys are fine." }
    // Backups, newest first; take the newest real (non-placeholder) value for the key's env var in its folder.
    let accounts = keychain.accounts(service: ImportModel.backupService, context: ctx)
    let backups: [ImportModel.Backup] = accounts.compactMap { a in
      guard let d = try? keychain.secret(for: a, context: ctx, service: ImportModel.backupService) else { return nil }
      return try? JSONDecoder().decode(ImportModel.Backup.self, from: d)
    }.sorted { $0.date > $1.date }
    var fixed: [String] = [], lost: [String] = []
    for s in bad {
      var value: String?
      search: for b in backups {
        for f in b.files where s.folder == nil || (f.path as NSString).deletingLastPathComponent == s.folder {
          if let k = ImportScanner.parse(f.text, file: f.path).first(where: { $0.name == s.envVarName && !Placeholder.isPlaceholder($0.value) }) {
            value = k.value; break search
          }
        }
      }
      if let v = value, (try? keychain.setSecret(Data(v.utf8), for: s.name, label: s.displayName)) != nil { fixed.append(s.name) } else { lost.append(s.name) }
    }
    unlocks.closeAll()
    var out = fixed.isEmpty ? "" : "Repaired: \(fixed.joined(separator: ", ")). "
    if !lost.isEmpty { out += "No real value found for: \(lost.joined(separator: ", ")); replace these in keydillo." }
    out += " (Checked \(backups.count) of \(accounts.count) import backups" + (backups.isEmpty ? "" : ", oldest \(backups.last!.date.formatted(date: .abbreviated, time: .shortened))") + ".)"
    events.insert(ActivityEvent(date: Date(), service: "keydillo", method: "", path: "", process: "keydillo", pid: getpid(), outcome: .sent, status: 0, note: out), at: 0)
    return out
  }

  /// Real secrets sitting in each project's env files (put back, left unticked, or written over a placeholder),
  /// minus ones the user chose to keep in the file. Shown as a warning on the project.
  var exposed: [String: [(file: String, name: String)]] = [:]
  /// Secret keys under browser prefixes (NEXT_PUBLIC_, VITE_, …) in each project's env files.
  var inFrontend: [String: [(file: String, name: String)]] = [:]
  var keptInFile: Set<String> {
    get { Set(UserDefaults.standard.stringArray(forKey: "keptInFile") ?? []) }
    set { UserDefaults.standard.set(Array(newValue), forKey: "keptInFile"); Task { await checkRealKeys() } }
  }

  /// Every file in every project that still holds real keys, secured in one import (one Touch ID).
  func secureAll() async -> String? {
    let files = realKeys.files
    guard !files.isEmpty else { return nil }
    let r = await ImportModel.secure(model: self, files: files)
    await checkRealKeys()
    return r
  }

  /// One count for every place that warns about real keys: project .env files holding real keys,
  /// plus files where real values replaced keydillo's placeholders.
  var realKeys: (projects: [String], files: [String]) {
    var files = Set(exposed.values.flatMap { $0.map(\.file) }).union(realKeyFiles)
    var projects = Set(exposed.keys)
    for f in realKeyFiles {
      let dir = (f as NSString).deletingLastPathComponent
      projects.insert(services.first { $0.folder == dir }?.project ?? (dir as NSString).lastPathComponent)
    }
    files = files.filter { !$0.isEmpty }
    return (projects.sorted(), files.sorted())
  }
  var realKeysText: String {
    let r = realKeys
    return "Real keys in \(r.projects.count) project\(r.projects.count == 1 ? "" : "s") (\(r.files.count) file\(r.files.count == 1 ? "" : "s"))"
  }

  func checkExposed() async {
    var folders: [String: String] = [:]   // folder -> project
    for s in services { if let f = s.folder, f != NSHomeDirectory() { folders[f] = s.project } }
    let kept = keptInFile
    let (found, frontend) = await Task.detached { () -> ([String: [(file: String, name: String)]], [String: [(file: String, name: String)]]) in
      var out: [String: [(file: String, name: String)]] = [:]
      var front: [String: [(file: String, name: String)]] = [:]
      for (folder, project) in folders {
        // The project folder and two levels below it (monorepos keep .env files in apps/web and the like).
        for path in ImportScanner.envFiles(in: folder, maxDepth: 2) {
          // A subfolder that is another project's folder is counted under that project.
          let dir = (path as NSString).deletingLastPathComponent
          if dir != folder, folders[dir] != nil { continue }
          guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
          for k in ImportScanner.parse(text, file: path) {
            if k.inFrontend { front[project, default: []].append((path, k.name)); continue }
            if !k.isPublic && k.localOnly == nil && !kept.contains(path + "#" + k.name) { out[project, default: []].append((path, k.name)) }
          }
        }
      }
      return (out, front)
    }.value
    exposed = found
    inFrontend = frontend
  }

  /// Re-checks tracked .env files for keys keydillo manages that hold real values again.
  func checkRealKeys() async {
    await checkExposed()
    let paths = ImportModel.trackedFiles
    var managed: [String: Set<String>] = [:]
    // Dev values are meant to sit in .env in plain text, so they never count as real keys coming back.
    for s in services where s.devValue == nil && s.database != true { if let f = s.folder { managed[f, default: []].insert(s.envVarName) } }
    let found = await Task.detached { ImportModel.filesWithRealKeys(paths, managed: managed) }.value
    if found != realKeyFiles { realKeyFiles = found }
  }

  /// Set when the user quits keydillo from the menu: `kd` then refuses instead of reopening it.
  static var quitMarker: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("keydillo/quit-by-user")
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
    startDatabaseProxy()
  }

  /// keydillo's local Postgres endpoint, one port above the HTTP proxy.
  var databasePort: UInt16 { port &+ 1 }
  var databaseProxy: PostgresProxy?

  /// Marks a launch-time Postgres key as connecting through keydillo, and swaps its placeholder in the project's
  /// env files for the local address (only lines holding this key's placeholder).
  func switchToDatabaseProxy(_ svc: ServiceConfig, local: String) {
    var s = svc; s.database = true
    try? addImported([s])
    var files = Set(ImportModel.trackedFiles)
    if let f = svc.folder { for p in ImportScanner.envFiles(in: f, maxDepth: 2) { files.insert(p) } }
    for path in files {
      guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
      var changed = false
      let lines = text.components(separatedBy: "\n").map { line -> String in
        guard let eq = line.firstIndex(of: "="), Placeholder.service(in: String(line[line.index(after: eq)...])) == svc.name else { return line }
        changed = true
        return String(line[...eq]) + local
      }
      if changed { try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8) }
    }
  }

  func startDatabaseProxy() {
    databaseProxy?.stop()
    guard let engine else { return }
    let db = PostgresProxy(port: databasePort) { name, database, caller in
      await engine.databaseLogin(name, database: database, client: caller)
    }
    do { try db.start(); databaseProxy = db } catch { databaseProxy = nil }
  }

  func movePort(to p: UInt16) {
    server?.stop()
    port = p
    startProxy()
  }


  var proxyRunning: Bool { proxyState == "ready" && !paused }

  func refreshGrants() async { activeGrants = await engine.gate.activeGrants() }

  func endAccess(session: String) async { await engine.gate.revoke(session: session); await refreshGrants() }

  /// `kd` runs whose command left programs running in the background (pm2, nohup, tmux), keyed by kd's proxy pid.
  var backgroundRuns: [Int32: BackgroundRun] = [:]

  /// Drops background runs whose proxy process has gone.
  func pruneBackgroundRuns() {
    for (pid, r) in backgroundRuns where ProcessLookup.startTime(of: pid) != r.startTime { backgroundRuns[pid] = nil }
  }

  /// Stops a background run's proxy, so the programs it served lose their keys.
  func endBackgroundRun(_ pid: Int32) {
    guard let r = backgroundRuns[pid] else { return }
    // Only signal keydillo's own proxy process, and only the one that registered (not a reused pid).
    if ProcessLookup.startTime(of: pid) == r.startTime, ProcessLookup.isKeydilloBinary(pid) { kill(pid, SIGTERM) }
    backgroundRuns[pid] = nil
    events.insert(ActivityEvent(date: Date(), service: "keydillo", method: "", path: "", process: "you", pid: getpid(), outcome: .sent, status: 0,
                                note: "ended background access for \(r.programs.joined(separator: ", "))"), at: 0)
  }

  func endAllAccess() async {
    for pid in backgroundRuns.keys { endBackgroundRun(pid) }
    await engine.gate.revokeAll()
    unlocks.closeAll()
    await refreshGrants(); refreshOpenProjects()
    events.insert(ActivityEvent(date: Date(), service: "keydillo", method: "", path: "", process: "you", pid: getpid(), outcome: .sent, status: 0,
                                note: "ended all access; every key asks again"), at: 0)
  }

  func endGrant(_ service: String) {
    Task { await engine.gate.revokeAll(service: service); await refreshGrants() }
  }

  // MARK: Approvals (driven by the proxy)

  func showPending(_ p: PendingApproval) {
    pending.append(p); StatusItem.shared?.flash()
    WindowManager.shared.showApprovalCard(p)
  }
  func clearPending(_ id: UUID) {
    pending.removeAll { $0.id == id }
    WindowManager.shared.close("approval-\(id)")
  }

  /// Popover "Deny": cancels the Touch ID prompt.
  func deny(_ p: PendingApproval) { p.context.invalidate(); clearPending(p.id) }

  /// Popover "15 min": the next Touch ID success also opens a 15-minute window.
  var windowUpgrades: Set<UUID> = []
  func allowWindow(_ p: PendingApproval) { windowUpgrades.insert(p.id) }

  /// "For this session" picked on the phone: no more prompts for this key from this program session.
  func grantFromPhone(service: String, minutes: Int, client: ClientProcess) async {
    await engine.gate.grantWindow(service: service, minutes: minutes, context: nil, client: client)
    await refreshGrants()
  }

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
    try saveApproved(config, secret: trimmed)
    return true
  }

  /// Stores a key the user already approved with Touch ID (the browser tool's captured keys ask in the broker).
  func saveApproved(_ config: ServiceConfig, secret: String) throws {
    guard storageSecure else { throw VaultError.invalidConfig(Self.insecureMessage) }
    try config.validate()
    let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw VaultError.invalidConfig("empty key") }
    try keychain.setSecret(Data(trimmed.utf8), for: config.name, label: config.displayName)
    if PhoneApprovals.shared.ready, !config.isLaunchTime { try? PhoneApprovals.shared.storeCopy(config.name, Data(trimmed.utf8)) }
    // A rotated key must not keep using the old value held in memory for an open project.
    if let old = service(named: config.name) { unlocks.close(old.project) }
    unlocks.close(config.project)
    try persist(services.filter { $0.name != config.name } + [config])
    clearRejected(config.name)
  }

  /// Rule edits that change where a key can go need Touch ID too.
  func update(_ config: ServiceConfig) async throws -> Bool {
    try config.validate()
    // Approved kinds of request change only through the proxy (after Touch ID) and Remove, never from an open editor.
    var config = config
    config.knownPaths = service(named: config.name)?.knownPaths
    if service(named: config.name)?.askNewPaths == true && config.askNewPaths != true {
      guard await authenticate("stop asking before new kinds of requests with your \(config.displayName) key") != nil else { return false }
    }
    // Anything that changes where or how the key is sent, or how often you're asked, needs Touch ID.
    if let old = service(named: config.name),
       old.upstreamHost != config.upstreamHost || old.authHeader != config.authHeader || old.authPrefix != config.authPrefix
        || old.upstreamScheme != config.upstreamScheme || old.authQueryParam != config.authQueryParam || old.basicAuth != config.basicAuth
        || old.extraHeaders != config.extraHeaders || old.placeholderAnywhere != config.placeholderAnywhere || old.approval != config.approval
        || !Set(config.allHosts).isSubset(of: Set(old.allHosts)) {
      guard await authenticate("send your \(config.displayName) key to \(config.upstreamHost)") != nil else { return false }
    } else if let old = service(named: config.name), old.project != config.project {
      // Another project's folder settings (or General's any-folder use) would apply to this key.
      guard await authenticate("move your \(config.displayName) key from \(old.project) to \(config.project)") != nil else { return false }
    }
    if config.isGeneral { config.folder = nil; config.folderChosen = nil }
    try persist(services.map { $0.name == config.name ? config : $0 })
    Task { await engine.gate.revokeAll(service: config.name); await refreshGrants() }
    return true
  }

  /// Called only after the user approved this kind of request with Touch ID (from the proxy).
  func addKind(_ kind: String, to name: String) {
    guard var s = service(named: name), !(s.knownPaths ?? []).contains(kind) else { return }
    s.knownPaths = (s.knownPaths ?? []) + [kind]
    try? persist(services.map { $0.name == name ? s : $0 })
  }

  /// Forgetting a kind of request only makes keydillo ask again, so it needs no Touch ID.
  func removeKind(_ kind: String, from name: String) {
    guard var s = service(named: name) else { return }
    s.knownPaths = (s.knownPaths ?? []).filter { $0 != kind }
    try? persist(services.map { $0.name == name ? s : $0 })
  }

  /// Called only after the user approved this host with Touch ID (from the proxy).
  func addHost(_ host: String, to name: String) {
    guard var s = service(named: name), !s.allHosts.contains(host) else { return }
    if s.upstreamHost.isEmpty { s.upstreamHost = host } else { s.extraHosts = (s.extraHosts ?? []) + [host] }
    try? persist(services.map { $0.name == name ? s : $0 })
  }

  /// Sets (or changes) a project's folder from the window. Same rules as a requested move; needs Touch ID.
  func setFolder(_ path: String, for project: String) async -> String? {
    let new = (path as NSString).standardizingPath
    if let why = ProjectFolders.problem(old: folder(for: project) ?? "", new: new) { return why }
    guard await authenticate("set \(project)'s folder to \((new as NSString).abbreviatingWithTildeInPath)") != nil else { return nil }
    do { try persist(services.map { var c = $0; if c.project == project { c.folder = new; c.folderChosen = true }; return c }) } catch { return error.localizedDescription }
    unlocks.close(project)
    return nil
  }

  /// Narrowing where a key can go needs no Touch ID.
  func removeHost(_ host: String, from name: String) {
    guard var s = service(named: name) else { return }
    s.extraHosts = (s.extraHosts ?? []).filter { $0.lowercased() != host.lowercased() }
    if s.extraHosts?.isEmpty == true { s.extraHosts = nil }
    try? persist(services.map { $0.name == name ? s : $0 })
    Task { await engine.gate.revokeAll(service: name); await refreshGrants() }
  }

  func delete(_ name: String) {
    if let s = service(named: name) { unlocks.close(s.project) }
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
    refreshSnapshot()
  }

  /// What the proxy sees: each key asks as its project's "Ask for Touch ID" setting says.
  func refreshSnapshot() {
    snapshot.value = services.map { var s = $0; s.approval = access(for: s.project).keyMode; return s }
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
    // The Touch ID dialog belongs to another process. When it closes, macOS may hand focus to the previous app and
    // leave keydillo's window behind it, which looks like the window closed. Bring that window back explicitly.
    let window = NSApp.keyWindow ?? NSApp.windows.first { $0.isVisible && $0.canBecomeKey }
    defer { Self.restoreFront(window) }
    do { return try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) ? ctx : nil }
    catch { return nil }
  }

  static func restoreFront(_ window: NSWindow?) {
    guard let window else { return }
    NSApp.activate(ignoringOtherApps: true)
    if window.isMiniaturized { window.deminiaturize(nil) }
    window.makeKeyAndOrderFront(nil)
    window.orderFrontRegardless()
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

  /// AI tools seen using keydillo (other than Claude Code, whose setup is checked directly), with when they were last seen.
  /// Shown in the menu bar as connected.
  var agentsSeen: [String: Date] = (UserDefaults.standard.dictionary(forKey: "agentsSeen") as? [String: Date]) ?? [:]

  func noteAgent(_ who: String) {
    let w = who.lowercased()
    guard let name = [("cursor", "Cursor"), ("codex", "Codex"), ("windsurf", "Windsurf"), ("gemini", "Gemini CLI"), ("opencode", "OpenCode"),
                      ("aider", "Aider"), ("goose", "Goose")].first(where: { w.contains($0.0) })?.1 else { return }
    agentsSeen[name] = Date()
    UserDefaults.standard.set(agentsSeen, forKey: "agentsSeen")
  }

  func handle(_ req: ControlRequest, caller: ClientProcess = .unknown) async -> ControlResponse {
    if let agent = caller.agent { noteAgent(agent) }
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
        // No project window: approve the keys for this caller's session only. Keys set to ask every time keep asking.
        guard caller.identified else { return .error("keydillo couldn't identify the caller, so it can't approve keys in advance.") }
        let grouped = keys.filter { if case .eachRequest = $0.approval { return false }; return true }
        let skipped = keys.filter { if case .eachRequest = $0.approval { return true }; return false }
        guard !grouped.isEmpty else { return .error("Every key in \(name) is set to ask each time, so there's nothing to approve in advance.") }
        let reason = "let \(who) use \(name)'s keys (\(grouped.map(\.displayName).joined(separator: ", "))) until this \(who) session ends"
        guard (try? await touchID(ctx, reason, for: caller)) == true else { return .declined }
        for k in grouped { await engine.gate.grantWindow(service: k.name, minutes: 12 * 60, context: ctx, client: caller) }
        await refreshGrants()
        let note = skipped.isEmpty ? "" : " (\(skipped.map(\.name).joined(separator: ", ")) still ask every time)"
        return .opened(project: name, services: grouped.map(\.name), span: "for this session" + note)
      }
      guard let folder = folder(for: name) else { return .error("keydillo doesn't know \(name)'s folder yet, so it can't open it for that folder.") }
      let reason = "let programs in \((folder as NSString).abbreviatingWithTildeInPath) use \(name)'s keys (\(list)) \(access.span)"
      guard (try? await touchID(ctx, reason, for: caller)) == true else { return .declined }
      unlocks.open(name, access: access, folder: folder, context: ctx, keys: keys.map(\.name), keychain: keychain)
      events.insert(ActivityEvent(date: Date(), service: name, method: "", path: "", process: who, pid: caller.pid, outcome: .sent, status: 0,
                                  note: "opened \(name) \(access.span)"), at: 0)
      return .opened(project: name, services: keys.map(\.name), span: access.span)
    case .launchValues(let names):
      // Only keydillo's own signed `kd` may receive values, and only launch-time keys, each approved like any request.
      guard ProcessLookup.isKeydilloBinary(caller.pid) else { return .error("launch-time values are only given to keydillo's own kd command") }
      guard servicesLoaded else { return .error("The Mac is locked, so keydillo can't read keys yet.") }
      let command = ProcessLookup.arguments(of: caller.pid).dropFirst().filter { $0 != "run" && $0 != "--" }.joined(separator: " ")
      let keys = names.compactMap(service(named:)).filter(\.isLaunchTime)
      guard !keys.isEmpty else { return .values([:]) }
      // Always a fresh Touch ID that names the command: these values end up readable inside the program.
      if ModelApprover.screenLocked { return .error("The Mac is locked; launch-time keys need Touch ID.") }
      let reason = "give \(keys.map(\.displayName).joined(separator: ", ")) to: \(command)\n\nAnything this command runs can read \(keys.count == 1 ? "it" : "them")."
      guard let ctx = await authenticate(reason) else { return .values([:]) }
      var out: [String: String] = [:]
      for svc in keys {
        let name = svc.name
        guard let d = try? keychain.secret(for: name, context: ctx) else { continue }
        let value = String(decoding: d, as: UTF8.self)
        // Postgres URLs move to keydillo's local endpoint the first time they're used, so the password stops
        // reaching the program from then on.
        if svc.database != true, let target = PostgresURL.proxyable(value) {
          let local = PostgresURL.local(service: name, target: target, port: databasePort)
          switchToDatabaseProxy(svc, local: local)
          out[name] = local
          events.insert(ActivityEvent(date: Date(), service: name, method: "START", path: command, process: caller.displayName, pid: caller.pid,
                                      outcome: .sent, status: 0, note: "now connects through keydillo; the program no longer sees the password"), at: 0)
          continue
        }
        out[name] = value
        events.insert(ActivityEvent(date: Date(), service: name, method: "START", path: command, process: caller.displayName, pid: caller.pid,
                                    outcome: .sent, status: 0, note: "given to the program as it started"), at: 0)
      }
      return .values(out)
    case .backgroundRun(let r):
      // Believed only from keydillo's own signed binary, about itself.
      guard caller.pid == r.pid, ProcessLookup.isKeydilloBinary(caller.pid) else { return .error("not allowed") }
      if r.ended { backgroundRuns[r.pid] = nil } else { backgroundRuns[r.pid] = r }
      return .changed("ok")
    case .requestChange(let r):
      guard servicesLoaded else { return .error("The Mac is locked, so keydillo can't change keys yet.") }
      let who = caller.agent != nil ? caller.friendlyName : (caller.identified ? caller.name : "an unidentified program")
      if r.kind == .rotate {
        guard let s = r.service.flatMap(service(named:)) else { return .error("No key named \(r.service ?? "?"). Call list_services.") }
        return await withCheckedContinuation { cont in
          let id = WindowManager.shared.showReplaceKey(s, requester: who)
          keyRequestWaiters[id] = cont
        }
      }
      let proposal: ChangeProposal
      do { proposal = try changeProposal(r, requester: who) } catch { return .error(error.localizedDescription) }
      if Self.isTrusted(caller) && !addsSite(r) {
        do {
          let result = try await proposal.apply(LAContext())
          events.insert(ActivityEvent(date: Date(), service: r.service ?? r.project ?? "", method: "", path: "", process: who, pid: caller.pid,
                                      outcome: .sent, status: 0, note: "\(proposal.title) (no prompt: \(who) is trusted)"), at: 0)
          return .changed(result)
        } catch { return .error(error.localizedDescription) }
      }
      return await withCheckedContinuation { cont in
        let wid = "change-\(proposal.id)"
        var done = false
        @MainActor func finish(_ resp: ControlResponse) { guard !done else { return }; done = true; WindowManager.shared.close(wid); cont.resume(returning: resp) }
        WindowManager.shared.show(wid, title: proposal.title, floating: true, onClose: { finish(.declined) }) {
          ChangeWindow(proposal: proposal) { finish($0) }.sheetCard()
        }
      }
    case .startBrowser:
      do { return .browser(socket: try BrowserService.shared.start()) } catch { return .error(error.localizedDescription) }
    case .listLogins:
      return .logins(BrowserService.shared.logins.map(LoginSummary.init))
    case .addLogin(var r):
      guard storageSecure else { return .error(Self.insecureMessage) }
      r.requester = caller.agent != nil ? caller.friendlyName : (caller.identified ? caller.name : nil)
      let req = r
      return await withCheckedContinuation { cont in
        WindowManager.shared.showAddLogin(prefill: req) { ok in cont.resume(returning: ok ? .changed("Saved. Call list_logins to see it.") : .declined) }
      }
    case .requestSecret(let r):
      guard servicesLoaded else { return .error("The Mac is locked, so keydillo can't read or add keys yet. Tell the user and retry after they unlock.") }
      guard ServiceConfig.isValidName(r.service) else { return .error("service must be lowercase letters, digits and dashes") }
      let kr = KeyRequest(service: r.service, displayName: r.displayName ?? HostCheck.displayName(r.service), host: r.host,
                          header: r.header, prefix: r.prefix ?? "",
                          envVarName: r.envVarName ?? ServiceConfig(name: r.service, upstreamHost: r.host, authHeader: r.header).envVarName,
                          project: r.project ?? GeneralKeys.defaultProject(cwd: caller.cwd ?? r.cwd),
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

  /// Builds the window for a requested change. Every change here needs the user's Touch ID before it's applied.
  func changeProposal(_ r: ChangeRequest, requester: String) throws -> ChangeProposal {
    func fail(_ m: String) -> Error { VaultError.invalidConfig(m) }
    switch r.kind {
    case .auth:
      guard let s = r.service.flatMap(service(named:)) else { throw fail("No key named \(r.service ?? "?"). Call list_services.") }
      guard !s.isLaunchTime else { throw fail("\(s.displayName) is a launch-time key; it isn't sent in requests.") }
      var n = s
      if let h = r.header { n.authHeader = h }
      if let p = r.prefix { n.authPrefix = p }
      if let b = r.basicAuth { n.basicAuth = b ? true : nil }
      if let q = r.queryParam { n.authQueryParam = q.isEmpty ? nil : q }
      if let h = r.host?.lowercased().trimmingCharacters(in: .whitespaces), !h.isEmpty, !s.allHosts.contains(h) {
        if s.upstreamHost.isEmpty { n.upstreamHost = h } else { n.extraHosts = (s.extraHosts ?? []) + [h] }
      }
      try n.validate()
      guard n != s else { throw fail("That's already how \(s.displayName) is sent.") }
      let rows = [("Header", s.authHeader, n.authHeader), ("Prefix", s.authPrefix, n.authPrefix),
                  ("Basic auth", s.basicAuth == true ? "on" : "off", n.basicAuth == true ? "on" : "off"),
                  ("Query parameter", s.authQueryParam ?? "", n.authQueryParam ?? ""),
                  ("Sent to", s.allHosts.joined(separator: ", "), n.allHosts.joined(separator: ", "))].filter { $0.1 != $0.2 }
      return ChangeProposal(title: "Change how your \(s.displayName) key is sent", requester: requester, rows: rows.map { (label: $0.0, old: $0.1, new: $0.2) },
                            note: r.why, warning: nil, touchReason: "change how your \(s.displayName) key is sent to \(s.upstreamHost.isEmpty ? "its site" : s.upstreamHost)") { [weak self] _ in
        guard let self else { return "" }
        try self.persist(self.services.map { $0.name == n.name ? n : $0 })
        await self.engine.gate.revokeAll(service: n.name); await self.refreshGrants()
        return "\(n.displayName) is now sent \(n.authQueryParam.map { "as ?\($0)=" } ?? (n.basicAuth == true ? "as Basic auth" : "in \(n.authPrefix)\(n.authHeader)"))."
      }
    case .share:
      guard let s = r.service.flatMap(service(named:)) else { throw fail("No key named \(r.service ?? "?"). Call list_services.") }
      guard !s.isGeneral else { throw fail("\(s.name) is in General, so programs in any folder can already use it at \(summary(s).baseURL). Use it directly; no share needed.") }
      guard let target = r.project?.trimmingCharacters(in: .whitespaces), !target.isEmpty, target != s.project else { throw fail("Give the other project's name.") }
      let slug = target.lowercased().filter { $0.isLetter || $0.isNumber }
      var name = "\(s.name)-\(slug)"; var i = 2
      while service(named: name) != nil { name = "\(s.name)-\(slug)-\(i)"; i += 1 }
      return ChangeProposal(title: "Use your \(s.displayName) key in \(target) too", requester: requester,
                            rows: [(label: "Projects", old: s.project, new: "\(s.project), \(target)")],
                            note: r.why, warning: "Programs in \(target) will be able to use this key, sent only to \(s.allHosts.isEmpty ? "its site" : s.allHosts.joined(separator: ", ")).",
                            touchReason: "let \(target) use your \(s.displayName) key (\(s.project))", loosens: true) { [weak self] ctx in
        guard let self else { return "" }
        let value = try self.keychain.secret(for: s.name, context: ctx)
        try self.keychain.setSecret(value, for: name, label: s.displayName)
        var copy = s
        copy.name = name; copy.project = target; copy.folder = self.folder(for: target)
        try self.persist(self.services + [copy])
        return "\(target) can now use \(s.displayName) as \(name) (base URL \(self.summary(copy).baseURL))."
      }
    case .moveFolder:
      guard let project = r.project, projects.contains(project) else { throw fail("No project named \(r.project ?? "?").") }
      guard let raw = r.folder, raw.hasPrefix("/") else { throw fail("Give the new folder as an absolute path.") }
      let new = (raw as NSString).standardizingPath
      var isDir: ObjCBool = false
      guard FileManager.default.fileExists(atPath: new, isDirectory: &isDir), isDir.boolValue else { throw fail("\(new) isn't a folder on this Mac.") }
      let old = folder(for: project) ?? ""
      if let why = ProjectFolders.problem(old: old, new: new) { throw fail(why) }
      let short = { (p: String) in (p as NSString).abbreviatingWithTildeInPath }
      return ChangeProposal(title: "Move \(project) to a new folder", requester: requester, rows: [(label: "Folder", old: short(old), new: short(new))],
                            note: r.why, warning: access(for: project) == .always ? "\(project) is set to \"Once per project\": programs in the new folder will use its keys without asking again." : nil,
                            touchReason: "move \(project)'s keys to \(short(new))", loosens: access(for: project) == .always) { [weak self] _ in
        guard let self else { return "" }
        try self.persist(self.services.map { var c = $0; if c.project == project { c.folder = new; c.folderChosen = true }; return c })
        self.unlocks.close(project)
        return "\(project) now lives in \(short(new)); its keys and settings are unchanged."
      }
    case .rotate:
      throw fail("rotate is handled by the key window")
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
    AgentTools.disconnectAll()
    ShellIntegration.removeLinks()
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
    set {
      if newValue {
        try? Self.agent.register()
        // Switched off under Login Items ("Allow in the Background"): register() can't turn it back on, only the user can.
        if Self.agent.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
      } else { try? Self.agent.unregister() }
    }
  }
  /// The keep-running agent is registered but turned off in System Settings → Login Items.
  var loginItemNeedsApproval: Bool { Self.agent.status == .requiresApproval }

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
    case .dataProtection: return servicesLoaded ? (neverAsk ? "Private Keychain group, readable only by keydillo" : "Private Keychain group, Touch ID on every read")
      : "Private Keychain group. Keys can't be read until the Mac is unlocked; keydillo loads them as soon as it is"
    case .legacy: return "NOT SECURE: no private Keychain group in this build, so keydillo won't store keys"
    }
  }
}

/// Touch ID, unless the caller was started by an app the user trusts.
func touchID(_ ctx: LAContext, _ reason: String, for client: ClientProcess? = nil) async throws -> Bool {
  if let client, AppModel.isTrusted(client) { return true }
  return try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)
}

/// Bridges proxy approvals to Touch ID and the popover.
final class ModelApprover: Approver, @unchecked Sendable {
  weak var model: AppModel?
  init(model: AppModel) { self.model = model }

  static var screenLocked: Bool {
    guard let d = CGSessionCopyCurrentDictionary() as? [String: Any] else { return false }
    return (d["CGSSessionScreenIsLocked"] as? Bool) == true
  }

  /// A key going to a host it hasn't been sent to: always an explicit Touch ID naming the host, whatever the
  /// project setting, earlier approvals or the locked-Mac mode.
  func approveNewHost(_ request: ApprovalRequest) async -> ApprovalResult {
    if Self.screenLocked { return .unavailable("the Mac is locked") }
    let ctx = LAContext()
    ctx.localizedCancelTitle = "Don't allow"
    do { return try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: request.newHostReason) ? .approved(ctx) : .denied }
    catch { return .denied }
  }

  /// A key with "ask before new kinds of requests" on, making one it hasn't made: an explicit Touch ID naming it,
  /// whatever the project setting or earlier approvals.
  func approveNewKind(_ request: ApprovalRequest, kind: String) async -> ApprovalResult {
    if Self.screenLocked { return .unavailable("the Mac is locked") }
    let ctx = LAContext()
    ctx.localizedCancelTitle = "Don't allow"
    do { return try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: request.newKindReason(kind)) ? .approved(ctx) : .denied }
    catch { return .denied }
  }

  /// Hours a "for this session" answer from the phone lasts at most (the AI session usually ends sooner).
  static let phoneSessionHours = 12

  /// Keeps the value the phone released for as long as the user chose on the phone: this request, or this key for
  /// the rest of this program session (any path). The wider choice was signed by the phone after Face ID.
  static func keepPhoneApproval(_ request: ApprovalRequest, _ value: Data, scope: AnswerScope, mode: ApprovalMode, model: AppModel?) async {
    let phone = PhoneApprovals.shared
    guard scope == .session, request.client.identified else { phone.hold(request.service, value, approval: mode); return }
    let minutes = phoneSessionHours * 60
    phone.hold(request.service, value, approval: .window(minutes: minutes))
    await model?.grantFromPhone(service: request.service, minutes: minutes, client: request.client)
  }

  func approve(_ request: ApprovalRequest) async -> ApprovalResult {
    if AppModel.isTrusted(request.client) { return .approved(nil) }
    // "Once per app": one Touch ID for this request also trusts the app (and what it runs) from now on.
    if let app = AppModel.trustCandidate(request.client), !Self.screenLocked {
      let ctx = LAContext()
      ctx.localizedCancelTitle = "Deny"
      let project = await MainActor.run { model?.service(named: request.service)?.project ?? "" }
      let pending = PendingApproval(request: request, context: ctx, project: project, trustApp: app)
      await MainActor.run { model?.showPending(pending) }
      defer { Task { @MainActor in model?.clearPending(pending.id) } }
      await EmbeddedAuthHost.waitUntilShown(pending.id)
      do {
        guard try await touchID(ctx, "let \(app) use your keys without asking from now on") else { return .denied }
        _ = await model?.setTrusted(app, true, context: ctx)
        return .approved(ctx)
      } catch { return .denied }
    }
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
        guard try await touchID(ctx, reason) else { return .denied }
        let keys = await MainActor.run { model?.services.filter { $0.project == open.project }.map(\.name) ?? [] }
        if let m = model { m.unlocks.open(open.project, access: open.access, folder: open.folder, context: ctx, keys: keys, keychain: m.keychain) }
        return .approved(ctx)
      } catch { return .denied }
    }
    // A paired iPhone gets the request too (and is the only way to answer while the Mac is locked).
    let phone = PhoneApprovals.shared
    let copy = phone.ready ? phone.copy(of: request.service) : nil
    let mode = await MainActor.run { model?.service(named: request.service)?.approval ?? .eachRequest }
    if Self.screenLocked {
      guard let copy else { return .unavailable("the Mac is locked") }
      switch await phone.ask(request, wrapped: copy, mac: nil, cancelMac: {}) {
      case .phone(.approved(let value, let scope)):
        guard let value else { return .denied }
        await Self.keepPhoneApproval(request, value, scope: scope, mode: mode, model: model)
        return .approved(nil)
      case .phone(.denied): return .denied
      default: return .unavailable("the Mac is locked and the paired iPhone didn't answer")
      }
    }
    let ctx = LAContext()
    ctx.localizedCancelTitle = "Deny"
    let project = await MainActor.run { model?.service(named: request.service)?.project ?? "" }
    let pending = PendingApproval(request: request, context: ctx, project: project)
    await MainActor.run { model?.showPending(pending) }
    defer { Task { @MainActor in model?.clearPending(pending.id) } }
    if let copy {
      let reason = request.reason
      let cardID = pending.id
      let result = await phone.ask(request, wrapped: copy, mac: {
        await EmbeddedAuthHost.waitUntilShown(cardID)
        return (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
      }, cancelMac: { ctx.invalidate() })
      switch result {
      case .mac(approved: true):
        await MainActor.run { model?.applyUpgradeIfNeeded(pending.id, service: request.service, context: ctx, client: request.client) }
        if let kc = model?.keychain { phone.refreshCopy(request.service, context: ctx, keychain: kc) }
        return .approved(ctx)
      case .phone(.approved(let value, let scope)):
        guard let value else { return .denied }
        await Self.keepPhoneApproval(request, value, scope: scope, mode: mode, model: model)
        return .approved(nil)
      default:
        return .denied
      }
    }
    await EmbeddedAuthHost.waitUntilShown(pending.id)
    do {
      guard try await touchID(ctx, request.reason) else { return .denied }
      await MainActor.run { model?.applyUpgradeIfNeeded(pending.id, service: request.service, context: ctx, client: request.client) }
      // Keys added or rotated after pairing get their phone copy the first time they're approved here.
      if let kc = model?.keychain { phone.refreshCopy(request.service, context: ctx, keychain: kc) }
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

/// Thread-safe list read by the proxy off the main thread.
final class StringsBox: @unchecked Sendable {
  private let lock = NSLock()
  private var v: [String] = []
  var value: [String] {
    get { lock.lock(); defer { lock.unlock() }; return v }
    set { lock.lock(); v = newValue; lock.unlock() }
  }
}

/// Thread-safe Bool read by the proxy off the main thread.
final class FlagBox: @unchecked Sendable {
  private let lock = NSLock()
  private var v = false
  var value: Bool {
    get { lock.lock(); defer { lock.unlock() }; return v }
    set { lock.lock(); v = newValue; lock.unlock() }
  }
}
