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

  public init(date: Date, service: String, method: String, path: String, process: String, pid: Int32,
              outcome: Outcome, status: Int, note: String? = nil) {
    self.date = date; self.service = service; self.method = method; self.path = path
    self.process = process; self.pid = pid; self.outcome = outcome; self.status = status; self.note = note
  }
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
    cfg.timeoutIntervalForRequest = 600        // idle time between bytes (long generations, streams)
    cfg.timeoutIntervalForResource = 24 * 3600
    self.session = URLSession(configuration: cfg, delegate: NoRedirects(), delegateQueue: nil)
  }

  /// Buffered convenience (tests, simple callers).
  public func handle(_ req: HTTPRequest, client: ClientProcess) async -> HTTPResponse {
    let sink = BufferSink()
    await serve(req, client: client, sink: sink)
    return sink.response
  }

  /// Handles one request, streaming the upstream response into `sink` as it arrives.
  public func serve(_ req: HTTPRequest, client: ClientProcess, sink: ResponseSink) async {
    // Web pages must never be able to use keys: block cross-site browser requests and DNS-rebinding hosts.
    if let reason = Self.browserBlockReason(req) {
      return await sink.respond(.error(403, reason, code: "browser_blocked",
        hint: "Call keydillo from server-side code or a script, not from a web page. Browsers can't use keydillo, by design."))
    }
    // Split /<service>/<rest>
    let (pathOnly, query) = Self.splitQuery(req.target)
    let parts = pathOnly.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: true)
    guard let first = parts.first else { return await sink.respond(.error(404, "use http://localhost:<port>/<service>/<path>", code: "bad_path", hint: "Call the keydillo list_services tool for base URLs.")) }
    let name = String(first)
    let upstreamPath = "/" + (parts.count > 1 ? String(parts[1]) : "")
    func log(_ outcome: ActivityEvent.Outcome, _ status: Int, _ note: String? = nil) {
      // Paths only, never query strings: some APIs take the key as a query parameter.
      onEvent(ActivityEvent(date: Date(), service: name, method: req.method, path: upstreamPath, process: client.displayName,
                            pid: client.pid, outcome: outcome, status: status, note: note))
    }
    guard let svc = services().first(where: { $0.name == name }) else {
      log(.blocked, 404, "unknown service")
      return await sink.respond(.error(404, "no key named '\(name)' is stored", code: "unknown_service", hint: "Call the keydillo request_secret tool so the user can add it. Never ask for the key in chat."))
    }
    guard svc.isProxyReady else {
      log(.blocked, 409, "not set up")
      return await sink.respond(.error(409, "\(name) is stored but has no host or header yet", code: "needs_setup", hint: "Ask the user to finish setting up \(name) in keydillo, or call request_secret with the API's host and header."))
    }
    // Decode once and refuse dot segments and encoded slashes, so path rules can't be stepped around.
    let decodedPath = upstreamPath.removingPercentEncoding ?? upstreamPath
    let lowered = upstreamPath.lowercased()
    guard !decodedPath.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == "." || $0 == ".." }),
          !lowered.contains("%2f"), !lowered.contains("%5c"), !decodedPath.contains("\\") else {
      log(.blocked, 400, "path traversal"); return await sink.respond(.error(400, "path not allowed", code: "bad_path"))
    }
    guard svc.permits(method: req.method, path: decodedPath) else {
      log(.blocked, 403, "path not allowed")
      return await sink.respond(.error(403, "\(req.method) \(upstreamPath) isn't allowed for \(name)", code: "path_not_allowed", hint: "Tell the user which path you need; they can allow it in keydillo. Don't try another route."))
    }
    if let cap = svc.maxRequestsPerHour, !takeRateSlot(name, cap: cap) {
      log(.blocked, 429, "rate limit")
      return await sink.respond(.error(429, "rate limit for \(name) reached (\(cap)/hour)", code: "rate_limited", hint: "Wait, or ask the user to raise the limit."))
    }

    if svc.placeholderAnywhere != true, let place = Self.misplacedPlaceholder(req, svc: svc, path: upstreamPath, query: query) {
      log(.blocked, 400, "placeholder in \(place)")
      return await sink.respond(.error(400, "a keydillo placeholder was found in the \(place). \(svc.displayName)'s key is only ever sent in \(Self.authSpot(svc))", code: "placeholder_misplaced",
        hint: "Remove the placeholder from the \(place); keydillo adds the key itself. If this API really needs the key there, the user can allow it for \(name) in keydillo."))
    }

    let approval = ApprovalRequest(service: name, displayName: svc.displayName, host: svc.upstreamHost,
                                   method: req.method, path: upstreamPath, client: client)
    let ctx: LAContext?
    switch await gate.authorize(svc, approval) {
    case .approved(let c): ctx = c
    case .denied:
      log(.denied, 403, nil)
      return await sink.respond(.error(403, "the user declined this request", code: "denied", hint: "Stop and tell the user. Don't retry unless they ask you to."))
    case .unavailable(let why):
      log(.denied, 423, why)
      return await sink.respond(.error(423, "can't ask for approval right now (\(why))", code: "approval_unavailable", hint: "Tell the user the request is waiting for them; retry once they're back."))
    }

    var secret: Data
    do { secret = try secrets.secret(for: name, context: ctx) }
    catch VaultError.denied { log(.denied, 403); return await sink.respond(.error(403, "the user declined this request", code: "denied", hint: "Stop and tell the user.")) }
    catch { log(.failed, 500, "key unavailable"); return await sink.respond(.error(500, "the key for \(name) couldn't be read", code: "key_unavailable", hint: "Ask the user to check \(name) in keydillo.")) }
    defer { secret.resetBytes(in: 0..<secret.count) }
    let raw = String(decoding: secret, as: UTF8.self)
    let keyValue: String = svc.basicAuth == true
      ? "Basic " + Data((raw.contains(":") ? raw : raw + ":").utf8).base64EncodedString()
      : svc.authPrefix + raw
    // Only keys that opted in may be placed anywhere; the rest go only into their configured spot.
    let sub = PlaceholderSubstitution(service: name, value: raw)
    let anywhere = svc.placeholderAnywhere == true
    let forms = Self.redactionForms(raw: raw, keyValue: keyValue)

    var queryItems = query.map { Self.parseQuery(anywhere ? sub.apply($0, urlEncoded: true) : $0) } ?? []
    if let qp = svc.authQueryParam, !qp.isEmpty {
      queryItems.removeAll { $0.0 == qp }
      queryItems.append((qp, keyValue))
    }
    let queryString = queryItems.isEmpty ? "" : "?" + queryItems.map { "\($0.0)\($0.1.map { "=" + Self.encode($0) } ?? "")" }.joined(separator: "&")
    let usesHeader = (svc.authQueryParam ?? "").isEmpty && !svc.authHeader.isEmpty
    let outPath = anywhere ? sub.apply(upstreamPath, urlEncoded: true) : upstreamPath

    func forwardedHeaders(keepUpgrade: Bool) -> [(String, String)] {
      var out: [(String, String)] = []
      for (k, v) in req.headers {
        let lk = k.lowercased()
        if keepUpgrade && (lk == "upgrade" || lk == "connection") { out.append((k, v)); continue }
        if Self.hopByHop.contains(lk) { continue }
        if usesHeader && (lk == svc.authHeader.lowercased() || lk == "authorization" && svc.authHeader.lowercased() != "authorization") { continue }
        if let extra = svc.extraHeaders, extra.keys.contains(where: { $0.lowercased() == lk }) { continue }
        out.append((k, anywhere ? sub.apply(v, urlEncoded: false) : v))
      }
      if usesHeader { out.append((svc.authHeader, keyValue)) }
      for (k, template) in svc.extraHeaders ?? [:] { out.append((k, template.replacingOccurrences(of: "{key}", with: raw))) }
      return out
    }

    // Build the destination from the validated host and port only; the path and query can't change it.
    guard let target = UpstreamTarget(svc), let url = URL(string: target.origin + outPath + queryString),
          url.host?.lowercased() == target.host, (url.port ?? Int(target.defaultPort)) == Int(target.port) else {
      log(.blocked, 400, "bad url"); return await sink.respond(.error(400, "bad path", code: "bad_path"))
    }

    // Websockets: send the upgrade request with the key; tunnel only if the upstream actually switches protocols.
    if (req.header("Upgrade") ?? "").lowercased() == "websocket" {
      var head = "\(req.method) \(outPath)\(queryString) HTTP/1.1\r\nHost: \(svc.upstreamHost)\r\n"
      for (k, v) in forwardedHeaders(keepUpgrade: true) { head += "\(k): \(v)\r\n" }
      head += "\r\n"
      log(.sent, 101, "websocket")
      return await sink.tunnel(host: target.host, port: target.port, tls: target.tls, head: Data(head.utf8),
                               redact: { Self.redact($0, forms: forms, label: svc.displayName) })
    }

    var out = URLRequest(url: url)
    out.httpMethod = req.method
    for (k, v) in forwardedHeaders(keepUpgrade: false) { out.addValue(v, forHTTPHeaderField: k) }
    if !req.body.isEmpty { out.httpBody = anywhere ? sub.apply(req.body) : req.body }

    let fetch = StreamFetch()
    let task = session.dataTask(with: out)
    task.delegate = fetch
    task.resume()
    do {
      let http = try await fetch.response()
      var headers: [(String, String)] = []
      for (k, v) in http.allHeaderFields {
        guard let k = k as? String, let v = v as? String else { continue }
        let lk = k.lowercased()
        if Self.hopByHop.contains(lk) || lk == "content-encoding" { continue }
        if lk == "set-cookie" {
          // URLSession joins repeated Set-Cookie headers with ", "; split them back apart.
          for c in Self.splitSetCookie(v) { headers.append((k, Self.redact(c, forms: forms, label: svc.displayName))) }
          continue
        }
        headers.append((k, Self.redact(v, forms: forms, label: svc.displayName)))
      }
      // The provider refused the key itself: say so in plain words for the agent and flag it in the app.
      let rejected = http.statusCode == 401
      if rejected {
        headers.append(("X-Keydillo-Note", "\(svc.displayName) rejected this key (401). Ask the user to rotate \(name) in keydillo; don't look for another key."))
      }
      await sink.start(status: http.statusCode, headers: headers)
      // Stream chunks through, holding back a tail so a key split across chunks is still redacted.
      let hold = max(0, (forms.map(\.count).max() ?? 1) - 1)
      var carry = Data()
      for try await chunk in fetch.chunks {
        carry.append(chunk)
        let redacted = Self.redact(carry, forms: forms, label: svc.displayName)
        if redacted.count > hold {
          await sink.write(redacted.prefix(redacted.count - hold))
          carry = Data(redacted.suffix(hold))
        } else { carry = redacted }
      }
      if !carry.isEmpty { await sink.write(Self.redact(carry, forms: forms, label: svc.displayName)) }
      await sink.finish()
      log(.sent, http.statusCode, rejected ? "key rejected by \(svc.displayName)" : nil)
    } catch {
      task.cancel()
      log(.failed, 502, "upstream unreachable")
      await sink.respond(.error(502, "couldn't reach \(svc.upstreamHost): \((error as NSError).localizedDescription)", code: "upstream_failed", hint: "Check the network, then retry."))
    }
  }

  static func browserBlockReason(_ req: HTTPRequest) -> String? {
    let localHosts = ["localhost", "127.0.0.1", "[::1]"]
    guard let host = req.header("Host") else { return "requests must include a Host header" }
    let name = (host.hasPrefix("[") ? String(host.prefix { $0 != "]" }) + "]" : String(host.split(separator: ":").first ?? "")).lowercased()
    // Docker containers reach the Mac as host.docker.internal; allowed only for non-browser requests.
    let dockerHost = name == "host.docker.internal" && req.header("Origin") == nil
    if !localHosts.contains(name) && !dockerHost { return "requests must be addressed to localhost (got Host: \(host))" }
    if let origin = req.header("Origin") {
      let oh = URL(string: origin)?.host?.lowercased()
      let local = oh.map { ["localhost", "127.0.0.1", "::1", "[::1]"].contains($0) } ?? false
      if !local { return "requests from web pages (\(origin)) aren't allowed" }
    }
    if let site = req.header("Sec-Fetch-Site")?.lowercased(), site == "cross-site" || site == "same-site" {
      return "requests from web pages aren't allowed"
    }
    return nil
  }

  static func splitSetCookie(_ v: String) -> [String] {
    let re = try! NSRegularExpression(pattern: ",\\s*(?=[^;,=\\s]+=)")
    var parts: [String] = []; var last = v.startIndex
    for m in re.matches(in: v, range: NSRange(v.startIndex..., in: v)) {
      let r = Range(m.range, in: v)!
      parts.append(String(v[last..<r.lowerBound])); last = r.upperBound
    }
    parts.append(String(v[last...]))
    return parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
  }

  static func parseQuery(_ q: String) -> [(String, String?)] {
    q.split(separator: "&", omittingEmptySubsequences: true).map { pair in
      let kv = pair.split(separator: "=", maxSplits: 1)
      return (String(kv[0]), kv.count > 1 ? String(kv[1]) : nil)
    }
  }
  static func encode(_ s: String) -> String {
    var allowed = CharacterSet.urlQueryAllowed; allowed.remove(charactersIn: "&=+?#")
    return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
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

  /// Every form of the key this proxy might have produced, longest first, so echoes in any of them are scrubbed.
  static func redactionForms(raw: String, keyValue: String) -> [Data] {
    var f = [raw, keyValue, Data(raw.utf8).base64EncodedString(), Data((raw + ":").utf8).base64EncodedString(),
             raw.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? raw]
    if keyValue.hasPrefix("Basic ") { f.append(String(keyValue.dropFirst(6))) }
    let forms = Array(Set(f.filter { $0.count >= 4 })).sorted { $0.count > $1.count }
    return forms.map { Data($0.utf8) }
  }

  public static func redact(_ data: Data, forms: [Data], label: String = "") -> Data {
    let mark = Data("[redacted by keydillo: \(label.isEmpty ? "" : label + " ")key]".utf8)
    var out = data
    for f in forms where out.count >= f.count {
      while let r = out.range(of: f) { out.replaceSubrange(r, with: mark) }
    }
    return out
  }
  static func redact(_ s: String, forms: [Data], label: String = "") -> String {
    String(decoding: redact(Data(s.utf8), forms: forms, label: label), as: UTF8.self)
  }

  static func hasMarker(_ s: String) -> Bool { let l = s.lowercased(); return l.contains("keydillo:") || l.contains("keydillo%3a") }

  static func authSpot(_ svc: ServiceConfig) -> String {
    if let q = svc.authQueryParam, !q.isEmpty { return "the ?\(q)= query parameter" }
    if svc.basicAuth == true { return "the Authorization header (Basic)" }
    return "the \(svc.authHeader) header"
  }

  /// Where a placeholder sits outside the key's configured spot, if anywhere.
  static func misplacedPlaceholder(_ req: HTTPRequest, svc: ServiceConfig, path: String, query: String?) -> String? {
    if hasMarker(path) { return "URL path" }
    for (k, v) in parseQuery(query ?? "") where k != svc.authQueryParam && (hasMarker(k) || hasMarker(v ?? "")) { return "query string" }
    let usesHeader = (svc.authQueryParam ?? "").isEmpty && !svc.authHeader.isEmpty
    for (k, v) in req.headers where hasMarker(v) {
      let lk = k.lowercased()
      if usesHeader && (lk == svc.authHeader.lowercased() || lk == "authorization") { continue }
      if svc.basicAuth == true && lk == "authorization" { continue }
      if svc.extraHeaders?.keys.contains(where: { $0.lowercased() == lk }) == true { continue }
      return "\(k) header"
    }
    if lowercasedContains(req.body, "keydillo:") || lowercasedContains(req.body, "keydillo%3a") { return "request body" }
    return nil
  }

  static func lowercasedContains(_ d: Data, _ needle: String) -> Bool {
    guard d.count >= needle.count, d.range(of: Data("eydillo".utf8)) != nil || d.range(of: Data("EYDILLO".utf8)) != nil else { return false }
    return String(decoding: d, as: UTF8.self).lowercased().contains(needle)
  }

  /// Replaces any occurrence of the secret in upstream output, in case an API echoes it back.
  public static func redact(_ data: Data, secret: Data, label: String = "") -> Data {
    guard secret.count >= 8, data.count >= secret.count else { return data }
    let mark = Data("[redacted by keydillo: \(label.isEmpty ? "" : label + " ")key]".utf8)
    var out = data
    while let r = out.range(of: secret) { out.replaceSubrange(r, with: mark) }
    return out
  }
  static func redact(_ s: String, secret: Data, label: String = "") -> String {
    String(decoding: redact(Data(s.utf8), secret: secret, label: label), as: UTF8.self)
  }
}

