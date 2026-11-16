import Foundation
import Network
import Security
import VaultCore

/// `keydillo run -- <command>`: runs a command whose outgoing HTTPS goes through a per-run proxy.
/// Requests to a stored service's host that carry a `keydillo:<name>` placeholder are handed to the
/// keydillo app (which asks for Touch ID and adds the real key). Everything else passes through untouched.
enum Runner {
  static var support: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("keydillo/ca", isDirectory: true)
  }
  static var caKey: URL { support.appendingPathComponent("ca.key") }
  static var caPem: URL { support.appendingPathComponent("ca.pem") }
  static var bundle: URL { support.appendingPathComponent("bundle.pem") }
  static var shims: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("keydillo/run", isDirectory: true)
  }

  /// Node: route fetch and https.request calls that carry a keydillo placeholder straight to the keydillo app.
  /// Works on every Node version, and for SDKs that ignore HTTPS_PROXY (Stripe, Resend…).
  static let nodePreload = #"""
  'use strict';
  (function () {
    let map = {}; try { map = JSON.parse(process.env.KEYDILLO_RUN_MAP || '{}'); } catch (e) {}
    const port = process.env.KEYDILLO_RUN_PORT;
    if (!port) return;
    function route(urlStr, headerText) {
      let u; try { u = new URL(urlStr); } catch (e) { return null; }
      const list = map[u.hostname.toLowerCase()]; if (!list) return null;
      const text = headerText + ' ' + urlStr;
      if (!text.includes('keydillo:') && !text.includes('keydillo%3A')) return null;
      const svc = list.find((s) => text.includes('keydillo:' + s) || text.includes('keydillo%3A' + s)) || list[0];
      return 'http://127.0.0.1:' + port + '/' + svc + u.pathname + u.search;
    }
    function headerString(h) {
      if (!h) return '';
      try { if (typeof h.forEach === 'function' && !Array.isArray(h)) { let s = ''; h.forEach((v, k) => { s += k + ':' + v + '\n'; }); return s; } } catch (e) {}
      return JSON.stringify(h);
    }
    if (typeof globalThis.fetch === 'function') {
      const orig = globalThis.fetch;
      globalThis.fetch = function (input, init) {
        try {
          const url = typeof input === 'string' ? input : (input instanceof URL ? input.href : input && input.url);
          const hdrs = headerString((init && init.headers) || (input && input.headers));
          const to = url && route(url, hdrs);
          if (to) {
            if (typeof input === 'object' && !(input instanceof URL) && input.url) return orig(new Request(to, input), init);
            return orig(to, init);
          }
        } catch (e) {}
        return orig(input, init);
      };
    }
    const http = require('http'), https = require('https');
    function wrap(fnName) {
      const orig = https[fnName];
      https[fnName] = function (a, b, c) {
        try {
          let url = null, opts = {}, cb = c;
          if (typeof a === 'string' || a instanceof URL) { url = new URL(a.toString()); if (typeof b === 'function') { cb = b; } else if (b) { opts = b; } }
          else { opts = a || {}; cb = b; url = new URL('https://' + (opts.hostname || opts.host || 'localhost') + (opts.port && opts.port != 443 ? ':' + opts.port : '') + (opts.path || '/')); }
          const to = route(url.href, headerString(opts.headers));
          if (to) {
            const t = new URL(to);
            const o = Object.assign({}, opts, { protocol: 'http:', hostname: t.hostname, host: t.hostname, port: t.port, path: t.pathname + t.search, agent: undefined });
            delete o.servername; delete o.ca; delete o.cert; delete o.key;
            return fnName === 'get' ? http.get(o, cb) : http.request(o, cb);
          }
        } catch (e) {}
        return orig.apply(this, arguments);
      };
    }
    wrap('request'); wrap('get');
  })();
  """#

  /// Python: make Apple's Python (LibreSSL, which ignores SSL_CERT_FILE) trust keydillo's per-run certificate.
  static let pythonSitecustomize = #"""
  import os, ssl
  _kd_ca = os.environ.get("KEYDILLO_CA")
  if _kd_ca:
      _kd_orig = ssl.create_default_context
      def _kd_ctx(*a, **k):
          c = _kd_orig(*a, **k)
          try:
              c.load_verify_locations(_kd_ca)
          except Exception:
              pass
          return c
      ssl.create_default_context = _kd_ctx
      ssl._create_default_https_context = _kd_ctx
  # Keep any other sitecustomize the user had.
  import importlib.util, sys
  _kd_here = os.path.dirname(os.path.abspath(__file__))
  for _p in sys.path:
      if _p and os.path.abspath(_p) != _kd_here and os.path.exists(os.path.join(_p, "sitecustomize.py")):
          _spec = importlib.util.spec_from_file_location("_user_sitecustomize", os.path.join(_p, "sitecustomize.py"))
          try:
              _spec.loader.exec_module(importlib.util.module_from_spec(_spec))
          except Exception:
              pass
          break
  """#

  static func writeShims() throws {
    try FileManager.default.createDirectory(at: shims, withIntermediateDirectories: true)
    try nodePreload.write(to: shims.appendingPathComponent("keydillo-preload.cjs"), atomically: true, encoding: .utf8)
    try pythonSitecustomize.write(to: shims.appendingPathComponent("sitecustomize.py"), atomically: true, encoding: .utf8)
  }

  @discardableResult
  static func sh(_ args: [String], input: Data? = nil) -> (Int32, Data) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: args[0])
    p.arguments = Array(args.dropFirst())
    let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
    if let input { let inp = Pipe(); p.standardInput = inp; try? inp.fileHandleForWriting.write(contentsOf: input); try? inp.fileHandleForWriting.close() }
    do { try p.run() } catch { return (-1, Data()) }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, data)
  }

  /// A local certificate authority trusted only by commands started with `keydillo run`.
  static func ensureCA() throws {
    let fm = FileManager.default
    try fm.createDirectory(at: support, withIntermediateDirectories: true)
    chmod(support.path, 0o700)
    if !fm.fileExists(atPath: caPem.path) || !fm.fileExists(atPath: caKey.path) {
      let (s1, _) = sh(["/usr/bin/openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", caKey.path])
      chmod(caKey.path, 0o600)
      let (s2, _) = sh(["/usr/bin/openssl", "req", "-x509", "-new", "-key", caKey.path, "-sha256", "-days", "3650",
                        "-subj", "/CN=keydillo local CA (keydillo run only)", "-out", caPem.path,
                        "-addext", "basicConstraints=critical,CA:TRUE", "-addext", "keyUsage=critical,keyCertSign,cRLSign"])
      guard s1 == 0, s2 == 0 else { throw VaultError.invalidConfig("couldn't create the keydillo run certificate (openssl failed)") }
      try? fm.removeItem(at: bundle)
    }
    if !fm.fileExists(atPath: bundle.path) {
      let (_, roots) = sh(["/usr/bin/security", "find-certificate", "-a", "-p", "/System/Library/Keychains/SystemRootCertificates.keychain"])
      // Roots an admin or MDM installed (corporate TLS inspection such as Zscaler) live in the System keychain.
      let (_, admin) = sh(["/usr/bin/security", "find-certificate", "-a", "-p", "/Library/Keychains/System.keychain"])
      // keydillo's CA goes first: some older TLS libraries stop reading a bundle at the first cert they can't parse.
      var data = try Data(contentsOf: caPem)
      data.append(roots); data.append(admin)
      try data.write(to: bundle)
    }
  }

  /// Leaf certificate for `host`, signed by the CA, loaded in memory only.
  static func identity(for host: String) throws -> SecIdentity {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("keydillo-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let key = dir.appendingPathComponent("leaf.key").path, csr = dir.appendingPathComponent("leaf.csr").path
    let pem = dir.appendingPathComponent("leaf.pem").path, ext = dir.appendingPathComponent("ext.cnf").path
    let p12 = dir.appendingPathComponent("leaf.p12").path
    try "subjectAltName=DNS:\(host)\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n".write(toFile: ext, atomically: true, encoding: .utf8)
    let steps: [[String]] = [
      ["/usr/bin/openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", key],
      ["/usr/bin/openssl", "req", "-new", "-key", key, "-subj", "/CN=\(host)", "-out", csr],
      ["/usr/bin/openssl", "x509", "-req", "-in", csr, "-CA", caPem.path, "-CAkey", caKey.path, "-CAcreateserial",
       "-days", "30", "-sha256", "-extfile", ext, "-out", pem],
      ["/usr/bin/openssl", "pkcs12", "-export", "-inkey", key, "-in", pem, "-out", p12, "-passout", "pass:keydillo"],
    ]
    for s in steps where sh(s).0 != 0 { throw VaultError.invalidConfig("couldn't create a certificate for \(host)") }
    var items: CFArray?
    let opts: [String: Any] = [kSecImportExportPassphrase as String: "keydillo", kSecImportToMemoryOnly as String: true]
    let st = SecPKCS12Import(try Data(contentsOf: URL(fileURLWithPath: p12)) as CFData, opts as CFDictionary, &items)
    guard st == errSecSuccess, let arr = items as? [[String: Any]], let first = arr.first,
          let id = first[kSecImportItemIdentity as String] else { throw VaultError.keychain(st) }
    return (id as! SecIdentity)
  }

  static func run(_ command: [String]) -> Never {
    guard !command.isEmpty else { fail("usage: keydillo run -- <command> [args]") }
    var services: [ServiceSummary]
    let env0 = ProcessInfo.processInfo.environment
    if let json = env0["KEYDILLO_TEST_SERVICES"], let d = json.data(using: .utf8),
       let s = try? JSONDecoder().decode([ServiceSummary].self, from: d) {
      services = s   // testing hook: which hosts to intercept (keys still only come from the app)
    } else {
      switch (try? ControlSocket.send(.listServices)) {
      case .services(let s)?: services = s
      default: fail("keydillo isn't running. Open the keydillo app first.")
      }
    }
    do { try ensureCA() } catch { fail(error.localizedDescription) }
    let appPort = env0["KEYDILLO_TEST_APP_PORT"].flatMap { UInt16($0) } ?? services.first.flatMap { URL(string: $0.baseURL)?.port }.map(UInt16.init) ?? UInt16(UserDefaults(suiteName: "com.studiokillswitch.keydillo")?.integer(forKey: "port") ?? 7787)
    let upstreamProxy = UpstreamProxy.fromEnvironment(env0)
    if let up = upstreamProxy {
      FileHandle.standardError.write(Data("keydillo run: also sending traffic through your proxy at \(up.host):\(up.port). Requests to other sites go through it as before. Requests keydillo signs go through the keydillo app, which uses your Mac's proxy settings; a debugging proxy there (Charles, Proxyman, mitmproxy) can see the real key.\n".utf8))
    }
    let proxy = MitmProxy(services: services, appPort: appPort, upstreamProxy: upstreamProxy)
    let port: UInt16
    do { port = try proxy.start() } catch { fail("couldn't start the proxy: \(error.localizedDescription)") }

    var env = ProcessInfo.processInfo.environment
    let proxyURL = "http://127.0.0.1:\(port)"
    for k in ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"] { env[k] = proxyURL }
    let keepNoProxy = (env0["NO_PROXY"] ?? env0["no_proxy"]).map { "," + $0 } ?? ""
    env["NO_PROXY"] = "localhost,127.0.0.1,::1" + keepNoProxy; env["no_proxy"] = env["NO_PROXY"]
    env["ALL_PROXY"] = nil; env["all_proxy"] = nil
    env["NODE_USE_ENV_PROXY"] = "1"
    // Per-run CA files: keydillo's CA plus whatever the user already trusted (corporate roots, their own bundles).
    let runBundle = FileManager.default.temporaryDirectory.appendingPathComponent("keydillo-ca-\(getpid()).pem")
    let runExtra = FileManager.default.temporaryDirectory.appendingPathComponent("keydillo-extra-\(getpid()).pem")
    var bundleData = (try? Data(contentsOf: bundle)) ?? Data()
    var extraData = (try? Data(contentsOf: caPem)) ?? Data()
    for k in ["SSL_CERT_FILE", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE", "NODE_EXTRA_CA_CERTS", "AWS_CA_BUNDLE"] {
      if let path = env0[k], let d = try? Data(contentsOf: URL(fileURLWithPath: path)) { bundleData.append(d); extraData.append(d) }
    }
    try? bundleData.write(to: runBundle); try? extraData.write(to: runExtra)
    env["NODE_EXTRA_CA_CERTS"] = runExtra.path
    for k in ["SSL_CERT_FILE", "REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE", "AWS_CA_BUNDLE"] { env[k] = runBundle.path }
    env["KEYDILLO_RUN"] = "1"
    // Shims for runtimes that ignore proxy or CA settings.
    try? writeShims()
    var hostMap: [String: [String]] = [:]
    for svc in services { hostMap[svc.host.lowercased().split(separator: ":").first.map(String.init) ?? svc.host, default: []].append(svc.name) }
    env["KEYDILLO_RUN_MAP"] = String(decoding: (try? JSONSerialization.data(withJSONObject: hostMap)) ?? Data("{}".utf8), as: UTF8.self)
    env["KEYDILLO_RUN_PORT"] = String(appPort)
    env["NODE_OPTIONS"] = ((env0["NODE_OPTIONS"].map { $0 + " " }) ?? "") + "--require \"\(shims.appendingPathComponent("keydillo-preload.cjs").path)\""
    env["KEYDILLO_CA"] = runExtra.path
    env["PYTHONPATH"] = shims.path + (env0["PYTHONPATH"].map { ":" + $0 } ?? "")

    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    child.arguments = command
    child.environment = env
    child.terminationHandler = { p in
      try? FileManager.default.removeItem(at: runBundle); try? FileManager.default.removeItem(at: runExtra)
      exit(p.terminationStatus)
    }
    signal(SIGINT, SIG_IGN); signal(SIGTERM) { _ in exit(143) }
    do { try child.run() } catch { fail("couldn't start \(command[0]): \(error.localizedDescription)") }
    dispatchMain()
  }
}

/// An HTTP proxy the user already had (corporate proxy, Charles, Proxyman, mitmproxy…), from the environment.
struct UpstreamProxy {
  let host: String
  let port: UInt16
  let authorization: String?
  let noProxy: [String]

  static func fromEnvironment(_ env: [String: String]) -> UpstreamProxy? {
    guard let raw = env["HTTPS_PROXY"] ?? env["https_proxy"] ?? env["ALL_PROXY"] ?? env["all_proxy"] ?? env["HTTP_PROXY"] ?? env["http_proxy"],
          let u = URL(string: raw.contains("://") ? raw : "http://" + raw), let host = u.host,
          u.scheme == "http" || u.scheme == "https" else { return nil }
    var auth: String?
    if let user = u.user {
      auth = "Basic " + Data("\(user.removingPercentEncoding ?? user):\(u.password?.removingPercentEncoding ?? "")".utf8).base64EncodedString()
    }
    let np = (env["NO_PROXY"] ?? env["no_proxy"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty }
    return UpstreamProxy(host: host, port: UInt16(u.port ?? 8080), authorization: auth, noProxy: np)
  }

  func bypasses(_ host: String) -> Bool {
    noProxy.contains { rule in
      rule == "*" || host == rule || host.hasSuffix(rule.hasPrefix(".") ? rule : "." + rule)
    }
  }
}

/// Minimal HTTP CONNECT proxy. MITMs only hosts that belong to stored services.
final class MitmProxy: @unchecked Sendable {
  let services: [ServiceSummary]
  let appPort: UInt16
  let queue = DispatchQueue(label: "keydillo.run")
  let listenerQueue = DispatchQueue(label: "keydillo.run.listeners")
  var tlsListeners: [String: UInt16] = [:]
  let lock = NSLock()
  let session: URLSession
  /// Straight to the keydillo app on localhost, never through any proxy.
  let appSession: URLSession = {
    let c = URLSessionConfiguration.ephemeral
    c.connectionProxyDictionary = [:]
    c.timeoutIntervalForRequest = 600; c.timeoutIntervalForResource = 24 * 3600
    return URLSession(configuration: c)
  }()

  let upstreamProxy: UpstreamProxy?

  init(services: [ServiceSummary], appPort: UInt16, upstreamProxy: UpstreamProxy?) {
    self.services = services; self.appPort = appPort; self.upstreamProxy = upstreamProxy
    let cfg = URLSessionConfiguration.ephemeral
    // Never loop back through ourselves; do go through the user's own proxy if they had one.
    if let up = upstreamProxy {
      cfg.connectionProxyDictionary = [kCFNetworkProxiesHTTPSEnable as String: true, kCFNetworkProxiesHTTPSProxy as String: up.host,
                                       kCFNetworkProxiesHTTPSPort as String: Int(up.port), kCFNetworkProxiesHTTPEnable as String: true,
                                       kCFNetworkProxiesHTTPProxy as String: up.host, kCFNetworkProxiesHTTPPort as String: Int(up.port)]
    } else {
      cfg.connectionProxyDictionary = [:]
    }
    session = URLSession(configuration: cfg)
  }

  var hosts: Set<String> { Set(services.map { $0.host.lowercased() }) }

  func start() throws -> UInt16 {
    let params = NWParameters.tcp
    params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let l = try NWListener(using: params)
    let ready = DispatchSemaphore(value: 0)
    l.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
    l.newConnectionHandler = { [weak self] c in self?.acceptClient(c) }
    l.start(queue: queue)
    _ = ready.wait(timeout: .now() + 5)
    guard let p = l.port?.rawValue else { throw VaultError.invalidConfig("no port") }
    return p
  }

  func acceptClient(_ c: NWConnection) {
    c.start(queue: queue)
    readHead(c, Data())
  }

  func readHead(_ c: NWConnection, _ buf: Data) {
    c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] d, _, done, err in
      guard let self else { return }
      var b = buf; if let d { b.append(d) }
      guard let end = b.range(of: Data("\r\n\r\n".utf8)) else {
        if done || err != nil { c.cancel() } else { self.readHead(c, b) }
        return
      }
      let head = String(decoding: b[..<end.lowerBound], as: UTF8.self)
      let rest = b[end.upperBound...]
      let parts = head.split(separator: " ")
      guard parts.count >= 2, parts[0] == "CONNECT" else {
        self.reply(c, "HTTP/1.1 405 Method Not Allowed\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"); return
      }
      let target = String(parts[1])
      let host = String(target.split(separator: ":").first ?? "").lowercased()
      let port = UInt16(target.split(separator: ":").last ?? "443") ?? 443
      do {
        if ProcessInfo.processInfo.environment["KEYDILLO_DEBUG"] != nil { FileHandle.standardError.write(Data("keydillo run: CONNECT \(host):\(port)\n".utf8)) }
        if !self.hosts.contains(host), let up = self.upstreamProxy, !up.bypasses(host) {
          // Not ours: hand the CONNECT to the user's own proxy and let it answer.
          let upstream = NWConnection(host: NWEndpoint.Host(up.host), port: NWEndpoint.Port(rawValue: up.port)!, using: .tcp)
          upstream.start(queue: self.queue)
          var connect = "CONNECT \(host):\(port) HTTP/1.1\r\nHost: \(host):\(port)\r\n"
          if let a = up.authorization { connect += "Proxy-Authorization: \(a)\r\n" }
          connect += "\r\n"
          upstream.send(content: Data(connect.utf8) + rest, completion: .idempotent)
          self.pipe(c, upstream); self.pipe(upstream, c)
          return
        }
        let (h, p) = self.hosts.contains(host) ? ("127.0.0.1", try self.tlsPort(for: host)) : (host, port)
        let upstream = NWConnection(host: NWEndpoint.Host(h), port: NWEndpoint.Port(rawValue: p)!, using: .tcp)
        upstream.start(queue: self.queue)
        c.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), completion: .contentProcessed { _ in
          if !rest.isEmpty { upstream.send(content: rest, completion: .idempotent) }
          self.pipe(c, upstream); self.pipe(upstream, c)
        })
      } catch {
        FileHandle.standardError.write(Data("keydillo run: couldn't intercept \(host): \(error.localizedDescription)\n".utf8))
        self.reply(c, "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
      }
    }
  }

  func reply(_ c: NWConnection, _ s: String) { c.send(content: Data(s.utf8), completion: .contentProcessed { _ in c.cancel() }) }

  func pipe(_ from: NWConnection, _ to: NWConnection) {
    from.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] d, _, done, err in
      if let d, !d.isEmpty { to.send(content: d, completion: .idempotent) }
      if done || err != nil { to.send(content: nil, isComplete: true, completion: .idempotent); return }
      self?.pipe(from, to)
    }
  }

  /// A TLS listener per MITM'd host, presenting a certificate for that host.
  func tlsPort(for host: String) throws -> UInt16 {
    lock.lock(); defer { lock.unlock() }
    if let p = tlsListeners[host] { return p }
    let identity = try Runner.identity(for: host)
    let tls = NWProtocolTLS.Options()
    sec_protocol_options_set_local_identity(tls.securityProtocolOptions, sec_identity_create(identity)!)
    sec_protocol_options_add_tls_application_protocol(tls.securityProtocolOptions, "http/1.1")
    let params = NWParameters(tls: tls)
    params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
    let l = try NWListener(using: params)
    let ready = DispatchSemaphore(value: 0)
    l.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
    l.newConnectionHandler = { [weak self] c in c.start(queue: self!.queue); self?.serve(c, host: host, buf: Data()) }
    l.start(queue: listenerQueue)   // not `queue`: we may be called from it, and we wait for .ready below
    _ = ready.wait(timeout: .now() + 5)
    guard let p = l.port?.rawValue else { throw VaultError.invalidConfig("tls listener failed") }
    tlsListeners[host] = p
    return p
  }

  /// Decrypted HTTP/1.1 from the client for `host`.
  func serve(_ c: NWConnection, host: String, buf: Data) {
    c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] d, _, done, err in
      guard let self else { return }
      var b = buf; if let d { b.append(d) }
      switch HTTPParser.parse(b) {
      case .incomplete:
        if done || err != nil { c.cancel() } else { self.serve(c, host: host, buf: b) }
      case .invalid(let status, let reason):
        c.send(content: HTTPResponse.error(status, reason).serialized(), completion: .contentProcessed { _ in c.cancel() })
      case .complete(let req, _):
        Task {
          let resp = await self.forward(req, host: host)
          c.send(content: resp.serialized(), completion: .contentProcessed { _ in c.cancel() })
        }
      }
    }
  }

  func forward(_ req: HTTPRequest, host: String) async -> HTTPResponse {
    // A placeholder anywhere in the headers names the service; it must belong to this host.
    let named = req.headers.lazy.compactMap { Placeholder.service(in: $0.1) }.first
    let urlString: String
    if let named {
      guard let svc = services.first(where: { $0.name == named }), svc.host.lowercased() == host else {
        return .error(403, "the placeholder for '\(named)' was sent to \(host), which isn't that key's host", code: "host_not_allowed",
                      hint: "Use the host keydillo stores for \(named), or check which env var your code reads.")
      }
      urlString = "http://127.0.0.1:\(appPort)/\(svc.name)\(req.target)"
    } else {
      urlString = "https://\(host)\(req.target)"
    }
    guard let url = URL(string: urlString) else { return .error(400, "bad path", code: "bad_path") }
    var out = URLRequest(url: url)
    out.httpMethod = req.method
    for (k, v) in req.headers where !["host", "content-length", "connection", "proxy-connection", "transfer-encoding"].contains(k.lowercased()) {
      out.addValue(v, forHTTPHeaderField: k)
    }
    if !req.body.isEmpty { out.httpBody = req.body }
    do {
      let (data, resp) = try await (named != nil ? appSession : session).data(for: out)
      guard let http = resp as? HTTPURLResponse else { return .error(502, "bad response", code: "upstream_failed") }
      let headers = http.allHeaderFields.compactMap { k, v -> (String, String)? in
        guard let k = k as? String, let v = v as? String else { return nil }
        return ["content-length", "content-encoding", "transfer-encoding", "connection"].contains(k.lowercased()) ? nil : (k, v)
      }
      return HTTPResponse(status: http.statusCode, headers: headers, body: data)
    } catch {
      let refused = (error as NSError).code == NSURLErrorCannotConnectToHost
      return .error(502, refused ? "the keydillo app isn't answering (restarting?)" : "request failed: \(error.localizedDescription)",
                    code: refused ? "keydillo_unavailable" : "upstream_failed", hint: refused ? "Retry in a few seconds." : nil)
    }
  }
}
