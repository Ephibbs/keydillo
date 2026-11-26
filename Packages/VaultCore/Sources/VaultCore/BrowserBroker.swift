import Foundation
import LocalAuthentication

/// Hands website passwords to keydillo's own browser tool, after Touch ID, and stores what it creates
/// (new sign-up passwords, captured API keys).
///
/// The broker has no public endpoint. It answers only on a private pipe to a browser process the app started
/// itself, so no command a user or agent runs can ask it for a password. The same JSON-lines protocol can sit
/// behind a Chrome extension's native messaging host later.
///
/// Requests: `{"id":1,"op":"list"}`, `{"id":2,"op":"secret","login":"github","page":"…","action":"…"}`,
/// `approvePage` (same fields), `saveNew` (`login`, `site`, `username`, `password`),
/// `saveKey` (`name`, `host`, `value`, `keysUrl?`, `project?`). Replies: `{"id":1,"ok":true,"result":…}` or `{"id":1,"ok":false,"error":"…"}`.
public final class BrowserBroker: @unchecked Sendable {
  public struct CapturedKey: Sendable {
    public var name: String, host: String, value: String, keysURL: String?, project: String?
  }

  let store: LoginPersistence
  /// Shows Touch ID with this reason. nil when the user declines.
  let approve: @Sendable (String) async -> LAContext?
  /// Saves a captured API key as a keydillo key. Returns its placeholder.
  let saveKey: @Sendable (CapturedKey) async throws -> String
  /// Logged for the Activity list.
  let note: @Sendable (String) -> Void
  /// Opens keydillo's window for the user to type a login (name, site, username are suggestions). true when saved.
  let requestLogin: @Sendable (String?, String?, String?) async -> Bool
  /// Hand-offs to the user (Mac window and paired iPhone): `handoffStart`, `handoffFrame`, `handoffEnd`.
  let handoff: @Sendable (String, [String: Any]) async throws -> Any
  private let lock = NSLock()

  public init(store: LoginPersistence, approve: @escaping @Sendable (String) async -> LAContext?,
              saveKey: @escaping @Sendable (CapturedKey) async throws -> String, note: @escaping @Sendable (String) -> Void = { _ in },
              requestLogin: @escaping @Sendable (String?, String?, String?) async -> Bool = { _, _, _ in false },
              handoff: @escaping @Sendable (String, [String: Any]) async throws -> Any = { _, _ in throw HandoffUnavailable() }) {
    self.store = store; self.approve = approve; self.saveKey = saveKey; self.note = note; self.requestLogin = requestLogin
    self.handoff = handoff
  }

  public struct HandoffUnavailable: Error, CustomStringConvertible { public init() {}; public var description: String { "hand-offs aren't available" } }

  struct Failure: Error { let message: String }

