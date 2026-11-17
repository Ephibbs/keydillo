import Foundation
import LocalAuthentication

public struct ApprovalRequest: Sendable {
  public var service: String
  public var displayName: String
  public var host: String
  public var method: String
  public var path: String
  public var client: ClientProcess

  public init(service: String, displayName: String, host: String, method: String, path: String, client: ClientProcess) {
    self.service = service; self.displayName = displayName; self.host = host; self.method = method; self.path = path; self.client = client
  }

  /// Shown in the Touch ID dialog. macOS prefixes it with "keydillo is trying to".
  public var reason: String {
    if method == "START" {
      return "give \(client.friendlyName) your \(displayName) as it starts (\(path)). The program can see this value"
    }
    let shortPath = path.count > 48 ? String(path.prefix(47)) + "…" : path
    // macOS shows this after '"keydillo" is trying to', so it reads: keydillo is trying to let Claude Code use your OpenAI key.
    let via = client.agent != nil && client.name.lowercased() != client.agent?.lowercased() && client.name != "keydillo" ? " (\(client.name))" : ""
    return "let \(client.friendlyName) use your \(displayName) key\(via): \(method) \(host)\(shortPath)"
  }
}

public enum ApprovalResult {
  case approved(LAContext?)
  case denied
  /// Touch ID couldn't be shown (e.g. the Mac is locked). The reason is passed to the agent.
  case unavailable(String)
}

public protocol Approver: AnyObject {
  func approve(_ request: ApprovalRequest) async -> ApprovalResult
  /// Sending a key to a host it hasn't been sent to before. Always an explicit prompt naming the host:
  /// never covered by an earlier approval, a project setting or the locked-Mac mode.
  func approveNewHost(_ request: ApprovalRequest) async -> ApprovalResult
}

public extension Approver {
  func approveNewHost(_ request: ApprovalRequest) async -> ApprovalResult { .denied }
}

public extension ApprovalRequest {
  /// "keydillo is trying to send your Together key to a new site, api.together.xyz (asked by Claude Code)…"
  var newHostReason: String {
    let note = Self.sharedHostingSuffix(host).map { " Note: anyone can host a site on \($0)." } ?? ""
    return "send your \(displayName) key to \(host)\n\nA new site for this key, asked for by \(client.friendlyName). keydillo will remember it.\(note)"
  }

  /// Domains where anyone can put up a site, so a host there proves nothing about who runs it.
  static let sharedHosting = ["github.io", "vercel.app", "netlify.app", "pages.dev", "workers.dev", "herokuapp.com", "ngrok.io", "ngrok-free.app",
                              "ngrok.app", "onrender.com", "fly.dev", "railway.app", "glitch.me", "repl.co", "replit.app", "web.app",
                              "firebaseapp.com", "appspot.com", "azurewebsites.net", "cloudfront.net", "s3.amazonaws.com", "trycloudflare.com",
                              "surge.sh", "deno.dev", "val.run", "loca.lt", "serveo.net"]
  static func sharedHostingSuffix(_ host: String) -> String? {
    let h = host.lowercased().split(separator: ":").first.map(String.init) ?? host.lowercased()
    return sharedHosting.first { h == $0 || h.hasSuffix("." + $0) }
  }
}

/// Touch ID (falls back to the login password when Touch ID is unavailable or locked out).
public final class TouchIDApprover: Approver {
  public init() {}
  public func approve(_ request: ApprovalRequest) async -> ApprovalResult {
    let ctx = LAContext()
    ctx.localizedCancelTitle = "Deny"
    do {
      let ok = try await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: request.reason)
      return ok ? .approved(ctx) : .denied
    } catch {
      return .denied
    }
  }
}

