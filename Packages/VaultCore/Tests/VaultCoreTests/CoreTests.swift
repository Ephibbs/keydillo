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
  func testRejectsChunked() {
    guard case .invalid(411, _) = HTTPParser.parse(Data("POST / HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n".utf8)) else { return XCTFail() }
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
  func testEachRequestPromptsEveryTime() async {
    let a = StubApprover(); let gate = ApprovalGate(approver: a)
    let s = ServiceConfig(name: "x", upstreamHost: "h", authHeader: "k", approval: .eachRequest)
    _ = await gate.authorize(s, req(s)); _ = await gate.authorize(s, req(s))
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

    // Denied approval never reads the key.
    approver.answer = false
    let (s4, b4, _) = try await fetch("http://127.0.0.1:18787/echo/v1/voices")
    XCTAssertEqual(s4, 403); XCTAssertFalse(b4.contains("sk_"))
    XCTAssertEqual(events.map(\.outcome), [.sent, .blocked, .blocked, .denied])
  }
}

final class ControlTests: XCTestCase {
  func testRoundTripOverSocket() throws {
    let path = NSTemporaryDirectory() + "kd-\(UUID().uuidString.prefix(6)).sock"
    try ControlSocket.serve(path: path) { req in
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
    XCTAssertEqual(lines, ["ELEVENLABS_BASE_URL=http://localhost:7787/elevenlabs", "ELEVENLABS_API_KEY=keydillo-placeholder"])
  }
}

final class MCPTests: XCTestCase {
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
