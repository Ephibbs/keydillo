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
          let hdrs = headerString((init && init.headers) || (input && input.headers));
          const body = init && init.body;
          if (typeof body === 'string') hdrs += ' ' + body;
          else if (body && typeof body.toString === 'function' && (body instanceof URLSearchParams)) hdrs += ' ' + body.toString();
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
    // undici.request() (discord.js and others) ignores both fetch and https: point the app's own undici at the env proxy.
    try {
      const u = require(require.resolve('undici', { paths: [process.cwd()] }));
      if (u.EnvHttpProxyAgent && u.setGlobalDispatcher) u.setGlobalDispatcher(new u.EnvHttpProxyAgent());
    } catch (e) {}
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
  # aiohttp ignores HTTPS_PROXY unless trust_env=True; default it on, once aiohttp is imported.
  import sys as _kd_sys
  class _KdAiohttpHook:
      def find_spec(self, name, path=None, target=None):
          if name != "aiohttp.client":
              return None
          import importlib.machinery
          for finder in _kd_sys.meta_path:
              if finder is self:
                  continue
              spec = getattr(finder, "find_spec", lambda *a: None)(name, path, target)
              if spec and spec.loader:
                  orig_exec = spec.loader.exec_module
                  def exec_module(module, _orig=orig_exec):
                      _orig(module)
                      cls = getattr(module, "ClientSession", None)
                      if cls is not None:
                          _init = cls.__init__
                          def __init__(self, *a, **k):
                              k.setdefault("trust_env", True)
                              _init(self, *a, **k)
                          cls.__init__ = __init__
                  spec.loader.exec_module = exec_module
                  return spec
          return None
  _kd_sys.meta_path.insert(0, _KdAiohttpHook())
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

  /// This run's private folder (0700), deleted when the command exits. Holds the per-run CA.
  static let runDir: URL = {
    let d = FileManager.default.temporaryDirectory.appendingPathComponent("keydillo-run-\(getpid())-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
    return d
  }()
  static var caKey: URL { runDir.appendingPathComponent("ca.key") }
  static var caPem: URL { runDir.appendingPathComponent("ca.pem") }
  static var roots: URL { runDir.appendingPathComponent("roots.pem") }   // public roots, rebuilt each run in the private run folder

  /// A fresh certificate authority for this run only, limited to the stored hosts, never reused.
  static func ensureCA(hosts: [String]) throws {
    let fm = FileManager.default
    try fm.createDirectory(at: support, withIntermediateDirectories: true)
    try? fm.removeItem(at: support.appendingPathComponent("ca.key"))   // older builds kept one long-lived CA
    try? fm.removeItem(at: support.appendingPathComponent("bundle.pem"))
    let names = (hosts.isEmpty ? ["invalid"] : hosts).map { "permitted;DNS:\($0)" }.joined(separator: ",")
    let (s1, _) = sh(["/usr/bin/openssl", "ecparam", "-name", "prime256v1", "-genkey", "-noout", "-out", caKey.path])
    chmod(caKey.path, 0o600)
    let (s2, _) = sh(["/usr/bin/openssl", "req", "-x509", "-new", "-key", caKey.path, "-sha256", "-days", "30",
                      "-subj", "/CN=keydillo run \(getpid()) (this command only)", "-out", caPem.path,
                      "-addext", "basicConstraints=critical,CA:TRUE,pathlen:0", "-addext", "keyUsage=critical,keyCertSign,cRLSign",
                      "-addext", "nameConstraints=critical,\(names)"])
    guard s1 == 0, s2 == 0 else { throw VaultError.invalidConfig("couldn't create the keydillo run certificate (openssl failed)") }
    try? fm.removeItem(at: support.appendingPathComponent("roots.pem"))   // older builds kept a shared, writable copy
    if !fm.fileExists(atPath: roots.path) {
      let (_, sys) = sh(["/usr/bin/security", "find-certificate", "-a", "-p", "/System/Library/Keychains/SystemRootCertificates.keychain"])
      // Roots an admin or MDM installed (corporate TLS inspection such as Zscaler) live in the System keychain.
      let (_, admin) = sh(["/usr/bin/security", "find-certificate", "-a", "-p", "/Library/Keychains/System.keychain"])
      try (sys + admin).write(to: roots)
    }
  }

  static func cleanup() { try? FileManager.default.removeItem(at: runDir) }

  /// Leaf certificate for `host`, signed by the CA, loaded in memory only.
  static func identity(for host: String) throws -> SecIdentity {
    let dir = runDir.appendingPathComponent("leaf-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
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
    let (proxy, env) = prepare()
    let child = Process()
    child.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    child.arguments = command
    child.environment = env
    child.terminationHandler = { p in
      // Programs the command started in the background (daemons, nohup, pm2) keep their keys and network
      // until they exit too.
      proxy.scanDescendants()
      let status = p.terminationStatus
      let wait = DispatchSource.makeTimerSource(queue: .main)
      wait.schedule(deadline: .now(), repeating: 2)
      wait.setEventHandler { if !proxy.anyKnownAlive { cleanup(); exit(status) } }
      wait.resume()
      Runner.keepAlive = wait
    }
    signal(SIGINT, SIG_IGN); signal(SIGTERM) { _ in Runner.cleanup(); exit(143) }
    do { try child.run() } catch { fail("couldn't start \(command[0]): \(error.localizedDescription)") }
    proxy.childPid = child.processIdentifier
    let scan = DispatchSource.makeTimerSource(queue: .global())
    scan.schedule(deadline: .now() + 1, repeating: 2)
    scan.setEventHandler { proxy.scanDescendants() }
    scan.resume()
    Runner.scanner = scan
    dispatchMain()
  }

  /// The app's services, opening keydillo in the background first if it isn't running.
  static func appServices() -> [ServiceSummary]? {
    if case .services(let s)? = try? ControlSocket.send(.listServices) { return s }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    // The app this command belongs to (…/keydillo.app/Contents/Resources/bin/keydillo), not whichever copy Spotlight finds.
    let me = URL(fileURLWithPath: ProcessLookup.path(of: getpid()))
    let app = me.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    guard app.pathExtension == "app" else { return nil }
    p.arguments = ["-g", app.path]
    p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
    try? p.run(); p.waitUntilExit()
    for _ in 0..<40 {
      usleep(250_000)
      if case .services(let s)? = try? ControlSocket.send(.listServices) { return s }
    }
    return nil
  }

  /// Launch-time keys (database URLs, JWT secrets…): the program reads them as it starts, so kd puts the real value
  /// in its environment (after the app's approval). .env loaders don't override variables that are already set.
  static func fillLaunchValues(services: [ServiceSummary], env0: [String: String], shipped: Bool, into env: inout [String: String]) {
    let launch = Set(services.filter { $0.launchTime == true }.map(\.name))
    guard !launch.isEmpty else { return }
    var wanted: [String: String] = [:]   // env var -> key name
    for (k, v) in projectEnvEntries(from: FileManager.default.currentDirectoryPath) + env0.map({ ($0.key, $0.value) }) {
      if let svc = Placeholder.service(in: v), launch.contains(svc) { wanted[k] = svc }
    }
    guard !wanted.isEmpty else { return }
    var values: [String: String] = [:]
    if !shipped, let json = env0["KEYDILLO_TEST_LAUNCH_VALUES"], let d = json.data(using: .utf8),
       let v = try? JSONDecoder().decode([String: String].self, from: d) {
      values = v   // testing hook, development builds only
    } else if case .values(let v)? = try? ControlSocket.send(.launchValues(Array(Set(wanted.values)).sorted())) {
      values = v
    }
    for (k, svc) in wanted.sorted(by: { $0.key < $1.key }) {
      if let v = values[svc] { env[k] = v }
      else { FileHandle.standardError.write(Data("kd: \(k) wasn't filled in (not approved, or keydillo is paused), so the program gets the keydillo placeholder.\n".utf8)) }
    }
  }

  /// KEY=VALUE lines from the env files of the keydillo project at or above `dir`.
  static func projectEnvEntries(from dir: String) -> [(String, String)] {
    var d = dir
    while !d.isEmpty && d != "/" {
      let names = ((try? FileManager.default.contentsOfDirectory(atPath: d)) ?? []).filter(ImportScanner.isEnvFile)
      let texts = names.compactMap { try? String(contentsOfFile: d + "/" + $0, encoding: .utf8) }
      if texts.contains(where: { $0.contains(ImportScanner.headerStart) }) {
        return texts.flatMap { t in
          t.components(separatedBy: "\n").compactMap { line -> (String, String)? in
            var l = line.trimmingCharacters(in: .whitespaces)
            if l.hasPrefix("#") || !l.contains("=") { return nil }
            if l.hasPrefix("export ") { l = String(l.dropFirst(7)) }
            let parts = l.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return nil }
            return (parts[0].trimmingCharacters(in: .whitespaces), parts[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")))
          }
        }
      }
      d = (d as NSString).deletingLastPathComponent
    }
    return []
  }

  static var keepAlive: DispatchSourceTimer?
  static var scanner: DispatchSourceTimer?

  /// Keeps the proxy alive for the life of the process (its callbacks only hold it weakly).
  static var active: MitmProxy?

  static func prepare() -> (MitmProxy, [String: String]) {
    var services: [ServiceSummary]
    let env0 = ProcessInfo.processInfo.environment
    // Test hooks work only in the standalone dev build, never in the copy shipped inside keydillo.app.
    let shipped = ProcessLookup.path(of: getpid()).contains(".app/Contents/")
    if !shipped, let json = env0["KEYDILLO_TEST_SERVICES"], let d = json.data(using: .utf8),
       let s = try? JSONDecoder().decode([ServiceSummary].self, from: d) {
      services = s   // testing hook: which hosts to intercept (keys still only come from the app)
    } else {
      services = appServices() ?? { fail("keydillo isn't running and couldn't be started. Open the keydillo app, then try again.") }()
    }
    do { try ensureCA(hosts: MitmProxy.knownHosts(services) + MitmProxy.guessedDomains(services)) } catch { fail(error.localizedDescription) }
    let appPort = (shipped ? nil : env0["KEYDILLO_TEST_APP_PORT"].flatMap { UInt16($0) }) ?? services.first.flatMap { URL(string: $0.baseURL)?.port }.map(UInt16.init) ?? UInt16(UserDefaults(suiteName: "com.studiokillswitch.keydillo")?.integer(forKey: "port") ?? 7787)
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
    let runBundle = runDir.appendingPathComponent("bundle.pem")
    let runExtra = runDir.appendingPathComponent("extra.pem")
    // keydillo's CA goes first: some older TLS libraries stop reading a bundle at the first cert they can't parse.
    var bundleData = ((try? Data(contentsOf: caPem)) ?? Data()) + ((try? Data(contentsOf: roots)) ?? Data())
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
    for svc in services { for h in MitmProxy.hosts(of: svc) { hostMap[h, default: []].append(svc.name) } }
    env["KEYDILLO_RUN_MAP"] = String(decoding: (try? JSONSerialization.data(withJSONObject: hostMap)) ?? Data("{}".utf8), as: UTF8.self)
    env["KEYDILLO_RUN_PORT"] = String(appPort)
    env["NODE_OPTIONS"] = ((env0["NODE_OPTIONS"].map { $0 + " " }) ?? "") + "--require \"\(shims.appendingPathComponent("keydillo-preload.cjs").path)\""
    env["KEYDILLO_CA"] = runExtra.path
    env["PYTHONPATH"] = shims.path + (env0["PYTHONPATH"].map { ":" + $0 } ?? "")

    fillLaunchValues(services: services, env0: env0, shipped: shipped, into: &env)
    active = proxy
    return (proxy, env)
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

  /// A service's approved hosts (without ports).
  static func hosts(of s: ServiceSummary) -> [String] {
    (s.hosts ?? [s.host]).filter { !$0.isEmpty }.map { $0.lowercased().split(separator: ":").first.map(String.init) ?? $0 }
  }
  static func knownHosts(_ services: [ServiceSummary]) -> [String] { Array(Set(services.flatMap { hosts(of: $0) })).sorted() }

  /// For keys without a host yet: likely provider domains from the key's name (together → together.xyz, upstash → upstash.io).
  /// Traffic to these is looked into so the placeholder can be seen and its host approved once with Touch ID.
  static func guessedDomains(_ services: [ServiceSummary]) -> [String] {
    let tlds = ["com", "ai", "io", "xyz", "co", "dev", "app", "net", "org", "cloud", "sh", "so"]
    var out = Set<String>()
    for s in services where hosts(of: s).isEmpty {
      for t in s.hostTokens ?? [] { for tld in tlds { out.insert("\(t).\(tld)"); out.insert("\(t)cloud.\(tld)") } }
    }
    return out.sorted()
  }

  lazy var exactHosts: Set<String> = Set(Self.knownHosts(services))
  lazy var guessed: [String] = Self.guessedDomains(services)

  /// Whether kd looks inside connections to `host`.
  func intercepts(_ host: String) -> Bool {
    lock.lock(); defer { lock.unlock() }
    return exactHosts.contains(host) || guessed.contains { host == $0 || host.hasSuffix("." + $0) }
  }

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
    listenPort = p
    return p
  }

  /// Processes started by the command that we've seen (pid -> start time). They keep access after they detach
  /// (daemons, nohup, pm2), and the proxy stays up while any of them is alive.
  var known: [Int32: UInt64] = [:]

  func allowed(_ pid: Int32) -> Bool {
    if ProcessLookup.isDescendant(pid, of: childPid) { remember(pid); return true }
    lock.lock(); let ks = known; lock.unlock()
    for (k, start) in ks where ProcessLookup.startTime(of: k) == start && ProcessLookup.isDescendant(pid, of: k) { remember(pid); return true }
    return false
  }

  func remember(_ pid: Int32) {
    let st = ProcessLookup.startTime(of: pid)
    lock.lock(); known[pid] = st; lock.unlock()
  }

  /// Records every current descendant of the command, so ones that later detach keep working.
  func scanDescendants() {
    for pid in ProcessLookup.allPids() where pid != childPid && ProcessLookup.isDescendant(pid, of: childPid) { remember(pid) }
  }

  var anyKnownAlive: Bool {
    lock.lock(); let ks = known; lock.unlock()
    return ks.contains { ProcessLookup.startTime(of: $0.key) == $0.value }
  }

  /// Set once the command starts. Only it and its descendants may use this run's proxy.
  var childPid: Int32 = 0
  var listenPort: UInt16 = 0

  func acceptClient(_ c: NWConnection) {
    if case .hostPort(_, let p) = c.endpoint {
      let peer = ProcessLookup.process(connectedFrom: p.rawValue, to: listenPort)
      guard childPid > 0, peer.pid > 0, allowed(peer.pid) else {
        c.start(queue: queue)
        reply(c, "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"); return
      }
      c.start(queue: queue)
      readHead(c, Data(), caller: peer.pid)
      return
    }
    c.start(queue: queue)
    reply(c, "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
  }

  /// Which program each of our own connections to a per-host TLS listener was opened for (by local port).
  var callerByPort: [UInt16: Int32] = [:]

  func readHead(_ c: NWConnection, _ buf: Data, caller: Int32) {
    c.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] d, _, done, err in
      guard let self else { return }
      var b = buf; if let d { b.append(d) }
      guard let end = b.range(of: Data("\r\n\r\n".utf8)) else {
        if done || err != nil { c.cancel() } else { self.readHead(c, b, caller: caller) }
        return
      }
      let head = String(decoding: b[..<end.lowerBound], as: UTF8.self)
      let rest = b[end.upperBound...]
      let parts = head.split(separator: " ")
      guard parts.count >= 2 else {
        self.reply(c, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"); return
      }
      if parts[0] != "CONNECT" {
        // A plain http:// request (absolute URL). Read it whole, then send it on.
        switch HTTPParser.parse(b) {
        case .incomplete:
          if done || err != nil { c.cancel() } else { self.readHead(c, b, caller: caller) }
        case .invalid(let status, let reason):
          c.send(content: HTTPResponse.error(status, reason).serialized(), completion: .contentProcessed { _ in c.cancel() })
        case .complete(let req, let consumed):
          self.forwardPlain(req, extra: b.suffix(from: b.startIndex + consumed), client: c, caller: caller)
        }
        return
      }
      let target = String(parts[1])
      let host = String(target.split(separator: ":").first ?? "").lowercased()
      let port = UInt16(target.split(separator: ":").last ?? "443") ?? 443
      do {
        if ProcessInfo.processInfo.environment["KEYDILLO_DEBUG"] != nil { FileHandle.standardError.write(Data("keydillo run: CONNECT \(host):\(port)\n".utf8)) }
        if !self.intercepts(host), let up = self.upstreamProxy, !up.bypasses(host) {
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
        let intercepted = self.intercepts(host)
        let (h, p) = intercepted ? ("127.0.0.1", try self.tlsPort(for: host)) : (host, port)
        let upstream = NWConnection(host: NWEndpoint.Host(h), port: NWEndpoint.Port(rawValue: p)!, using: .tcp)
        upstream.stateUpdateHandler = { [weak self] st in
          guard case .ready = st, intercepted, let self,
                case .hostPort(_, let local)? = upstream.currentPath?.localEndpoint else { return }
          self.lock.lock(); self.callerByPort[local.rawValue] = caller; self.lock.unlock()
          c.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), completion: .contentProcessed { _ in
            if !rest.isEmpty { upstream.send(content: rest, completion: .idempotent) }
            self.pipe(c, upstream); self.pipe(upstream, c)
          })
        }
        upstream.start(queue: self.queue)
        if !intercepted {
          c.send(content: Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8), completion: .contentProcessed { _ in
            if !rest.isEmpty { upstream.send(content: rest, completion: .idempotent) }
            self.pipe(c, upstream); self.pipe(upstream, c)
          })
        }
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
    l.newConnectionHandler = { [weak self] c in
      guard let self else { c.cancel(); return }
      // Only this proxy itself may connect here (it forwards CONNECTs it has already checked). Anyone else is refused.
      guard case .hostPort(_, let peerPort) = c.endpoint, let me = self.tlsListeners[host] ?? l.port?.rawValue,
            ProcessLookup.isOwnConnection(from: peerPort.rawValue, to: me) else {
        if ProcessInfo.processInfo.environment["KEYDILLO_DEBUG"] != nil {
          FileHandle.standardError.write(Data("keydillo run: refused a direct connection to the \(host) listener\n".utf8))
        }
        c.cancel(); return
      }
      // Our side may not have recorded who this connection is for yet: wait briefly.
      func attempt(_ tries: Int) {
        self.lock.lock(); let caller = self.callerByPort.removeValue(forKey: peerPort.rawValue); self.lock.unlock()
        if let caller { c.start(queue: self.queue); self.serve(c, host: host, buf: Data(), caller: caller); return }
        if tries <= 0 { c.cancel(); return }
        self.queue.asyncAfter(deadline: .now() + .milliseconds(10)) { attempt(tries - 1) }
      }
      attempt(100)
    }
    l.start(queue: listenerQueue)   // not `queue`: we may be called from it, and we wait for .ready below
    _ = ready.wait(timeout: .now() + 5)
    guard let p = l.port?.rawValue else { throw VaultError.invalidConfig("tls listener failed") }
    tlsListeners[host] = p
    return p
  }

  /// Decrypted HTTP/1.1 from the client for `host`.
  func serve(_ c: NWConnection, host: String, buf: Data, caller: Int32) {
    c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] d, _, done, err in
      guard let self else { return }
      var b = buf; if let d { b.append(d) }
      switch HTTPParser.parse(b) {
      case .incomplete:
        if done || err != nil { c.cancel() } else { self.serve(c, host: host, buf: b, caller: caller) }
      case .invalid(let status, let reason):
        c.send(content: HTTPResponse.error(status, reason).serialized(), completion: .contentProcessed { _ in c.cancel() })
      case .complete(let req, let consumed):
        self.route(req, extra: b.suffix(from: b.startIndex + consumed), client: c, host: host, caller: caller)
      }
    }
  }

  /// A plain http:// request through the proxy: keyed ones go to the app, everything else straight to its server.
  func forwardPlain(_ req: HTTPRequest, extra: Data, client c: NWConnection, caller: Int32) {
    guard let u = URL(string: req.target), u.scheme?.lowercased() == "http", let host = u.host?.lowercased() else {
      c.send(content: HTTPResponse.error(400, "expected an absolute http:// URL").serialized(), completion: .contentProcessed { _ in c.cancel() }); return
    }
    var path = u.path.isEmpty ? "/" : u.path
    if let q = u.query { path += "?" + q }
    var origin = req; origin.target = path
    if placeholderService(origin) != nil {
      route(origin, extra: extra, client: c, host: host, caller: caller); return
    }
    let port = UInt16(u.port ?? 80)
    let dial = host == "0.0.0.0" ? "127.0.0.1" : host
    let upstream = NWConnection(host: NWEndpoint.Host(dial), port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
    var head = "\(req.method) \(path) HTTP/1.1\r\nHost: \(u.port.map { "\(host):\($0)" } ?? host)\r\n"
    for (k, v) in req.headers where !["host", "proxy-connection", "proxy-authorization", "connection", "keep-alive", "transfer-encoding", "content-length"].contains(k.lowercased()) {
      head += "\(k): \(v)\r\n"
    }
    if !req.body.isEmpty { head += "Content-Length: \(req.body.count)\r\n" }
    head += "Connection: close\r\n\r\n"
    var answered = false
    upstream.stateUpdateHandler = { st in
      switch st {
      case .failed(let e), .waiting(let e):
        guard !answered else { return }; answered = true
        upstream.cancel()
        c.send(content: HTTPResponse.error(502, "keydillo couldn't reach \(host):\(port) (\(e.localizedDescription))").serialized(),
               completion: .contentProcessed { _ in c.cancel() })
      case .ready: answered = true
      default: break
      }
    }
    upstream.start(queue: queue)
    upstream.send(content: Data(head.utf8) + req.body + extra, completion: .idempotent)
    pipe(c, upstream); pipe(upstream, c)
  }

  /// The service whose placeholder appears anywhere in the request: headers (incl. client-built Basic auth),
  /// path, query or body. The app then decides whether that spot is allowed for the key.
  func placeholderService(_ req: HTTPRequest) -> String? {
    for (k, v) in req.headers {
      if let n = Placeholder.service(in: v) { return n }
      if k.lowercased() == "authorization", v.lowercased().hasPrefix("basic "),
         let d = Data(base64Encoded: String(v.dropFirst(6)).trimmingCharacters(in: .whitespaces)),
         let n = Placeholder.service(in: String(decoding: d, as: UTF8.self)) { return n }
    }
    let target = req.target.replacingOccurrences(of: "%3A", with: ":").replacingOccurrences(of: "%3a", with: ":")
    if let n = Placeholder.service(in: target) { return n }
    if req.body.range(of: Data("keydillo".utf8)) != nil {
      let text = String(decoding: req.body, as: UTF8.self).replacingOccurrences(of: "%3A", with: ":").replacingOccurrences(of: "%3a", with: ":")
      if let n = Placeholder.service(in: text) { return n }
    }
    return nil
  }

  var warned = Set<String>()

  /// Sends the request on as raw HTTP and pipes the answer back as it arrives (streaming, websockets).
  func route(_ req: HTTPRequest, extra: Data, client c: NWConnection, host: String, caller: Int32) {
    let named = placeholderService(req)
    var upstream: NWConnection
    var toApp = false
    var newHost: String?
    var target = req.target
    if let named {
      guard let svc = services.first(where: { $0.name == named }) else {
        let r = HTTPResponse.error(404, "no key named '\(named)' is stored", code: "unknown_service")
        c.send(content: r.serialized(), completion: .contentProcessed { _ in c.cancel() }); return
      }
      // A host the key hasn't been sent to before: the app asks the user, with Touch ID naming this host.
      newHost = Self.hosts(of: svc).contains(host) ? nil : host
      target = "/\(svc.name)\(req.target)"
      upstream = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: appPort)!, using: .tcp)
      toApp = true
    } else {
      // A stored host with no placeholder: the program read its key from somewhere keydillo doesn't manage.
      lock.lock(); let first = warned.insert(host).inserted; lock.unlock()
      if first {
        FileHandle.standardError.write(Data("keydillo run: a request to \(host) carried no keydillo placeholder, so it was sent as is. If it fails with 401, the program read its key from somewhere else (another env var, a config file, a different process).\n".utf8))
      }
      if let up = upstreamProxy, !up.bypasses(host) {
        // Through the user's own proxy: use URLSession, which knows how to tunnel.
        Task {
          let resp = await self.forwardViaSession(req, host: host)
          c.send(content: resp.serialized(), completion: .contentProcessed { _ in c.cancel() })
        }
        return
      }
      upstream = NWConnection(host: NWEndpoint.Host(host), port: 443, using: .tls)
    }
    let upgrade = req.headers.contains { $0.0.lowercased() == "upgrade" }
    var head = "\(req.method) \(target) HTTP/1.1\r\nHost: \(named != nil ? "localhost" : host)\r\n"
    var hasLength = false
    for (k, v) in req.headers {
      let lk = k.lowercased()
      if ["host", "proxy-connection", "proxy-authorization", "transfer-encoding", "x-keydillo-caller", "x-keydillo-target-host"].contains(lk) { continue }
      if !upgrade && (lk == "connection" || lk == "keep-alive") { continue }
      // Ask for uncompressed replies so keydillo can scrub any echoed key.
      if lk == "accept-encoding" { continue }
      if lk == "content-length" { hasLength = true; head += "Content-Length: \(req.body.count)\r\n"; continue }
      head += "\(k): \(v)\r\n"
    }
    if !hasLength && !req.body.isEmpty { head += "Content-Length: \(req.body.count)\r\n" }
    head += "Accept-Encoding: identity\r\n"
    // One request per connection: the client opens a new one for its next request, which keydillo checks again.
    if !upgrade { head += "Connection: close\r\n" }
    // Tells the app which program actually made the request (the app checks it came from keydillo's own binary).
    if named != nil { head += "X-Keydillo-Caller: \(caller)\r\n" }
    if let h = newHost { head += "X-Keydillo-Target-Host: \(h)\r\n" }
    head += "\r\n"
    var answered = false
    upstream.stateUpdateHandler = { st in
      switch st {
      case .ready: answered = true
      case .waiting, .failed:
        // Refused connections leave NWConnection waiting forever: answer right away instead of hanging.
        guard !answered else { if case .failed = st { c.cancel() }; return }
        answered = true; upstream.cancel()
        let paused: Bool = { if case .status(let st)? = try? ControlSocket.send(.status) { return st.proxyState == "paused" }; return false }()
        let r = !toApp ? HTTPResponse.error(502, "couldn't reach \(host)")
          : paused ? HTTPResponse.error(503, "keydillo is paused, so it isn't handing out keys", code: "keydillo_paused", hint: "Resume keydillo from the menu bar, then try again.")
          : HTTPResponse.error(503, "the keydillo app isn't running, so the key couldn't be added", code: "keydillo_not_running",
                               hint: "Open keydillo (it restarts by itself within a few seconds if it crashed) and try again.")
        c.send(content: r.serialized(), completion: .contentProcessed { _ in c.cancel() })
      default: break
      }
    }
    upstream.start(queue: queue)
    upstream.send(content: Data(head.utf8) + req.body + extra, completion: .idempotent)
    pipe(c, upstream); pipe(upstream, c)
  }

  func forwardViaSession(_ req: HTTPRequest, host: String) async -> HTTPResponse {
    guard let url = URL(string: "https://\(host)\(req.target)") else { return .error(400, "bad path", code: "bad_path") }
    var out = URLRequest(url: url)
    out.httpMethod = req.method
    for (k, v) in req.headers where !["host", "content-length", "connection", "proxy-connection", "transfer-encoding"].contains(k.lowercased()) {
      out.addValue(v, forHTTPHeaderField: k)
    }
    if !req.body.isEmpty { out.httpBody = req.body }
    do {
      let (data, resp) = try await session.data(for: out)
      guard let http = resp as? HTTPURLResponse else { return .error(502, "bad response", code: "upstream_failed") }
      let headers = http.allHeaderFields.compactMap { k, v -> (String, String)? in
        guard let k = k as? String, let v = v as? String else { return nil }
        return ["content-length", "content-encoding", "transfer-encoding", "connection"].contains(k.lowercased()) ? nil : (k, v)
      }
      return HTTPResponse(status: http.statusCode, headers: headers, body: data)
    } catch {
      return .error(502, "request failed: \(error.localizedDescription)", code: "upstream_failed")
    }
  }
}
