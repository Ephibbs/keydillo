import XCTest
import LocalAuthentication
import Network
@testable import VaultCore

final class StubApprover: Approver, @unchecked Sendable {
  var answer = true
  var calls = 0
  func approve(_ request: ApprovalRequest) async -> ApprovalResult {
    calls += 1
    return answer ? .approved(nil) : .denied
  }
}

final class MemorySecrets: SecretProvider {
  var values: [String: Data] = [:]
  func secret(for name: String, context: LAContext?) throws -> Data {
    guard let v = values[name] else { throw VaultError.keyNotFound(name) }
    return v
  }
}

/// Tiny upstream that echoes the request line and headers back as the body.
final class EchoServer: @unchecked Sendable {
  let listener: NWListener
  var port: UInt16 { listener.port!.rawValue }
  init() throws {
    listener = try NWListener(using: .tcp, on: .any)
    listener.newConnectionHandler = { c in
      c.start(queue: .global())
      c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, _, _ in
        let text = String(decoding: data ?? Data(), as: UTF8.self)
        let head = text.components(separatedBy: "\r\n\r\n").first ?? ""
        let body = Data(head.utf8)
        let resp = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nX-Echo-Key: \(head.contains("sk_TESTSECRET123") ? "sk_TESTSECRET123" : "none")\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        c.send(content: Data(resp.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
      }
    }
    let ready = DispatchSemaphore(value: 0)
    listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
    listener.start(queue: .global())
    ready.wait()
  }
}

final class ParserTests: XCTestCase {
  func testParsesRequestWithBody() {
    let raw = Data("POST /elevenlabs/v1/x?a=1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 5\r\n\r\nhello".utf8)
    guard case .complete(let r, let n) = HTTPParser.parse(raw) else { return XCTFail() }
    XCTAssertEqual(r.method, "POST"); XCTAssertEqual(r.target, "/elevenlabs/v1/x?a=1")
    XCTAssertEqual(r.body, Data("hello".utf8)); XCTAssertEqual(n, raw.count)
  }
  func testIncompleteBody() {
    XCTAssertEqual(HTTPParser.parse(Data("POST / HTTP/1.1\r\nContent-Length: 10\r\n\r\nabc".utf8)), .incomplete)
  }
  func testDecodesChunkedBody() {
    let raw = Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n".utf8)
    guard case .complete(let r, let n) = HTTPParser.parse(raw) else { return XCTFail() }
    XCTAssertEqual(String(decoding: r.body, as: UTF8.self), "hello world"); XCTAssertEqual(n, raw.count)
    XCTAssertEqual(HTTPParser.parse(raw.prefix(raw.count - 4)), .incomplete)
  }
}

final class RuleTests: XCTestCase {
  func testPathRules() {
    let svc = ServiceConfig(name: "elevenlabs", upstreamHost: "api.elevenlabs.io", authHeader: "xi-api-key",
                            allowed: [PathRule(method: "POST", pattern: "/v1/text-to-speech/*"), PathRule(method: "GET", pattern: "/v1/voices")])
    XCTAssertTrue(svc.permits(method: "POST", path: "/v1/text-to-speech/abc"))
    XCTAssertFalse(svc.permits(method: "GET", path: "/v1/text-to-speech/abc"))
    XCTAssertTrue(svc.permits(method: "get", path: "/v1/voices"))
    XCTAssertFalse(svc.permits(method: "DELETE", path: "/v1/voices"))
  }
  func testValidation() {
    XCTAssertThrowsError(try ServiceConfig(name: "x", upstreamHost: "evil.com", upstreamScheme: "http", authHeader: "k").validate())
    XCTAssertNoThrow(try ServiceConfig(name: "x", upstreamHost: "127.0.0.1:9", upstreamScheme: "http", authHeader: "k").validate())
    XCTAssertThrowsError(try ServiceConfig(name: "Bad Name", upstreamHost: "a.com", authHeader: "k").validate())
    XCTAssertEqual(ServiceConfig(name: "eleven-labs", upstreamHost: "a", authHeader: "k").envVarName, "ELEVEN_LABS_API_KEY")
    XCTAssertEqual(Placeholder.service(in: "Bearer keydillo:openai-oda"), "openai-oda")
    XCTAssertNil(Placeholder.service(in: "sk-real"))
    XCTAssertEqual(Placeholder.service(in: "keydillo:openai:start-with-keydillo-run"), "openai")
    let sub = PlaceholderSubstitution(service: "openai", value: "REAL")
    XCTAssertEqual(sub.apply("Bearer keydillo:openai:start-with-keydillo-run", urlEncoded: false), "Bearer REAL")
    XCTAssertEqual(sub.apply("Bearer keydillo:openai", urlEncoded: false), "Bearer REAL")
    XCTAssertEqual(sub.apply("/bot" + "keydillo%3Aopenai%3Astart-with-keydillo-run/x", urlEncoded: true), "/botREAL/x")
  }
  func testRedaction() {
    let s = Data("sk_TESTSECRET123".utf8)
    XCTAssertEqual(String(decoding: ProxyEngine.redact(Data("a sk_TESTSECRET123 b".utf8), secret: s), as: UTF8.self), "a [redacted by keydillo: key] b")
  }
}

final class GateTests: XCTestCase {
  let client = ClientProcess(pid: 42, name: "curl", agent: "claude", startTime: 1)
  func req(_ s: ServiceConfig) -> ApprovalRequest {
    ApprovalRequest(service: s.name, displayName: s.displayName, host: s.upstreamHost, method: "GET", path: "/", client: client)
  }
  func testEachRequestPromptsEveryTimeOutsideABurst() async {
    let a = StubApprover()
    final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 0) }
    let clock = Clock()
    let gate = ApprovalGate(approver: a, now: { clock.t })
    let s = ServiceConfig(name: "x", upstreamHost: "h", authHeader: "k", approval: .eachRequest)
    _ = await gate.authorize(s, req(s)); _ = await gate.authorize(s, req(s))
    XCTAssertEqual(a.calls, 1, "calls within the burst window share one Touch ID")
    clock.t = clock.t.addingTimeInterval(5)
    _ = await gate.authorize(s, req(s))
    XCTAssertEqual(a.calls, 2)
  }
  func testWindowReusesUntilExpiry() async {
    let a = StubApprover()
    final class Clock: @unchecked Sendable { var t = Date(timeIntervalSince1970: 0) }
    let clock = Clock()
    let gate = ApprovalGate(approver: a, now: { clock.t })
    let s = ServiceConfig(name: "x", upstreamHost: "h", authHeader: "k", approval: .window(minutes: 15))
    _ = await gate.authorize(s, req(s)); _ = await gate.authorize(s, req(s))
    XCTAssertEqual(a.calls, 1)
    clock.t = clock.t.addingTimeInterval(16 * 60)
    _ = await gate.authorize(s, req(s))
    XCTAssertEqual(a.calls, 2)
  }
  func testPerProcessIsScopedToPid() async {
    let a = StubApprover(); let gate = ApprovalGate(approver: a)
    let s = ServiceConfig(name: "x", upstreamHost: "h", authHeader: "k", approval: .perProcess)
    _ = await gate.authorize(s, req(s)); _ = await gate.authorize(s, req(s))
    var other = req(s); other.client.pid = 43
    _ = await gate.authorize(s, other)
    XCTAssertEqual(a.calls, 2)
  }
  func testDeniedIsNotRemembered() async {
    let a = StubApprover(); a.answer = false; let gate = ApprovalGate(approver: a)
    let s = ServiceConfig(name: "x", upstreamHost: "h", authHeader: "k", approval: .window(minutes: 5))
    guard case .denied = await gate.authorize(s, req(s)) else { return XCTFail() }
    _ = await gate.authorize(s, req(s))
    XCTAssertEqual(a.calls, 2)
  }
}

