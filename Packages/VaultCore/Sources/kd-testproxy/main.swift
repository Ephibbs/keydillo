import Foundation
import LocalAuthentication
import VaultCore

// Test-only: runs the real proxy with an approver controlled by a file, and in-memory keys.
// Usage: kd-testproxy <config.json>
// config: {"port": 18787, "services": [ServiceConfig...], "secrets": {"name": "value"}, "decisionFile": "/path"}
// decisionFile contains "approve" (default), "deny" or "locked"; approvals are counted in <decisionFile>.count

struct Config: Decodable { var port: UInt16; var services: [ServiceConfig]; var secrets: [String: String]; var decisionFile: String }

final class FileApprover: Approver, @unchecked Sendable {
  let path: String
  init(path: String) { self.path = path }
  func approve(_ request: ApprovalRequest) async -> ApprovalResult {
    let n = (Int((try? String(contentsOfFile: path + ".count", encoding: .utf8)) ?? "0") ?? 0) + 1
    try? String(n).write(toFile: path + ".count", atomically: true, encoding: .utf8)
    switch (try? String(contentsOfFile: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) {
    case "deny": return .denied
    case "locked": return .unavailable("the Mac is locked")
    default:
      try? await Task.sleep(nanoseconds: 300_000_000)   // a human-ish Touch ID delay, to exercise queueing
      return .approved(nil)
    }
  }
}

final class Secrets: SecretProvider {
  let values: [String: String]
  init(_ v: [String: String]) { values = v }
  func secret(for name: String, context: LAContext?) throws -> Data {
    guard let v = values[name] else { throw VaultError.keyNotFound(name) }
    return Data(v.utf8)
  }
}

let cfg = try JSONDecoder().decode(Config.self, from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
let engine = ProxyEngine(services: { cfg.services }, secrets: Secrets(cfg.secrets), approver: FileApprover(path: cfg.decisionFile))
engine.onEvent = { e in
  let line = "event \(e.outcome.rawValue) \(e.status) \(e.service) \(e.method) \(e.path) \(e.note ?? "")\n"
  FileHandle.standardError.write(Data(line.utf8))
}
let server = ProxyServer(port: cfg.port, engine: engine)
server.identify = { _, _ in ClientProcess(pid: 1, name: "compat-client") }
server.onStateChange = { s in if s == "ready" { print("ready"); fflush(stdout) } }
try server.start()
dispatchMain()
