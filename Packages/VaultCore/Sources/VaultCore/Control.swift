import Foundation
import Darwin

/// Messages between the keydillo CLI / MCP server and the app, over a Unix socket.
/// Nothing here ever carries a key value.
public enum ControlRequest: Codable, Equatable {
  case listServices
  case status
  /// Opens the key window so the user can paste a key. Fields are suggestions from the agent.
  case requestSecret(SecretRequest)
  /// Opens all of a project's keys with one Touch ID, for as long as the project's setting allows.
  case openProject(OpenProjectRequest)
}

public struct OpenProjectRequest: Codable, Equatable {
  /// Project name; when nil, the project whose folder contains the caller's working directory.
  public var project: String?
  public init(project: String? = nil) { self.project = project }
}

public struct SecretRequest: Codable, Equatable {
  public var service: String
  public var displayName: String?
  public var host: String
  public var header: String
  public var prefix: String?
  public var envVarName: String?
  public var project: String?
  public var cwd: String?
  public var requester: String?
  /// Provider page where the user manages this key, for "Rotate".
  public var keyPageURL: String?
  public init(service: String, displayName: String? = nil, host: String, header: String, prefix: String? = nil,
              envVarName: String? = nil, project: String? = nil, cwd: String? = nil, requester: String? = nil, keyPageURL: String? = nil) {
    self.service = service; self.displayName = displayName; self.host = host; self.header = header; self.keyPageURL = keyPageURL
    self.prefix = prefix; self.envVarName = envVarName; self.project = project; self.cwd = cwd; self.requester = requester
  }
}

public struct ServiceSummary: Codable, Equatable {
  public var name: String
  public var displayName: String
  public var project: String
  public var host: String
  public var baseURL: String
  public var envVarName: String
  public var baseURLEnvName: String
}

public struct StatusInfo: Codable, Equatable {
  public var proxyRunning: Bool
  public var proxyState: String
  public var port: UInt16
  public var storage: String
  public var services: [ServiceSummary]
  /// Recent refusals in plain words, newest first.
  public var recentBlocks: [String]
  public init(proxyRunning: Bool, proxyState: String, port: UInt16, storage: String, services: [ServiceSummary], recentBlocks: [String]) {
    self.proxyRunning = proxyRunning; self.proxyState = proxyState; self.port = port
    self.storage = storage; self.services = services; self.recentBlocks = recentBlocks
  }
}

public enum ControlResponse: Codable, Equatable {
  case services([ServiceSummary])
  case status(StatusInfo)
  case saved(ServiceSummary, envLines: [String])
  case declined
  case error(String)
  case opened(project: String, services: [String], span: String)
}

public extension ServiceConfig {
  func summary(port: UInt16) -> ServiceSummary {
    ServiceSummary(name: name, displayName: displayName, project: project, host: upstreamHost,
                   baseURL: "http://localhost:\(port)/\(name)\(sdkBasePath ?? "")", envVarName: envVarName,
                   baseURLEnvName: baseURLEnvName ?? Self.derivedBaseEnv(envVarName))
  }

  /// OPENAI_API_KEY / OPENAI_KEY / RESEND_SECRET_KEY → OPENAI_BASE_URL / OPENAI_BASE_URL / RESEND_BASE_URL
  static func derivedBaseEnv(_ env: String) -> String {
    var base = env
    for suffix in ["_SECRET_KEY", "_API_KEY", "_API_TOKEN", "_ACCESS_TOKEN", "_KEY", "_TOKEN", "_SECRET"] where base.hasSuffix(suffix) && base.count > suffix.count {
      base = String(base.dropLast(suffix.count)); break
    }
    return base + "_BASE_URL"
  }
}

public extension ServiceSummary {
  /// Lines for a local .env: the proxy address plus a placeholder in place of the key.
  var placeholderEnvLines: [String] {
    ["\(baseURLEnvName)=\(baseURL)", "\(envVarName)=\(Placeholder.value(for: name))"]
  }
}