final class EndToEndTests: XCTestCase {
  func fetch(_ url: String, method: String = "GET", headers: [String: String] = [:]) async throws -> (Int, String, [AnyHashable: Any]) {
    var r = URLRequest(url: URL(string: url)!); r.httpMethod = method
    for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
    let (d, resp) = try await URLSession(configuration: .ephemeral).data(for: r)
    let h = resp as! HTTPURLResponse
    return (h.statusCode, String(decoding: d, as: UTF8.self), h.allHeaderFields)
  }

  func testProxyInjectsKeyAndRedactsEcho() async throws {
    let echo = try EchoServer()
    let secrets = MemorySecrets(); secrets.values["echo"] = Data("sk_TESTSECRET123".utf8)
    let approver = StubApprover()
    let svc = ServiceConfig(name: "echo", upstreamHost: "127.0.0.1:\(echo.port)", upstreamScheme: "http", authHeader: "xi-api-key",
                            allowed: [PathRule(method: "*", pattern: "/v1/*")])
    let engine = ProxyEngine(services: { [svc] }, secrets: secrets, approver: approver)
    var events: [ActivityEvent] = []
    engine.onEvent = { events.append($0) }
    let server = ProxyServer(port: 18787, engine: engine)
    server.identify = { _, _ in ClientProcess(pid: 1, name: "test") }
    try server.start(); defer { server.stop() }
    try await Task.sleep(nanoseconds: 200_000_000)

    // Agent tries to supply its own key header: must be replaced, not forwarded.
    let (status, body, headers) = try await fetch("http://127.0.0.1:18787/echo/v1/voices?x=1", headers: ["xi-api-key": "agent-supplied"])
    XCTAssertEqual(status, 200)
    XCTAssertTrue(body.contains("GET /v1/voices?x=1"), body)
    XCTAssertTrue(body.contains("[redacted by keydillo: Echo key]"), "upstream saw the injected key, echo was redacted")
    XCTAssertFalse(body.contains("sk_TESTSECRET123"))
    XCTAssertFalse(body.contains("agent-supplied"))
    XCTAssertEqual(headers["X-Echo-Key"] as? String, "[redacted by keydillo: Echo key]")
    XCTAssertEqual(approver.calls, 1)

    // Path outside the rules is blocked before approval.
    let (s2, _, _) = try await fetch("http://127.0.0.1:18787/echo/admin")
    XCTAssertEqual(s2, 403); XCTAssertEqual(approver.calls, 1)

    // Unknown service.
    let (s3, _, _) = try await fetch("http://127.0.0.1:18787/nope/v1/x")
    XCTAssertEqual(s3, 404)

    // Denied approval never reads the key (after the burst window, which shares one approval between parallel calls).
    try await Task.sleep(nanoseconds: 3_200_000_000)
    approver.answer = false
    let (s4, b4, _) = try await fetch("http://127.0.0.1:18787/echo/v1/voices")
    XCTAssertEqual(s4, 403); XCTAssertFalse(b4.contains("sk_"))
    XCTAssertEqual(events.map(\.outcome), [.sent, .blocked, .blocked, .denied])
  }
}

