import Foundation
import Security
import CryptoKit
import CommonCrypto
import Darwin

/// A Postgres connection string, split into the parts the local proxy needs.
public struct PostgresTarget: Equatable, Sendable {
  public var host: String
  public var port: Int
  public var user: String
  public var password: String
  public var database: String
  /// libpq's sslmode: disable, allow, prefer (default), require, verify-ca, verify-full.
  public var sslmode: String
  /// Other query parameters (kept on the local URL for the program, e.g. Prisma's `pgbouncer=true`).
  public var params: [(String, String)]

  public static func == (a: Self, b: Self) -> Bool {
    a.host == b.host && a.port == b.port && a.user == b.user && a.password == b.password && a.database == b.database
      && a.sslmode == b.sslmode && a.params.map { $0.0 + "=" + $0.1 } == b.params.map { $0.0 + "=" + $0.1 }
  }
}

public enum PostgresURL {
  public static func isPostgres(_ s: String) -> Bool {
    let l = s.lowercased()
    return l.hasPrefix("postgres://") || l.hasPrefix("postgresql://")
  }

  /// Parameters that only matter between keydillo and the real server, never on the local connection.
  static let serverSide: Set<String> = ["sslmode", "sslrootcert", "sslcert", "sslkey", "sslcrl", "sslpassword", "sslnegotiation",
                                        "channel_binding", "options", "host", "hostaddr", "port", "user", "password", "passfile"]

  public static func parse(_ s: String) -> PostgresTarget? {
    guard isPostgres(s), let c = URLComponents(string: s), let host = c.host, !host.isEmpty else { return nil }
    let items = c.queryItems ?? []
    let db = String(c.path.drop { $0 == "/" })
    return PostgresTarget(host: host, port: c.port ?? 5432, user: c.user ?? "postgres", password: c.password ?? "",
                          database: db.removingPercentEncoding ?? db,
                          sslmode: items.first { $0.name == "sslmode" }?.value ?? "prefer",
                          params: items.map { ($0.name, $0.value ?? "") })
  }

  /// The target when keydillo's local endpoint can stand in for this URL; nil means it stays a launch-time key that
  /// `kd` gives the program. Simple rule: anything needing files on disk (client certificates, a custom root
  /// certificate), channel binding, or several hosts goes through `kd` instead.
  public static func proxyable(_ s: String) -> PostgresTarget? {
    guard let t = parse(s), !t.host.contains(","), !t.host.hasPrefix("/") else { return nil }
    let names = Set(t.params.map { $0.0.lowercased() })
    if !names.isDisjoint(with: ["sslcert", "sslkey", "sslrootcert", "sslcrl", "sslpassword", "host", "hostaddr", "passfile"]) { return nil }
    if t.params.contains(where: { $0.0.lowercased() == "channel_binding" && $0.1.lowercased() == "require" }) { return nil }
    return t
  }

  /// The connection string a program gets instead: keydillo on this Mac, the key's name as the user, no password,
  /// the real database name (tools like Prisma's migrations switch databases by name) and the program's own options.
  public static func local(service: String, target: PostgresTarget, port: UInt16) -> String {
    var c = URLComponents()
    c.scheme = "postgresql"
    c.user = service
    c.host = "127.0.0.1"
    c.port = Int(port)
    c.path = "/" + target.database
    var items = target.params.filter { !serverSide.contains($0.0) }.map { URLQueryItem(name: $0.0, value: $0.1) }
    items.append(URLQueryItem(name: "sslmode", value: "disable"))
    c.queryItems = items
    return c.string ?? "postgresql://\(service)@127.0.0.1:\(port)/\(target.database)?sslmode=disable"
  }

  /// True for a connection string keydillo wrote (points at its local Postgres port).
  public static func isLocal(_ s: String, port: UInt16) -> Bool {
    guard let c = URLComponents(string: s), isPostgres(s) else { return false }
    return (c.host == "127.0.0.1" || c.host == "localhost") && c.port == Int(port)
  }
}