/// Redirects are returned to the client instead of followed, so the auth header never goes to another host.
final class NoRedirects: NSObject, URLSessionTaskDelegate {
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest) async -> URLRequest? { nil }
}


/// Where the proxy writes a response. The server implements it over the socket; `BufferSink` collects it.
public protocol ResponseSink: AnyObject {
  func start(status: Int, headers: [(String, String)]) async
  func write(_ data: Data) async
  func finish() async
  /// Turns the client connection into a raw tunnel to host:port after sending `head` (websockets).
  /// Sends `head` upstream; if the upstream answers 101, the connection becomes a raw tunnel.
  /// Any other answer is passed back through `redact` and the connection is closed.
  func tunnel(host: String, port: UInt16, tls: Bool, head: Data, redact: @escaping (Data) -> Data) async
}

public extension ResponseSink {
  func respond(_ r: HTTPResponse) async {
    await start(status: r.status, headers: r.headers)
    await write(r.body)
    await finish()
  }
}

public final class BufferSink: ResponseSink {
  public var response = HTTPResponse(status: 502)
  public init() {}
  public func start(status: Int, headers: [(String, String)]) async { response = HTTPResponse(status: status, headers: headers) }
  public func write(_ data: Data) async { response.body.append(data) }
  public func finish() async {}
  public func tunnel(host: String, port: UInt16, tls: Bool, head: Data, redact: @escaping (Data) -> Data) async {
    response = .error(501, "websockets need a live connection", code: "unsupported")
  }
}