/// Decides whether a request needs a fresh approval, based on the service's mode, and remembers grants.
/// One approval prompt at a time: concurrent requests wait instead of stacking dialogs.
public actor ApprovalGate {
  struct Grant { var context: LAContext?; var expires: Date? ; var client: ClientProcess? }
  private var grants: [String: Grant] = [:]
  private let approver: Approver
  private let now: @Sendable () -> Date
  private var busy = false
  private var waiters: [CheckedContinuation<Void, Never>] = []

  public init(approver: Approver, now: @escaping @Sendable () -> Date = { Date() }) {
    self.approver = approver
    self.now = now
  }

  func key(_ service: ServiceConfig, _ client: ClientProcess) -> String {
    switch service.approval {
    case .eachRequest: return ""
    case .perProcess: return "\(service.name)|\(client.sessionKey)"
    case .window: return "\(service.name)|\(client.sessionKey)"
    }
  }

  /// A user-chosen window applies regardless of the service's own mode.
  func windowOverride(_ service: ServiceConfig, _ client: ClientProcess) -> Grant? {
    let k = "\(service.name)|\(client.sessionKey)|override"
    guard let g = grants[k], let e = g.expires else { return nil }
    if e <= now() { grants[k] = nil; return nil }
    return g
  }

  func validGrant(_ service: ServiceConfig, _ client: ClientProcess) -> Grant? {
    if case .eachRequest = service.approval { return nil }
    guard let g = grants[key(service, client)] else { return nil }
    if let e = g.expires, e <= now() { grants[key(service, client)] = nil; return nil }
    return g
  }

  /// Parallel calls from the same program within a few seconds share one Touch ID, instead of N prompts in a row.
  private var bursts: [String: (Date, LAContext?)] = [:]
  public static let burstSeconds: TimeInterval = 3
  func burst(_ service: ServiceConfig, _ client: ClientProcess) -> LAContext?? {
    guard client.identified else { return nil }
    let k = service.name + "|" + client.sessionKey
    guard let (t, ctx) = bursts[k], now().timeIntervalSince(t) < Self.burstSeconds else { return nil }
    return .some(ctx)
  }

  public func authorize(_ service: ServiceConfig, _ request: ApprovalRequest) async -> ApprovalResult {
    if let g = validGrant(service, request.client) ?? windowOverride(service, request.client) { return .approved(g.context) }
    if let ctx = burst(service, request.client) { return .approved(ctx) }
    await lock()
    defer { unlock() }
    // Another request may have been approved while we waited.
    if let g = validGrant(service, request.client) ?? windowOverride(service, request.client) { return .approved(g.context) }
    if let ctx = burst(service, request.client) { return .approved(ctx) }
    let result = await approver.approve(request)
    if case .approved(let ctx) = result, request.client.identified { bursts[service.name + "|" + request.client.sessionKey] = (now(), ctx) }
    if case .approved(let ctx) = result, request.client.identified {
      switch service.approval {
      case .eachRequest: break
      case .perProcess: grants[key(service, request.client)] = Grant(context: ctx, expires: nil, client: request.client)
      case .window(let m): grants[key(service, request.client)] = Grant(context: ctx, expires: now().addingTimeInterval(Double(m) * 60), client: request.client)
      }
    }
    return result
  }

  /// Extends an approval to a time window, e.g. when the user picks "15 min" in the popover.
  public func grantWindow(service: String, minutes: Int, context: LAContext?, client: ClientProcess? = nil) {
    guard let client, client.identified else { return }
    grants["\(service)|\(client.sessionKey)|override"] = Grant(context: context, expires: now().addingTimeInterval(Double(minutes) * 60), client: client)
  }

  /// Ends every approval held by one program session.
  public func revoke(session: String) {
    grants = grants.filter { $0.value.client?.sessionKey != session }
    bursts = bursts.filter { !$0.key.hasSuffix("|" + session) }
  }

  public func revokeAll(service: String? = nil) {
    if let service { grants = grants.filter { !$0.key.hasPrefix(service + "|") && $0.key != service }; bursts = bursts.filter { !$0.key.hasPrefix(service + "|") } }
    else { grants.removeAll() }
  }

  public func activeGrants() -> [(service: String, expires: Date?, client: ClientProcess?)] {
    grants.compactMap { k, g in
      if let e = g.expires, e <= now() { return nil }
      return (String(k.split(separator: "|").first ?? ""), g.expires, g.client)
    }
  }

  private func lock() async {
    if !busy { busy = true; return }
    await withCheckedContinuation { waiters.append($0) }
  }
  private func unlock() {
    if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
  }
}