final class ControlTests: XCTestCase {
  func testRoundTripOverSocket() throws {
    let path = NSTemporaryDirectory() + "kd-\(UUID().uuidString.prefix(6)).sock"
    try ControlSocket.serve(path: path) { req, caller in
      XCTAssertEqual(caller.pid, getpid(), "peer identified by the kernel")
      if case .requestSecret(let r) = req {
        let svc = ServiceConfig(name: r.service, upstreamHost: r.host, authHeader: r.header).summary(port: 7787)
        return .saved(svc, envLines: svc.placeholderEnvLines)
      }
      return .services([])
    }
    Thread.sleep(forTimeInterval: 0.1)
    let resp = try ControlSocket.send(.requestSecret(SecretRequest(service: "elevenlabs", host: "api.elevenlabs.io", header: "xi-api-key")), path: path)
    guard case .saved(let s, let lines) = resp else { return XCTFail("\(resp)") }
    XCTAssertEqual(s.baseURL, "http://localhost:7787/elevenlabs")
    XCTAssertEqual(lines, ["ELEVENLABS_BASE_URL=http://localhost:7787/elevenlabs", "ELEVENLABS_API_KEY=keydillo:elevenlabs:start-with-keydillo-run"])
  }
}

final class HostApprover: Approver, @unchecked Sendable {
  var allowNewHost = true
  var newHostAsks: [String] = []
  func approve(_ request: ApprovalRequest) async -> ApprovalResult { .approved(nil) }
  func approveNewHost(_ request: ApprovalRequest) async -> ApprovalResult {
    newHostAsks.append(request.host); return allowNewHost ? .approved(nil) : .denied
  }
}

final class HostOnFirstUseTests: XCTestCase {
  func req(_ target: String, _ headers: String = "") -> HTTPRequest {
    guard case .complete(let r, _) = HTTPParser.parse(Data("GET \(target) HTTP/1.1\r\nHost: localhost:7787\r\n\(headers)\r\n".utf8)) else { fatalError() }
    return r
  }