/// Per-task URLSession delegate that exposes the response and body chunks as async values.
final class StreamFetch: NSObject, URLSessionDataDelegate, @unchecked Sendable {
  private var responseCont: CheckedContinuation<HTTPURLResponse, Error>?
  private var gotResponse: Result<HTTPURLResponse, Error>?
  private let lock = NSLock()
  let chunks: AsyncThrowingStream<Data, Error>
  private let chunkCont: AsyncThrowingStream<Data, Error>.Continuation

  override init() {
    var c: AsyncThrowingStream<Data, Error>.Continuation!
    chunks = AsyncThrowingStream { c = $0 }
    chunkCont = c
  }

  func response() async throws -> HTTPURLResponse {
    try await withCheckedThrowingContinuation { cont in
      lock.lock()
      if let r = gotResponse { lock.unlock(); cont.resume(with: r) } else { responseCont = cont; lock.unlock() }
    }
  }

  private func deliver(_ r: Result<HTTPURLResponse, Error>) {
    lock.lock()
    if gotResponse != nil { lock.unlock(); return }
    gotResponse = r
    let c = responseCont; responseCont = nil
    lock.unlock()
    c?.resume(with: r)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse) async -> URLSession.ResponseDisposition {
    if let http = response as? HTTPURLResponse { deliver(.success(http)) } else { deliver(.failure(URLError(.badServerResponse))) }
    return .allow
  }
  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) { chunkCont.yield(data) }
  func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
    if let error { deliver(.failure(error)); chunkCont.finish(throwing: error) } else { chunkCont.finish() }
  }
  func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                  newRequest request: URLRequest) async -> URLRequest? { nil }
}