/// A byte stream to the real database: plain TCP, or TLS on top of it after Postgres's SSLRequest.
protocol PGStream: AnyObject {
  var fd: Int32 { get }
  func read(_ max: Int) -> Data?
  func write(_ d: Data) -> Bool
  /// Bytes already decrypted and waiting (so poll() on the socket alone would miss them).
  var buffered: Int { get }
  func close()
}

final class PlainStream: PGStream {
  let fd: Int32
  init(_ fd: Int32) { self.fd = fd }
  func read(_ max: Int) -> Data? {
    var buf = [UInt8](repeating: 0, count: max)
    let n = Darwin.read(fd, &buf, max)
    return n > 0 ? Data(buf[0..<n]) : nil
  }
  func write(_ d: Data) -> Bool { PostgresProxy.writeAll(fd, d) }
  var buffered: Int { 0 }
  func close() { Darwin.close(fd) }
}

/// TLS to the database. Network.framework can't start TLS on a connection that already exchanged plain bytes
/// (Postgres's SSLRequest), so this uses Secure Transport on the socket directly.
final class TLSStream: PGStream {
  let fd: Int32
  var ctx: SSLContext
  var fdBox: UnsafeMutablePointer<Int32>

  init?(fd: Int32, host: String, verify: Bool) {
    self.fd = fd
    guard let c = SSLCreateContext(nil, .clientSide, .streamType) else { return nil }
    ctx = c
    fdBox = UnsafeMutablePointer<Int32>.allocate(capacity: 1); fdBox.pointee = fd
    SSLSetIOFuncs(ctx, { conn, data, len in
      let fd = conn.assumingMemoryBound(to: Int32.self).pointee
      let want = len.pointee
      var got = 0
      while got < want {
        let n = Darwin.read(fd, data.advanced(by: got), want - got)
        if n > 0 { got += n; continue }
        len.pointee = got
        return n == 0 ? errSSLClosedGraceful : errSecIO
      }
      return noErr
    }, { conn, data, len in
      let fd = conn.assumingMemoryBound(to: Int32.self).pointee
      let want = len.pointee
      var sent = 0
      while sent < want {
        let n = Darwin.write(fd, data.advanced(by: sent), want - sent)
        if n > 0 { sent += n; continue }
        len.pointee = sent
        return errSecIO
      }
      return noErr
    })
    SSLSetConnection(ctx, fdBox)
    SSLSetPeerDomainName(ctx, host, host.utf8.count)
    // Like libpq: "require" encrypts without checking the certificate (Supabase and others use their own CA);
    // "verify-ca" / "verify-full" check it against the system's trusted roots.
    SSLSetSessionOption(ctx, .breakOnServerAuth, true)
    var status = SSLHandshake(ctx)
    while status == errSSLPeerAuthCompleted || status == errSSLWouldBlock {
      if status == errSSLPeerAuthCompleted && verify {
        var trust: SecTrust?
        SSLCopyPeerTrust(ctx, &trust)
        guard let t = trust else { return nil }
        SecTrustSetPolicies(t, SecPolicyCreateSSL(true, host as CFString))
        guard SecTrustEvaluateWithError(t, nil) else { return nil }
      }
      status = SSLHandshake(ctx)
    }
    guard status == noErr else { return nil }
  }

  func read(_ max: Int) -> Data? {
    var buf = [UInt8](repeating: 0, count: max)
    var n = 0
    let s = SSLRead(ctx, &buf, max, &n)
    if n > 0 { return Data(buf[0..<n]) }
    return s == noErr || s == errSSLWouldBlock ? Data() : nil
  }
  func write(_ d: Data) -> Bool {
    var sent = 0
    let s = d.withUnsafeBytes { SSLWrite(ctx, $0.baseAddress, d.count, &sent) }
    return s == noErr && sent == d.count
  }
  var buffered: Int { var n = 0; SSLGetBufferedReadSize(ctx, &n); return n }
  func close() { SSLClose(ctx); Darwin.close(fd); fdBox.deallocate() }
}