  func testAKeyIsLockedToItsHostOnFirstUseAndEachNewHostNeedsItsOwnApproval() async throws {
    let echo = try EchoServer(), other = try EchoServer()
    let secrets = MemorySecrets(); secrets.values["tg"] = Data("sk_TESTSECRET123".utf8)
    var svc = ServiceConfig(name: "tg", upstreamHost: "", upstreamScheme: "http", authHeader: "x-api-key", approval: .perProcess)
    let approver = HostApprover()
    let engine = ProxyEngine(services: { [svc] }, secrets: secrets, approver: approver)
    engine.onHostAdded = { _, h in if svc.upstreamHost.isEmpty { svc.upstreamHost = h } else { svc.extraHosts = (svc.extraHosts ?? []) + [h] } }
    let client = ClientProcess(pid: 1, name: "test", startTime: 1)

    // No host yet, and nobody said where it's going: a clear refusal.
    let r0 = await engine.handle(req("/tg/v1/x"), client: client)
    XCTAssertEqual(r0.status, 409); XCTAssertTrue(String(decoding: r0.body, as: UTF8.self).contains("needs_host"))

    // kd saw it go to a host: one explicit approval naming the host, then the key is locked there.
    let first = "127.0.0.1:\(echo.port)"
    let r1 = await engine.handle(req("/tg/v1/x", "X-Keydillo-Target-Host: \(first)\r\n"), client: client)
    XCTAssertEqual(r1.status, 200); XCTAssertEqual(approver.newHostAsks, [first]); XCTAssertEqual(svc.upstreamHost, first)

    // Same host again: no new-host prompt.
    _ = await engine.handle(req("/tg/v1/x", "X-Keydillo-Target-Host: \(first)\r\n"), client: client)
    XCTAssertEqual(approver.newHostAsks.count, 1)

    // Another host: asked again even though the key is already approved for this caller; declining refuses it.
    approver.allowNewHost = false
    let second = "127.0.0.1:\(other.port)"
    let r2 = await engine.handle(req("/tg/v1/x", "X-Keydillo-Target-Host: \(second)\r\n"), client: client)
    XCTAssertEqual(r2.status, 403); XCTAssertTrue(String(decoding: r2.body, as: UTF8.self).contains("host_not_allowed"))
    XCTAssertEqual(approver.newHostAsks, [first, second]); XCTAssertNil(svc.extraHosts)

    // Approving adds it to the key's hosts.
    approver.allowNewHost = true
    let r3 = await engine.handle(req("/tg/v1/x", "X-Keydillo-Target-Host: \(second)\r\n"), client: client)
    XCTAssertEqual(r3.status, 200); XCTAssertEqual(svc.extraHosts ?? [], [second])
    XCTAssertEqual(svc.allHosts, [first, second])
  }

  func testLaunchTimeKeysAreNeverSentOverTheNetwork() async {
    let secrets = MemorySecrets(); secrets.values["jwt"] = Data("s3cret".utf8)
    var svc = ServiceConfig(name: "jwt", upstreamHost: "", authHeader: ""); svc.launchTime = true
    let engine = ProxyEngine(services: { [svc] }, secrets: secrets, approver: HostApprover())
    let r = await engine.handle(req("/jwt/x", "X-Keydillo-Target-Host: example.com\r\n"), client: ClientProcess(pid: 1, name: "t", startTime: 1))
    XCTAssertEqual(r.status, 409); XCTAssertTrue(String(decoding: r.body, as: UTF8.self).contains("launch_time_key"))
    XCTAssertEqual(svc.summary(port: 7787).launchTime, true)
  }

  func testUnknownKeysGetHostHintsFromTheirName() {
    let s = ServiceConfig(name: "together", upstreamHost: "", authHeader: "Authorization", envVarName: "TOGETHER_API_KEY")
    XCTAssertEqual(s.hostTokens, ["together"])
  }
}

final class ChangeRequestTests: XCTestCase {
  func testMCPToolSendsTheChangeAndReportsTheAnswer() throws {
    var sent: ControlRequest?
    let mcp = MCPServer(cwd: "/tmp", send: { sent = $0; return .changed("done") })
    XCTAssertTrue(mcp.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)!.contains("request_key_change"))
    let out = mcp.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"request_key_change","arguments":{"kind":"auth","service":"openai","header":"Authorization","prefix":"Bearer "}}}"#)!
    XCTAssertTrue(out.contains("The user approved: done"), out)
    guard case .requestChange(let r) = sent else { return XCTFail() }
    XCTAssertEqual(r.kind, .auth); XCTAssertEqual(r.header, "Authorization"); XCTAssertEqual(r.prefix, "Bearer ")
    let bad = mcp.handle(line: #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"request_key_change","arguments":{"kind":"show_key"}}}"#)!
    XCTAssertTrue(bad.contains("isError"), bad)
  }

  func testMoveFolderRules() {
    let home = "/Users/u"
    XCTAssertNil(ProjectFolders.problem(old: "/Users/u/Desktop/app", new: "/Users/u/code/app", home: home))
    XCTAssertNotNil(ProjectFolders.problem(old: "/Users/u/Desktop/app", new: "/Users/u/Desktop", home: home))
    XCTAssertNotNil(ProjectFolders.problem(old: "/Users/u/code/app", new: "/Users/u", home: home))
    XCTAssertNotNil(ProjectFolders.problem(old: "/Users/u/code/app", new: "/Users/u/code", home: home), "a folder containing the old one")
    XCTAssertNotNil(ProjectFolders.problem(old: "/x/app", new: "relative/path", home: home))
  }
}