  /// Handles one JSON line and returns the reply line.
  public func handle(line: Data) async -> Data {
    let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] ?? [:]
    let id = obj["id"] ?? NSNull()
    var reply: [String: Any] = ["id": id]
    do {
      reply["result"] = try await run(obj)
      reply["ok"] = true
    } catch let f as Failure {
      reply["ok"] = false; reply["error"] = f.message
    } catch {
      reply["ok"] = false; reply["error"] = String(describing: error)
    }
    return (try? JSONSerialization.data(withJSONObject: reply)) ?? Data("{\"ok\":false}".utf8)
  }

  private func str(_ o: [String: Any], _ k: String) throws -> String {
    guard let s = o[k] as? String, !s.isEmpty else { throw Failure(message: "missing \(k)") }
    return s
  }

  private func record(_ name: String) throws -> LoginRecord {
    guard let r = store.loadLogins().first(where: { $0.name == name }) else { throw Failure(message: "No saved login named \(name).") }
    return r
  }

  private func update(_ r: LoginRecord) throws {
    lock.lock(); defer { lock.unlock() }
    var all = store.loadLogins().filter { $0.name != r.name }
    all.append(r)
    try store.saveLogins(all.sorted { $0.name < $1.name })
  }

  private func shortPath(_ u: String) -> String { URL(string: u)?.path ?? u }

  func run(_ o: [String: Any]) async throws -> Any {
    switch o["op"] as? String {
    case "list":
      return store.loadLogins().map { r -> [String: Any] in
        ["name": r.name, "site": r.site, "username": r.username, "hasTotp": r.hasTotp,
         "pages": r.pages.map { ["page": $0.page, "action": $0.action] }]
      }

    case "secret", "approvePage":
      var r = try record(try str(o, "login"))
      let lp = LoginPage(page: try str(o, "page"), action: try str(o, "action"))
      guard LoginRules.origin(of: lp.page) == r.site, LoginRules.origin(of: lp.action) == r.site else {
        throw Failure(message: "That page is not on \(r.site).")
      }
      let known = r.pages.contains(lp)
      let reason = known
        ? "sign in to \(r.host) as \(r.username) in the agent's browser"
        : "use your \(r.host) login on a NEW sign-in page: \(lp.page) (sends to \(shortPath(lp.action)))"
      guard let ctx = await approve(reason) else { throw Failure(message: "Denied.") }
      if !known { r.pages.append(lp); try update(r) }
      note("\(o["op"] as? String == "secret" ? "filled" : "approved page for") \(r.name) on \(lp.page)")
      if o["op"] as? String == "approvePage" { return [:] as [String: Any] }
      let s = try store.loginSecret(for: r.name, context: ctx)
      var out: [String: Any] = ["password": s.password]
      if let t = s.totp { out["totp"] = t }
      return out

    case "saveNew":
      let name = try str(o, "login")
      guard LoginRules.isValidName(name) else { throw Failure(message: "Bad login name.") }
      guard let site = LoginRules.normalizeSite(try str(o, "site")) else { throw Failure(message: "Only https sites.") }
      let username = try str(o, "username"), password = try str(o, "password")
      guard password.count >= 12 else { throw Failure(message: "Password too short.") }
      let host = URL(string: site)?.host ?? site
      guard await approve("create an account on \(host) as \(username) and save its new password as \"\(name)\"") != nil else {
        throw Failure(message: "Denied.")
      }
      try store.setLoginSecret(LoginSecret(password: password), for: name)
      try update(LoginRecord(name: name, site: site, username: username))
      note("saved new login \(name) for \(site)")
      return [:] as [String: Any]

    case "saveKey":
      let name = try str(o, "name").lowercased()
      let host = try str(o, "host").lowercased()
      let value = try str(o, "value")
      guard ServiceConfig.isValidName(name) else { throw Failure(message: "Key name must be lowercase letters, digits and dashes.") }
      guard host.range(of: #"^[a-z0-9.-]+\.[a-z]{2,}$"#, options: .regularExpression) != nil else { throw Failure(message: "Bad host.") }
      guard await approve("save a new API key as \"\(name)\" for \(host)") != nil else { throw Failure(message: "Denied.") }
      let placeholder = try await saveKey(CapturedKey(name: name, host: host, value: value,
                                                      keysURL: o["keysUrl"] as? String, project: o["project"] as? String))
      note("saved new API key \(name) for \(host)")
      return ["placeholder": placeholder]

    case "requestLogin":
      let ok = await requestLogin(o["login"] as? String, o["site"] as? String, o["username"] as? String)
      guard ok else { throw Failure(message: "The user closed the window without saving a login.") }
      return [:] as [String: Any]

    case "handoffStart", "handoffFrame", "handoffEnd":
      do { return try await handoff(o["op"] as! String, o) } catch { throw Failure(message: String(describing: error)) }

    default:
      throw Failure(message: "unknown op")
    }
  }

  /// Serves the protocol on a file descriptor (one end of a socketpair) until it closes.
  public func serve(fd: Int32) {
    let input = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    let out = FileHandle(fileDescriptor: fd, closeOnDealloc: false)
    let writeLock = NSLock()
    Thread.detachNewThread { [self] in
      var buf = Data()
      while true {
        let chunk = input.availableData
        if chunk.isEmpty { break }
        buf.append(chunk)
        while let nl = buf.firstIndex(of: 0x0A) {
          let line = buf[buf.startIndex..<nl]
          buf = Data(buf[buf.index(after: nl)...])
          let req = Data(line)
          Task {
            var reply = await self.handle(line: req)
            reply.append(0x0A)
            writeLock.withLock { out.write(reply) }
          }
        }
      }
      close(fd)
    }
  }
}