/// A local Postgres endpoint for database keys. Programs connect to 127.0.0.1 with the key's name as the user and
/// no password; keydillo asks for approval like any key, logs in to the real database with the real connection
/// string (TLS where the server offers it), and then passes the connection through unchanged.
/// The program never sees the password. It can still read and change the data, like any program you let use a database.
public final class PostgresProxy: @unchecked Sendable {
  /// Why a connection was refused, shown to the program as a Postgres error.
  public struct Refusal: Error, Sendable { public let message: String; public init(_ m: String) { message = m } }
  public typealias Resolve = @Sendable (_ service: String, _ database: String, _ caller: ClientProcess) async -> Result<PostgresTarget, Refusal>

  public let port: UInt16
  let resolve: Resolve
  var listenFD: Int32 = -1
  /// BackendKeyData (pid, secret) from each upstream session, so cancel requests reach the right server.
  var cancelTargets: [String: PostgresTarget] = [:]
  let lock = NSLock()

  public init(port: UInt16, resolve: @escaping Resolve) { self.port = port; self.resolve = resolve }

  public func start() throws {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { throw VaultError.invalidConfig("socket failed") }
    var yes: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    guard ok == 0, listen(fd, 64) == 0 else { Darwin.close(fd); throw VaultError.invalidConfig("port \(port) is in use") }
    listenFD = fd
    Thread.detachNewThread { [self] in
      while true {
        var peer = sockaddr_in(); var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let c = withUnsafeMutablePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { accept(fd, $0, &len) } }
        if c < 0 { if errno == EINTR { continue }; return }
        let clientPort = UInt16(bigEndian: peer.sin_port)
        Thread.detachNewThread { [self] in self.serve(c, clientPort: clientPort) }
      }
    }
  }

  public func stop() { if listenFD >= 0 { Darwin.close(listenFD); listenFD = -1 } }

  // MARK: One client connection

  func serve(_ client: Int32, clientPort: UInt16) {
    defer { Darwin.close(client) }
    var nosig: Int32 = 1
    setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
    // Startup: answer "no" to SSL and GSS encryption requests (the connection never leaves this Mac), then read the startup message.
    var startup: Data
    while true {
      guard let len = Self.readInt32(client), len >= 8, len < 10_000, let body = Self.readExact(client, Int(len) - 4) else { return }
      let code = body.prefix(4).withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) }
      if code == 80877103 || code == 80877104 { _ = Self.writeAll(client, Data("N".utf8)); continue }
      if code == 80877102 { forwardCancel(body); return }
      startup = body; break
    }
    let params = Self.startupParams(startup.dropFirst(4))
    let service = params["user"] ?? ""
    let database = params["database"] ?? ""
    let caller = ProcessLookup.process(connectedFrom: clientPort, to: port)

    let sem = DispatchSemaphore(value: 0)
    nonisolated(unsafe) var outcome: Result<PostgresTarget, Refusal> = .failure(Refusal("keydillo couldn't check this connection"))
    Task { outcome = await resolve(service, database, caller); sem.signal() }
    sem.wait()
    let target: PostgresTarget
    switch outcome {
    case .failure(let why): Self.sendError(client, code: "28000", why.message); return
    case .success(let t): target = t
    }

    guard let up = connectUpstream(target) else {
      Self.sendError(client, code: "08001", "keydillo couldn't connect to the database at \(target.host):\(target.port)"); return
    }
    defer { up.close() }
    // Log in with the real user and password; the program's own settings (application name, options) carry over.
    var out: [(String, String)] = [("user", target.user), ("database", database.isEmpty ? target.database : database)]
    for (k, v) in params where k != "user" && k != "database" { out.append((k, v)) }
    if let opts = target.params.first(where: { $0.0 == "options" })?.1, params["options"] == nil { out.append(("options", opts)) }
    guard up.write(Self.startupMessage(out)) else { return }
    var pending: Data
    switch authenticate(up, target) {
    case .failure(let message):
      if let m = message.raw { _ = Self.writeAll(client, m) } else { Self.sendError(client, code: "28000", message.text) }
      return
    case .success(let rest): pending = rest
    }
    // Tell the program it's logged in, then pass the server's messages through, noting the cancel key.
    _ = Self.writeAll(client, Self.message("R", Self.int32(0)))
    readyLoop: while true {
      while let (type, body, total) = Self.nextMessage(pending) {
        if type == UInt8(ascii: "K"), body.count >= 8 {
          lock.lock(); cancelTargets[body.prefix(8).base64EncodedString()] = target; lock.unlock()
        }
        _ = Self.writeAll(client, pending.prefix(total))
        pending.removeFirst(total)
        if type == UInt8(ascii: "Z") { break readyLoop }
      }
      guard let chunk = up.read(65536) else { return }
      pending.append(chunk)
    }
    if !pending.isEmpty { _ = Self.writeAll(client, pending) }
    pipe(client, up)
  }

  /// Copies bytes both ways until either side closes.
  func pipe(_ client: Int32, _ up: PGStream) {
    var fds = [pollfd(fd: client, events: Int16(POLLIN), revents: 0), pollfd(fd: up.fd, events: Int16(POLLIN), revents: 0)]
    var buf = [UInt8](repeating: 0, count: 65536)
    while true {
      if up.buffered == 0 {
        fds[0].revents = 0; fds[1].revents = 0
        guard poll(&fds, 2, -1) > 0 else { if errno == EINTR { continue }; return }
      }
      if up.buffered > 0 || fds[1].revents != 0 {
        guard let d = up.read(65536) else { return }
        if !d.isEmpty, !Self.writeAll(client, d) { return }
      }
      if fds[0].revents != 0 {
        let n = Darwin.read(client, &buf, buf.count)
        if n <= 0 { return }
        if !up.write(Data(buf[0..<n])) { return }
        fds[0].revents = 0
      }
    }
  }

  func connectUpstream(_ t: PostgresTarget) -> PGStream? {
    var hints = addrinfo(); hints.ai_socktype = SOCK_STREAM
    var res: UnsafeMutablePointer<addrinfo>?
    guard getaddrinfo(t.host, String(t.port), &hints, &res) == 0, let first = res else { return nil }
    defer { freeaddrinfo(res) }
    var fd: Int32 = -1
    var ai: UnsafeMutablePointer<addrinfo>? = first
    while let a = ai {
      fd = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
      if fd >= 0 {
        var tv = timeval(tv_sec: 15, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        if connect(fd, a.pointee.ai_addr, a.pointee.ai_addrlen) == 0 { break }
        Darwin.close(fd); fd = -1
      }
      ai = a.pointee.ai_next
    }
    guard fd >= 0 else { return nil }
    var nosig: Int32 = 1
    setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &nosig, socklen_t(MemoryLayout<Int32>.size))
    let mode = t.sslmode.lowercased()
    if mode == "disable" { return PlainStream(fd) }
    var req = Self.int32(8); req.append(Self.int32(80877103))
    guard Self.writeAll(fd, req), let answer = Self.readExact(fd, 1) else { Darwin.close(fd); return nil }
    if answer.first == UInt8(ascii: "S") {
      guard let tls = TLSStream(fd: fd, host: t.host, verify: mode == "verify-ca" || mode == "verify-full") else { Darwin.close(fd); return nil }
      return tls
    }
    if ["require", "verify-ca", "verify-full"].contains(mode) { Darwin.close(fd); return nil }
    return PlainStream(fd)
  }

  struct AuthFailure: Error { var text: String; var raw: Data? }

  /// Answers the server's password request: SCRAM-SHA-256, MD5 or cleartext.
  /// On success, returns any bytes the server already sent after AuthenticationOk.
  func authenticate(_ up: PGStream, _ t: PostgresTarget) -> Result<Data, AuthFailure> {
    var pending = Data()
    func next() -> (UInt8, Data, Data)? {
      while true {
        if let (type, body, total) = Self.nextMessage(pending) {
          let raw = pending.prefix(total); pending.removeFirst(total); return (type, body, Data(raw))
        }
        guard let d = up.read(65536) else { return nil }
        pending.append(d)
      }
    }
    var scram: SCRAM?
    while let (type, body, raw) = next() {
      switch type {
      case UInt8(ascii: "E"): return .failure(AuthFailure(text: "the database refused keydillo's login", raw: raw))
      case UInt8(ascii: "R"):
        let code = body.prefix(4).withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) }
        let rest = body.dropFirst(4)
        switch code {
        case 0:
          return .success(pending)
        case 3:
          var p = Data(t.password.utf8); p.append(0)
          _ = up.write(Self.message("p", p))
        case 5:
          let salt = Data(rest.prefix(4))
          let inner = Self.md5Hex(Data((t.password + t.user).utf8))
          var p = Data(("md5" + Self.md5Hex(Data(inner.utf8) + salt)).utf8); p.append(0)
          _ = up.write(Self.message("p", p))
        case 10:
          let mechs = String(decoding: rest, as: UTF8.self).split(separator: "\0").map(String.init)
          guard mechs.contains("SCRAM-SHA-256") else { return .failure(AuthFailure(text: "the database asked for a login method keydillo doesn't support (\(mechs.joined(separator: ", "))). " + Self.putBackHint, raw: nil)) }
          let s = SCRAM(password: t.password); scram = s
          let first = Data(s.clientFirst.utf8)
          var p = Data("SCRAM-SHA-256".utf8); p.append(0); p.append(Self.int32(UInt32(first.count))); p.append(first)
          _ = up.write(Self.message("p", p))
        case 11:
          guard let s = scram, let final = s.clientFinal(serverFirst: String(decoding: rest, as: UTF8.self)) else {
            return .failure(AuthFailure(text: "the database's SCRAM login didn't make sense", raw: nil))
          }
          _ = up.write(Self.message("p", Data(final.utf8)))
        case 12:
          guard let s = scram, s.verify(serverFinal: String(decoding: rest, as: UTF8.self)) else {
            return .failure(AuthFailure(text: "the database couldn't prove it knows the password; keydillo stopped", raw: nil))
          }
        default:
          return .failure(AuthFailure(text: "the database asked for a login method keydillo doesn't support (code \(code)). " + Self.putBackHint, raw: nil))
        }
      case UInt8(ascii: "v"): continue   // NegotiateProtocolVersion: carry on with what the server supports
      default: return .failure(AuthFailure(text: "unexpected reply from the database during login", raw: nil))
      }
    }
    return .failure(AuthFailure(text: "the database closed the connection during login", raw: nil))
  }

  static let putBackHint = "To use this database directly, put this key's real value back from its project page in keydillo."

  func forwardCancel(_ body: Data) {
    guard body.count >= 12 else { return }
    let key = body.dropFirst(4).prefix(8).base64EncodedString()
    lock.lock(); let t = cancelTargets[key]; lock.unlock()
    guard let target = t, let up = connectUpstream(target) else { return }
    var m = Self.int32(UInt32(body.count + 4)); m.append(body)
    _ = up.write(m); up.close()
  }

  // MARK: Wire helpers

  static func int32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.bigEndian) { Data($0) } }
  static func message(_ type: Character, _ body: Data) -> Data {
    var d = Data([type.asciiValue!]); d.append(int32(UInt32(body.count + 4))); d.append(body); return d
  }
  static func nextMessage(_ d: Data) -> (UInt8, Data, Int)? {
    guard d.count >= 5 else { return nil }
    let s = d.startIndex
    let len = Int(d[s+1..<s+5].withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) })
    guard len >= 4, d.count >= 1 + len else { return nil }
    return (d[s], Data(d[s+5..<s+1+len]), 1 + len)
  }
  static func startupMessage(_ params: [(String, String)]) -> Data {
    var body = int32(196608)
    for (k, v) in params { body.append(Data(k.utf8)); body.append(0); body.append(Data(v.utf8)); body.append(0) }
    body.append(0)
    var d = int32(UInt32(body.count + 4)); d.append(body); return d
  }
  static func startupParams(_ d: Data) -> [String: String] {
    let parts = d.split(separator: 0, omittingEmptySubsequences: false).map { String(decoding: $0, as: UTF8.self) }
    var out: [String: String] = [:]
    var i = 0
    while i + 1 < parts.count, !parts[i].isEmpty { out[parts[i]] = parts[i + 1]; i += 2 }
    return out
  }
  static func sendError(_ fd: Int32, code: String, _ text: String) {
    var b = Data()
    for (k, v) in [("S", "FATAL"), ("V", "FATAL"), ("C", code), ("M", "keydillo: " + text)] {
      b.append(Data(k.utf8)); b.append(Data(v.utf8)); b.append(0)
    }
    b.append(0)
    _ = writeAll(fd, message("E", b))
  }
  static func readExact(_ fd: Int32, _ n: Int) -> Data? {
    var out = Data(); var buf = [UInt8](repeating: 0, count: max(n, 1))
    while out.count < n {
      let r = Darwin.read(fd, &buf, n - out.count)
      if r <= 0 { return nil }
      out.append(contentsOf: buf[0..<r])
    }
    return out
  }
  static func readInt32(_ fd: Int32) -> UInt32? {
    readExact(fd, 4).map { $0.withUnsafeBytes { UInt32(bigEndian: $0.loadUnaligned(as: UInt32.self)) } }
  }
  static func writeAll(_ fd: Int32, _ d: Data) -> Bool {
    d.withUnsafeBytes { p in
      var sent = 0
      while sent < d.count {
        let n = Darwin.write(fd, p.baseAddress!.advanced(by: sent), d.count - sent)
        if n <= 0 { return false }
        sent += n
      }
      return true
    }
  }
  static func md5Hex(_ d: Data) -> String { Insecure.MD5.hash(data: d).map { String(format: "%02x", $0) }.joined() }
}