final class CallerNameTests: XCTestCase {
  func testNamesCantBeBorrowed() {
    XCTAssertEqual(ClientProcess(pid: 1, name: "Claude Code").friendlyName, "Claude Code (unverified)")
    XCTAssertEqual(ClientProcess(pid: 1, name: "node", agent: "claude", agentPid: 2).friendlyName, "claude (unverified)")
    var verified = ClientProcess(pid: 1, name: "node", agent: "claude", agentPid: 2)
    verified.agentVerified = true
    XCTAssertEqual(verified.friendlyName, "Claude Code")
    XCTAssertEqual(ClientProcess(pid: 1, name: "python3").friendlyName, "python3")
  }
}

final class MCPTests: XCTestCase {
  func testOpenProject() throws {
    var sent: ControlRequest?
    let mcp = MCPServer(cwd: "/Users/x/Desktop/voiceover", send: { req in
      sent = req
      return .opened(project: "voiceover", services: ["elevenlabs", "openai"], span: "for 8 hours")
    })
    XCTAssertTrue(mcp.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)!.contains("open_project"))
    let out = mcp.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"open_project","arguments":{}}}"#)!
    XCTAssertTrue(out.contains("elevenlabs, openai") && out.contains("for 8 hours"), out)
    guard case .openProject(let r) = sent else { return XCTFail() }
    XCTAssertNil(r.project)   // the app works out the project from the caller's folder
    // Round-trips over the control socket encoding.
    let d = try JSONEncoder().encode(ControlResponse.opened(project: "p", services: ["a"], span: "for 1 hour"))
    XCTAssertEqual(try JSONDecoder().decode(ControlResponse.self, from: d), .opened(project: "p", services: ["a"], span: "for 1 hour"))
  }

  func testToolsAndRequestSecret() throws {
    var sent: ControlRequest?
    let mcp = MCPServer(cwd: "/Users/x/Desktop/notes-app", send: { req in
      sent = req
      let s = ServiceConfig(name: "elevenlabs", upstreamHost: "api.elevenlabs.io", authHeader: "xi-api-key").summary(port: 7787)
      return .saved(s, envLines: s.placeholderEnvLines)
    })
    XCTAssertNil(mcp.handle(line: #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#))
    XCTAssertTrue(mcp.handle(line: #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)!.contains("request_secret"))
    let out = mcp.handle(line: #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"request_secret","arguments":{"service":"ElevenLabs","host":"api.elevenlabs.io","header":"xi-api-key"}}}"#)!
    XCTAssertTrue(out.contains("http://localhost:7787/elevenlabs"), out)
    guard case .requestSecret(let r) = sent else { return XCTFail() }
    XCTAssertEqual(r.service, "elevenlabs"); XCTAssertEqual(r.project, "notes-app")
  }
}

final class PortTests: XCTestCase {
  func testFindsBusyAndFreePorts() throws {
    let fd = socket(AF_INET, SOCK_STREAM, 0); defer { close(fd) }
    var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_port = 0; addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    Darwin.listen(fd, 1)
    var len = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
    let p = UInt16(bigEndian: addr.sin_port)
    XCTAssertFalse(Ports.isFree(p))
    XCTAssertNotEqual(Ports.firstFree(from: p), p)
  }
}

final class ImportTests: XCTestCase {
  let env = """
  # app
  PORT=3000
  NEXT_PUBLIC_SUPABASE_ANON_KEY=eyJhbGciOiJIUzI1NiJ9.public
  SUPABASE_URL=https://xyz.supabase.co
  export ANTHROPIC_API_KEY="sk-ant-api03-abcdefghijklmnop"
  ELEVENLABS_API_KEY=abcdef0123456789abcdef # voice
  GOOGLE_CLIENT_SECRET=GOCSPX-abcdefghijklmnop
  SHORT_TOKEN=abc
  DONE_KEY=keydillo:done
  """

  func testParseFindsOnlySecrets() {
    let all = ImportScanner.parse(env, file: "/x/.env")
    XCTAssertEqual(all.filter(\.isPublic).map(\.name), ["NEXT_PUBLIC_SUPABASE_ANON_KEY"])
    let found = all.filter { !$0.isPublic }
    XCTAssertEqual(found.map(\.name), ["ANTHROPIC_API_KEY", "ELEVENLABS_API_KEY", "GOOGLE_CLIENT_SECRET"])
    XCTAssertEqual(found[0].value, "sk-ant-api03-abcdefghijklmnop")
    XCTAssertEqual(found[1].value, "abcdef0123456789abcdef")
    XCTAssertEqual(found[0].service?.host, "api.anthropic.com")
    XCTAssertNil(found[2].service)
  }

  func testPublicKeysAreFlagged() {
    let anon = "eyJhbGciOiJIUzI1NiJ9." + Data(#"{"role":"anon"}"#.utf8).base64EncodedString() + ".sig"
    let svc = "eyJhbGciOiJIUzI1NiJ9." + Data(#"{"role":"service_role"}"#.utf8).base64EncodedString() + ".sig"
    let text = """
    STRIPE_PUBLISHABLE_KEY=pk_test_abcdefghijklmnop
    STRIPE_KEY=pk_live_abcdefghijklmnop
    STRIPE_SECRET_KEY=sk_test_abcdefghijklmnop
    SUPABASE_KEY=\(anon)
    SUPABASE_SERVICE_KEY=\(svc)
    FIREBASE_API_KEY=AIzaSyAbcdefghijklmnop
    FIREBASE_AUTH_DOMAIN=x.firebaseapp.com
    NEXT_PUBLIC_POSTHOG_KEY=phc_abcdefghijklmnop
    """
    let f = Dictionary(uniqueKeysWithValues: ImportScanner.parse(text, file: "/x/.env").map { ($0.name, $0.isPublic) })
    XCTAssertEqual(f["STRIPE_PUBLISHABLE_KEY"], true); XCTAssertEqual(f["STRIPE_KEY"], true); XCTAssertEqual(f["STRIPE_SECRET_KEY"], false)
    XCTAssertEqual(f["SUPABASE_KEY"], true); XCTAssertEqual(f["SUPABASE_SERVICE_KEY"], false)
    XCTAssertEqual(f["FIREBASE_API_KEY"], true); XCTAssertEqual(f["NEXT_PUBLIC_POSTHOG_KEY"], true)
  }

  func testRewriteKeepsEverythingElse() {
    let out = ImportScanner.rewrite(env, replacements: [
      "ANTHROPIC_API_KEY": ("anthropic", "http://localhost:7787/anthropic", "ANTHROPIC_BASE_URL"),
      "GOOGLE_CLIENT_SECRET": ("google-client-secret", nil, nil),
    ])
    XCTAssertTrue(out.contains("export ANTHROPIC_API_KEY=keydillo:anthropic:start-with-keydillo-run"))
    XCTAssertTrue(out.contains("GOOGLE_CLIENT_SECRET=keydillo:google-client-secret:start-with-keydillo-run"))
    XCTAssertTrue(out.contains("ANTHROPIC_BASE_URL=http://localhost:7787/anthropic"))
    XCTAssertTrue(out.contains("ELEVENLABS_API_KEY=abcdef0123456789abcdef # voice"))
    XCTAssertTrue(out.contains("PORT=3000"))
    XCTAssertFalse(out.contains("sk-ant-api03"))
    XCTAssertTrue(out.hasPrefix(ImportScanner.headerStart))
    // Idempotent, and keydillo's additions come back out cleanly.
    let again = ImportScanner.rewrite(out, replacements: [:])
    XCTAssertEqual(again.components(separatedBy: ImportScanner.headerStart).count, 2)
    let stripped = ImportScanner.stripKeydilloLines(out)
    XCTAssertFalse(stripped.contains("keydillo ---")); XCTAssertFalse(stripped.contains("ANTHROPIC_BASE_URL"))
    XCTAssertTrue(stripped.contains("PORT=3000"))
  }

  func testScanSkipsExamplesAndNodeModules() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("kdscan-\(UUID().uuidString)")
    let proj = root.appendingPathComponent("myapp")
    try FileManager.default.createDirectory(at: proj.appendingPathComponent("node_modules/x"), withIntermediateDirectories: true)
    try "OPENAI_API_KEY=sk-proj-0123456789abcdef".write(to: proj.appendingPathComponent(".env.local"), atomically: true, encoding: .utf8)
    try "OPENAI_API_KEY=sk-proj-0123456789abcdef".write(to: proj.appendingPathComponent(".env.example"), atomically: true, encoding: .utf8)
    try "OPENAI_API_KEY=sk-proj-0123456789abcdef".write(to: proj.appendingPathComponent("node_modules/x/.env"), atomically: true, encoding: .utf8)
    let r = ImportScanner.scan(roots: [root])
    XCTAssertEqual(r.count, 1)
    XCTAssertEqual(r[0].project, "myapp")
    XCTAssertEqual(r[0].keys.first?.service?.service, "openai")
  }
}

final class StreamingTests: XCTestCase {
  func testQueryParamKeyAndChunkedStream() async throws {
    let echo = try EchoServer()
    let secrets = MemorySecrets(); secrets.values["q"] = Data("sk_TESTSECRET123".utf8)
    var svc = ServiceConfig(name: "q", upstreamHost: "127.0.0.1:\(echo.port)", upstreamScheme: "http", authHeader: "")
    svc.authQueryParam = "key"
    let engine = ProxyEngine(services: { [svc] }, secrets: secrets, approver: StubApprover())
    var events: [ActivityEvent] = []
    engine.onEvent = { events.append($0) }
    let server = ProxyServer(port: 18788, engine: engine)
    server.identify = { _, _ in ClientProcess(pid: 1, name: "test") }
    try server.start(); defer { server.stop() }
    try await Task.sleep(nanoseconds: 200_000_000)
    let (d, r) = try await URLSession(configuration: .ephemeral).data(from: URL(string: "http://127.0.0.1:18788/q/v1/x?a=1&key=agent")!)
    let body = String(decoding: d, as: UTF8.self)
    XCTAssertEqual((r as! HTTPURLResponse).statusCode, 200)
    XCTAssertTrue(body.contains("GET /v1/x?a=1&key=[redacted by keydillo: Q key]"), body)
    XCTAssertFalse(body.contains("agent"))
    XCTAssertEqual(events.last?.path, "/v1/x")   // no query string in logs
  }
}

final class SecurityTests: XCTestCase {
  func testStrictHosts() {
    func ok(_ h: String) -> Bool { UpstreamTarget(ServiceConfig(name: "x", upstreamHost: h, authHeader: "k")) != nil }
    XCTAssertTrue(ok("api.stripe.com")); XCTAssertTrue(ok("api.stripe.com:8443")); XCTAssertTrue(ok("API.Stripe.com"))
    for bad in ["evil.io:443#.stripe.com", "evil.io?.stripe.com", "evil.io/.stripe.com", "user@evil.io", "evil.io:99999", "évil.io", "a..b", " api.x.com", "api.x.com:"] {
      XCTAssertFalse(ok(bad), bad)
    }
    XCTAssertThrowsError(try ServiceConfig(name: "x", upstreamHost: "evil.io:443#.stripe.com", authHeader: "k").validate())
  }

  func testRedactsEveryForm() {
    let forms = ProxyEngine.redactionForms(raw: "sk_TESTSECRET123", keyValue: "Basic " + Data("sk_TESTSECRET123:".utf8).base64EncodedString())
    for leak in ["sk_TESTSECRET123", Data("sk_TESTSECRET123:".utf8).base64EncodedString(), Data("sk_TESTSECRET123".utf8).base64EncodedString()] {
      XCTAssertFalse(String(decoding: ProxyEngine.redact(Data("x \(leak) y".utf8), forms: forms), as: UTF8.self).contains(leak), leak)
    }
  }

  func testPlaceholderOnlyInItsSpot() async throws {
    let echo = try EchoServer()
    let secrets = MemorySecrets(); secrets.values["h"] = Data("sk_TESTSECRET123".utf8); secrets.values["any"] = Data("sk_TESTSECRET456".utf8)
    let h = ServiceConfig(name: "h", upstreamHost: "127.0.0.1:\(echo.port)", upstreamScheme: "http", authHeader: "x-api-key")
    var any = ServiceConfig(name: "any", upstreamHost: "127.0.0.1:\(echo.port)", upstreamScheme: "http", authHeader: "")
    any.placeholderAnywhere = true
    let approver = StubApprover()
    let engine = ProxyEngine(services: { [h, any] }, secrets: secrets, approver: approver)
    func req(_ target: String, _ headers: [(String, String)] = [], body: String = "") -> HTTPRequest {
      HTTPRequest(method: body.isEmpty ? "GET" : "POST", target: target, headers: [("Host", "localhost")] + headers, body: Data(body.utf8))
    }
    let c = ClientProcess(pid: 1, name: "t")
    for r in [req("/h/v1/x?q=keydillo:h"), req("/h/bot" + "keydillo:h/x"), req("/h/v1/x", [("X-Other", "keydillo:h")]), req("/h/v1/x", body: "{\"k\":\"keydillo:h\"}")] {
      let resp = await engine.handle(r, client: c)
      XCTAssertEqual(resp.status, 400, r.target)
      XCTAssertTrue(String(decoding: resp.body, as: UTF8.self).contains("placeholder_misplaced"))
    }
    XCTAssertEqual(approver.calls, 0, "refused before asking for Touch ID")
    for t in ["/h/public/.%2e/secret", "/h/public/%2e./secret", "/h/public/%2e%2E/secret", "/h/a%2Fb", "/h/x/../y"] {
      let r = await engine.handle(req(t), client: c)
      XCTAssertEqual(r.status, 400, t)
    }
    let okResp = await engine.handle(req("/h/v1/x", [("x-api-key", "keydillo:h")]), client: c)
    XCTAssertEqual(okResp.status, 200)
    let anyResp = await engine.handle(req("/any/v1/x", body: "{\"k\":\"keydillo:any\"}"), client: c)
    XCTAssertEqual(anyResp.status, 200)
  }
}

final class CallerScopeTests: XCTestCase {
  func req(_ s: ServiceConfig, _ c: ClientProcess) -> ApprovalRequest {
    ApprovalRequest(service: s.name, displayName: s.displayName, host: s.upstreamHost, method: "GET", path: "/", client: c)
  }
  func testApprovalsBelongToTheCallersTree() async {
    let a = StubApprover(); let gate = ApprovalGate(approver: a)
    let s = ServiceConfig(name: "x", upstreamHost: "h", authHeader: "k", approval: .perProcess)
    var c1 = ClientProcess(pid: 100, name: "curl", startTime: 5); c1.rootPid = 10; c1.rootStart = 1
    var c2 = ClientProcess(pid: 101, name: "python3", startTime: 6); c2.rootPid = 10; c2.rootStart = 1
    var other = ClientProcess(pid: 200, name: "curl", startTime: 7); other.rootPid = 20; other.rootStart = 2
    _ = await gate.authorize(s, req(s, c1)); _ = await gate.authorize(s, req(s, c2))
    XCTAssertEqual(a.calls, 1, "same terminal/session shares the approval")
    _ = await gate.authorize(s, req(s, other))
    XCTAssertEqual(a.calls, 2, "another process tree gets its own prompt")
  }
  func testUnidentifiedCallersAreNeverCached() async {
    let a = StubApprover(); let gate = ApprovalGate(approver: a)
    let s = ServiceConfig(name: "x", upstreamHost: "h", authHeader: "k", approval: .window(minutes: 15))
    _ = await gate.authorize(s, req(s, .unknown)); _ = await gate.authorize(s, req(s, .unknown))
    XCTAssertEqual(a.calls, 2)
  }
}

final class ImportClassificationTests: XCTestCase {
  func testLocalSecretsInterpolationAndPrefixes() {
    let text = """
    JWT_SECRET=abcdefghijklmnopqrstuvwxyz
    STRIPE_WEBHOOK_SECRET=whsec_abcdefghijklmnop
    RESEND_WEBHOOK_SECRET=abcdefghijklmnopqrst
    AWS_SECRET_ACCESS_KEY=abcdefghijklmnopqrstuvwxyz
    ENCRYPTION_KEY=0123456789abcdef0123456789abcdef
    OPENAI_KEY=${OPENAI_API_KEY}
    OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrst
    """
    let f = Dictionary(uniqueKeysWithValues: ImportScanner.parse(text, file: "/x/.env").map { ($0.name, $0) })
    for n in ["JWT_SECRET", "STRIPE_WEBHOOK_SECRET", "RESEND_WEBHOOK_SECRET", "AWS_SECRET_ACCESS_KEY", "ENCRYPTION_KEY"] {
      XCTAssertNotNil(f[n]?.localOnly, n)
    }
    XCTAssertNil(f["OPENAI_KEY"], "interpolation skipped")
    XCTAssertNil(f["OPENAI_API_KEY"]?.localOnly)
    XCTAssertEqual(f["OPENAI_API_KEY"]?.keyPrefix, "sk-proj-")
    XCTAssertEqual(ImportScanner.formatPrefix("sk_live_abc123"), "sk_live_")
    XCTAssertEqual(ImportScanner.formatPrefix("sk-ant-api03-xyz"), "sk-ant-api03-")
    XCTAssertEqual(ImportScanner.formatPrefix("abcdefghijklmnop"), "")
    let out = ImportScanner.rewrite("OPENAI_API_KEY=sk-proj-abc", replacements: ["OPENAI_API_KEY": ("openai", nil, nil)], prefixes: ["OPENAI_API_KEY": "sk-proj-"])
    XCTAssertTrue(out.contains("OPENAI_API_KEY=sk-proj-keydillo:openai:start-with-keydillo-run"))
    XCTAssertEqual(PlaceholderSubstitution(service: "openai", value: "REAL").apply("Bearer sk-proj-keydillo:openai:start-with-keydillo-run", urlEncoded: false), "Bearer REAL")
  }
}
