import Foundation
import LocalAuthentication

public struct ApprovalRequest: Sendable {
  public var service: String
  public var displayName: String
  public var host: String
  public var method: String
  public var path: String
  public var client: ClientProcess

  /// Shown in the Touch ID dialog. macOS prefixes it with "keydillo is trying to".
  public var reason: String {
    let shortPath = path.count > 48 ? String(path.prefix(47)) + "…" : path
    return "let \(client.displayName) use your \(displayName) key: \(method) \(host)\(shortPath)"
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
    case .window: return service.name
    }
  }

  /// A user-chosen window applies regardless of the service's own mode.
  func windowOverride(_ service: ServiceConfig) -> Grant? {
    guard let g = grants[service.name], let e = g.expires else { return nil }
    if e <= now() { grants[service.name] = nil; return nil }
    return g
  }

  func validGrant(_ service: ServiceConfig, _ client: ClientProcess) -> Grant? {
    if case .eachRequest = service.approval { return nil }
    guard let g = grants[key(service, client)] else { return nil }
    if let e = g.expires, e <= now() { grants[key(service, client)] = nil; return nil }
    return g
  }

  public func authorize(_ service: ServiceConfig, _ request: ApprovalRequest) async -> ApprovalResult {
    if let g = validGrant(service, request.client) ?? windowOverride(service) { return .approved(g.context) }
    await lock()
    defer { unlock() }
    // Another request may have been approved while we waited.
    if let g = validGrant(service, request.client) ?? windowOverride(service) { return .approved(g.context) }
    let result = await approver.approve(request)
    if case .approved(let ctx) = result {
      switch service.approval {
      case .eachRequest: break
      case .perProcess: grants[key(service, request.client)] = Grant(context: ctx, expires: nil, client: request.client)
      case .window(let m): grants[key(service, request.client)] = Grant(context: ctx, expires: now().addingTimeInterval(Double(m) * 60), client: nil)
      }
    }
    return result
  }

  /// Extends an approval to a time window, e.g. when the user picks "15 min" in the popover.
  public func grantWindow(service: String, minutes: Int, context: LAContext?) {
    grants[service] = Grant(context: context, expires: now().addingTimeInterval(Double(minutes) * 60), client: nil)
  }

  public func revokeAll(service: String? = nil) {
    if let service { grants = grants.filter { !$0.key.hasPrefix(service + "|") && $0.key != service } }
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