/// SCRAM-SHA-256 (RFC 7677) client, without channel binding.
public final class SCRAM {
  let password: String
  let user: String
  let nonce: String
  var authMessage = ""
  var serverKey = Data()
  var clientFirstBare: String { "n=\(user),r=\(nonce)" }
  public var clientFirst: String { "n,," + clientFirstBare }

  /// Postgres ignores the SCRAM user name (it uses the startup message's), so it's left empty.
  public init(password: String, user: String = "", nonce: String? = nil) {
    self.password = password
    self.user = user
    if let nonce { self.nonce = nonce } else {
      var bytes = [UInt8](repeating: 0, count: 18)
      _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
      self.nonce = Data(bytes).base64EncodedString()
    }
  }

  public func clientFinal(serverFirst: String) -> String? {
    var attrs: [Character: String] = [:]
    for part in serverFirst.split(separator: ",") where part.count > 2 { attrs[part.first!] = String(part.dropFirst(2)) }
    guard let r = attrs["r"], r.hasPrefix(nonce), let s = attrs["s"], let salt = Data(base64Encoded: s),
          let i = attrs["i"].flatMap(Int.init), i > 0 else { return nil }
    let salted = Self.pbkdf2(password: password, salt: salt, rounds: i)
    let clientKey = Self.hmac(salted, "Client Key")
    let storedKey = Data(SHA256.hash(data: clientKey))
    serverKey = Self.hmac(salted, "Server Key")
    let withoutProof = "c=biws,r=\(r)"
    authMessage = clientFirstBare + "," + serverFirst + "," + withoutProof
    let signature = Self.hmac(storedKey, authMessage)
    let proof = Data(zip(clientKey, signature).map { $0 ^ $1 })
    return withoutProof + ",p=" + proof.base64EncodedString()
  }

  public func verify(serverFinal: String) -> Bool {
    guard serverFinal.hasPrefix("v="), let v = Data(base64Encoded: String(serverFinal.dropFirst(2)).split(separator: ",").first.map(String.init) ?? "") else { return false }
    return v == Self.hmac(serverKey, authMessage)
  }

  static func hmac(_ key: Data, _ msg: String) -> Data {
    Data(HMAC<SHA256>.authenticationCode(for: Data(msg.utf8), using: SymmetricKey(data: key)))
  }
  static func pbkdf2(password: String, salt: Data, rounds: Int) -> Data {
    var out = [UInt8](repeating: 0, count: 32)
    let pw = Array(password.utf8)
    _ = salt.withUnsafeBytes { s in
      CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), pw.map { CChar(bitPattern: $0) }, pw.count,
                           s.bindMemory(to: UInt8.self).baseAddress, salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256),
                           UInt32(rounds), &out, out.count)
    }
    return Data(out)
  }
}