/// Replaces `keydillo:<name>` placeholders (optionally with a format prefix such as `sk-`) with the real key.
public struct PlaceholderSubstitution {
  let service: String
  let value: String
  public init(service: String, value: String) { self.service = service; self.value = value }

  var regex: NSRegularExpression {
    let name = NSRegularExpression.escapedPattern(for: service)
    // An optional key-format prefix like "sk-" or "sk_test_" belongs to the placeholder; "bot" in "/botkeydillo:x" doesn't.
    let hint = NSRegularExpression.escapedPattern(for: Placeholder.hint)
    return try! NSRegularExpression(pattern: "(?:[A-Za-z0-9]+[-_])*keydillo(?::|%3A|%3a)\(name)(?:(?::|%3A|%3a)\(hint))?(?![A-Za-z0-9\\-])")
  }

  public func apply(_ s: String, urlEncoded: Bool) -> String {
    guard s.contains("keydillo") else { return s }
    let replacement = urlEncoded ? (value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?#/"))) ?? value) : value
    return regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: NSRegularExpression.escapedTemplate(for: replacement))
  }

  public func apply(_ body: Data) -> Data {
    guard body.range(of: Data("keydillo".utf8)) != nil, let text = String(data: body, encoding: .utf8) else {
      // Not UTF-8 (binary upload): swap exact byte runs only.
      var out = body
      for needle in [Placeholder.value(for: service), Placeholder.prefix + service].map({ Data($0.utf8) }) {
        while let r = out.range(of: needle) { out.replaceSubrange(r, with: Data(value.utf8)) }
      }
      return out
    }
    return Data(apply(text, urlEncoded: false).utf8)
  }
}
