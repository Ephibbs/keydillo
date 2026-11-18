// Test-only: runs BrowserHost + BrowserBroker with in-memory logins and an approver that says yes (and logs the
// Touch ID reason), so the browser tool's app mode can be tested end to end. Never shipped.
//
//   kd-testbrowser --node <node> --server <server.mjs> --socket <path> --data-dir <dir> --site <origin> [--deny-new-pages]
import Foundation
import LocalAuthentication
import VaultCore

let args = CommandLine.arguments
func opt(_ n: String) -> String? { args.firstIndex(of: n).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
guard let node = opt("--node"), let server = opt("--server"), let socket = opt("--socket"), let dir = opt("--data-dir"), let site = opt("--site") else {
  FileHandle.standardError.write(Data("usage: kd-testbrowser --node N --server S --socket P --data-dir D --site ORIGIN\n".utf8)); exit(2)
}
let denyNew = args.contains("--deny-new-pages")

let logins = MemoryLogins()
logins.logins = [LoginRecord(name: "demo", site: site, username: "evan", hasTotp: true)]
logins.secrets = ["demo": LoginSecret(password: "Hunter2-correct", totp: "JBSWY3DPEHPK3PXP")]

func log(_ obj: [String: Any]) {
  let d = try! JSONSerialization.data(withJSONObject: obj)
  print(String(decoding: d, as: UTF8.self)); fflush(stdout)
}

let broker = BrowserBroker(
  store: logins,
  approve: { reason in
    log(["event": "touchid", "reason": reason])
    if denyNew && reason.contains("NEW sign-in page") && reason.contains("/forms/") { return nil }
    return LAContext()
  },
  saveKey: { key in
    log(["event": "saveKey", "name": key.name, "host": key.host, "value": key.value, "project": key.project ?? ""])
    return "keydillo:\(key.name)"
  },
  note: { log(["event": "note", "text": $0]) },
  requestLogin: { name, site, user in
    log(["event": "requestLogin", "name": name ?? "", "site": site ?? "", "username": user ?? ""])
    logins.logins.append(LoginRecord(name: name ?? "added", site: site ?? "", username: user ?? ""))
    logins.secrets[name ?? "added"] = LoginSecret(password: "typed-by-user-123")
    return true
  })

let host = BrowserHost(paths: .init(node: node, server: server, dataDir: dir, socket: socket), broker: broker, extraArgs: ["--headless"])
do { try host.ensureRunning() } catch { log(["event": "error", "text": "\(error)"]); exit(1) }
log(["event": "ready"])
signal(SIGTERM) { _ in exit(0) }
// Report saved logins on demand (stdin line "dump").
Thread.detachNewThread {
  while let line = readLine() {
    if line == "dump" {
      log(["event": "logins", "names": logins.logins.map(\.name), "pages": logins.logins.flatMap { $0.pages.map(\.page) },
           "secrets": logins.secrets.mapValues(\.password)])
    }
  }
  host.stop(); exit(0)
}
dispatchMain()