public enum ControlSocket {
  public static var path: String {
    let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("keydillo", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir.appendingPathComponent("control.sock").path
  }

  static func address(_ path: String) -> sockaddr_un {
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8.prefix(103))
    withUnsafeMutableBytes(of: &addr.sun_path) { buf in
      for (i, b) in bytes.enumerated() { buf[i] = b }
      buf[bytes.count] = 0
    }
    return addr
  }

  /// One request, one newline-terminated JSON response. Blocks; the app may wait on the user.
  public static func send(_ request: ControlRequest, path: String = ControlSocket.path) throws -> ControlResponse {
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw VaultError.invalidConfig("socket failed") }
    defer { close(fd) }
    var addr = address(path)
    let ok = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard ok == 0 else { throw VaultError.invalidConfig("keydillo isn't running. Open the keydillo app first.") }
    var data = try JSONEncoder().encode(request); data.append(0x0A)
    _ = data.withUnsafeBytes { write(fd, $0.baseAddress, data.count) }
    var out = Data(); var buf = [UInt8](repeating: 0, count: 65536)
    while true {
      let n = read(fd, &buf, buf.count)
      if n <= 0 { break }
      out.append(contentsOf: buf[0..<n])
      if out.last == 0x0A { break }
    }
    return try JSONDecoder().decode(ControlResponse.self, from: out)
  }

  /// Listens on the socket; `handle` may take as long as it needs (it runs on its own task per client).
  /// The handler gets the connecting process as identified by the kernel (LOCAL_PEERPID), not as it describes itself.
  public static func serve(path: String = ControlSocket.path, handle: @escaping @Sendable (ControlRequest, ClientProcess) async -> ControlResponse) throws {
    unlink(path)
    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { throw VaultError.invalidConfig("socket failed") }
    var addr = address(path)
    let bound = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard bound == 0 else { close(fd); throw VaultError.invalidConfig("bind failed") }
    chmod(path, 0o600)
    listen(fd, 16)
    Thread.detachNewThread {
      while true {
        let c = accept(fd, nil, nil)
        if c < 0 { continue }
        var peer: pid_t = 0
        var len = socklen_t(MemoryLayout<pid_t>.size)
        let caller = getsockopt(c, SOL_LOCAL, LOCAL_PEERPID, &peer, &len) == 0 && peer > 0 ? ProcessLookup.describe(peer) : .unknown
        Task.detached {
          var input = Data(); var buf = [UInt8](repeating: 0, count: 65536)
          while input.last != 0x0A {
            let n = read(c, &buf, buf.count)
            if n <= 0 { break }
            input.append(contentsOf: buf[0..<n])
          }
          let response: ControlResponse
          if let req = try? JSONDecoder().decode(ControlRequest.self, from: input) { response = await handle(req, caller) }
          else { response = .error("Bad request") }
          var data = (try? JSONEncoder().encode(response)) ?? Data(); data.append(0x0A)
          _ = data.withUnsafeBytes { write(c, $0.baseAddress, data.count) }
          close(c)
        }
      }
    }
  }
}

/// Placeholder values written into .env files instead of real keys. `keydillo run` recognises them.
public enum Placeholder {
  public static let prefix = "keydillo:"
  /// Self-explaining, so a person who sends it to the real API sees why it failed.
  public static let hint = "start-with-keydillo-run"
  public static func value(for service: String) -> String { prefix + service + ":" + hint }
  /// The service a placeholder stands for, if `s` is (or contains, e.g. "Bearer keydillo:x") one.
  public static func service(in s: String) -> String? {
    guard let r = s.range(of: prefix) else { return nil }
    let name = s[r.upperBound...].prefix { $0.isLetter || $0.isNumber || $0 == "-" }
    return name.isEmpty ? nil : String(name)
  }
}
