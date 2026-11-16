import Foundation
import LocalAuthentication

public protocol SecretProvider: AnyObject {
  func secret(for name: String, context: LAContext?) throws -> Data
}
extension KeychainBackend: SecretProvider {}

public struct ActivityEvent: Codable, Identifiable, Equatable, Sendable {
  public enum Outcome: String, Codable, Sendable { case sent, blocked, denied, failed }
  public var id = UUID()
  public var date: Date
  public var service: String
  public var method: String
  public var path: String
  public var process: String
  public var pid: Int32
  public var outcome: Outcome
  public var status: Int
  public var note: String?
}

/// Turns one local request into one upstream request, enforcing rules and approval.
/// Never logs header values or bodies.
public final class ProxyEngine: @unchecked Sendable {
  public var services: () -> [ServiceConfig]
  let secrets: SecretProvider
  public let gate: ApprovalGate
  let session: URLSession
  public var onEvent: (ActivityEvent) -> Void = { _ in }
  private var hits: [String: [Date]] = [:]
  private let lock = NSLock()

  static let hopByHop: Set<String> = ["connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
                                       "proxy-connection", "te", "trailer", "transfer-encoding", "upgrade", "host",
                                       "content-length"]

  public init(services: @escaping () -> [ServiceConfig], secrets: SecretProvider, approver: Approver) {
    self.services = services
    self.secrets = secrets
    self.gate = ApprovalGate(approver: approver)
    let cfg = URLSessionConfiguration.ephemeral
    cfg.httpCookieStorage = nil
    cfg.httpShouldSetCookies = false
    cfg.urlCache = nil
    cfg.timeoutIntervalForRequest = 120
    self.session = URLSession(configuration: cfg, delegate: NoRedirects(), delegateQueue: nil)
  }

  public func handle(_ req: HTTPRequest, client: ClientProcess) async -> HTTPResponse {
    // Split /<service>/<rest>
    let (pathOnly, query) = Self.splitQuery(req.target)
    let parts = pathOnly.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
    guard let first = parts.first else { return .error(404, "Use http://localhost:7787/<service>/<path>") }
    let name = String(first)
    let upstreamPath = "/" + (parts.count > 1 ? String(parts[1]) : "")
    func log(_ outcome: ActivityEvent.Outcome, _ status: Int, _ note: String? = nil) {
      onEvent(ActivityEvent(date: Date(), service: name, method: req.method, path: upstreamPath, process: client.displayName,
                            pid: client.pid, outcome: outcome, status: status, note: note))
    }
    guard let svc = services().first(where: { $0.name == name }) else {
      log(.blocked, 404, "unknown service")
      return .error(404, "No service named '\(name)'. Ask the user to add it in keydillo.")
    }
    guard !pathOnly.contains("/../"), !pathOnly.hasSuffix("/.."), !pathOnly.contains("%2e%2e"), !pathOnly.contains("%2E%2E") else {
      log(.blocked, 400, "path traversal"); return .error(400, "Path not allowed")
    }
    guard svc.permits(method: req.method, path: upstreamPath) else {
      log(.blocked, 403, "path not allowed")
      return .error(403, "\(req.method) \(upstreamPath) is not allowed for \(name)")
    }
    if let cap = svc.maxRequestsPerHour, !takeRateSlot(name, cap: cap) {
      log(.blocked, 429, "rate limit")
      return .error(429, "Rate limit for \(name) reached (\(cap)/hour)")
    }

    let approval = ApprovalRequest(service: name, displayName: svc.displayName, host: svc.upstreamHost,
                                   method: req.method, path: upstreamPath, client: client)
    guard case .approved(let ctx) = await gate.authorize(svc, approval) else {
      log(.denied, 403, nil)
      return .error(403, "The user did not approve this request")
    }

    var secret: Data
    do { secret = try secrets.secret(for: name, context: ctx) }
    catch VaultError.denied { log(.denied, 403); return .error(403, "The user did not approve this request") }
    catch { log(.failed, 500, "key unavailable"); return .error(500, "Key for \(name) is unavailable") }
    defer { secret.resetBytes(in: 0..<secret.count) }

    guard let url = URL(string: "\(svc.upstreamScheme)://\(svc.upstreamHost)\(upstreamPath)\(query.map { "?\($0)" } ?? "")"),
          url.host == svc.upstreamHost.split(separator: ":").first.map(String.init) else {
      log(.blocked, 400, "bad url"); return .error(400, "Bad path")
    }
    var out = URLRequest(url: url)
    out.httpMethod = req.method
    for (k, v) in req.headers {
      let lk = k.lowercased()
      if Self.hopByHop.contains(lk) || lk == svc.authHeader.lowercased() || lk == "authorization" && svc.authHeader.lowercased() != "authorization" {
        continue
      }
      out.addValue(v, forHTTPHeaderField: k)
    }
    out.setValue(svc.authPrefix + String(decoding: secret, as: UTF8.self), forHTTPHeaderField: svc.authHeader)
    if !req.body.isEmpty { out.httpBody = req.body }

    do {
      let (data, resp) = try await session.data(for: out)
      guard let http = resp as? HTTPURLResponse else { log(.failed, 502); return .error(502, "Bad upstream response") }
      var headers: [(String, String)] = []
      for (k, v) in http.allHeaderFields {
        guard let k = k as? String, let v = v as? String else { continue }
        let lk = k.lowercased()
        if Self.hopByHop.contains(lk) || lk == "content-encoding" || lk == "set-cookie" { continue }
        headers.append((k, Self.redact(v, secret: secret)))
      }
      let body = Self.redact(data, secret: secret)
      log(.sent, http.statusCode)
      return HTTPResponse(status: http.statusCode, headers: headers, body: body)
    } catch {
      log(.failed, 502, "upstream unreachable")
      return .error(502, "Upstream request failed: \((error as NSError).localizedDescription)")
    }
  }

  func takeRateSlot(_ name: String, cap: Int) -> Bool {
    lock.lock(); defer { lock.unlock() }
    let cutoff = Date().addingTimeInterval(-3600)
    var list = (hits[name] ?? []).filter { $0 > cutoff }
    guard list.count < cap else { hits[name] = list; return false }
    list.append(Date()); hits[name] = list
    return true
  }

  static func splitQuery(_ target: String) -> (String, String?) {
    guard let q = target.firstIndex(of: "?") else { return (target, nil) }
    return (String(target[..<q]), String(target[target.index(after: q)...]))
  }

  static let redaction = Data("[redacted by keydillo]".utf8)

  /// Replaces any occurrence of the secret in upstream output, in case an API echoes it back.
  public static func redact(_ data: Data, secret: Data) -> Data {
    guard secret.count >= 8, data.count >= secret.count else { return data }
    var out = data
    while let r = out.range(of: secret) { out.replaceSubrange(r, with: redaction) }
    return out
  }
  static func redact(_ s: String, secret: Data) -> String {
    String(decoding: redact(Data(s.utf8), secret: secret), as: UTF8.self)
  }
}

/// Redirects are returned to the client instead of followed, so the auth header never goes to another host.
final class NoRedirects: NSObject, URLSessionTaskDelegate {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest) async -> URLRequest? { nil }
}
