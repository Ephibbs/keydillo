// kdlogin: stores website logins in the macOS login Keychain and releases one only after Touch ID.
//
//   kdlogin add <name> --site https://github.com     asks for username, password and optional TOTP secret
//   kdlogin list                                      names, sites and usernames as JSON (no secrets, no prompt)
//   kdlogin get <name> --page URL --action URL        Touch ID, then {"password","totp"} as JSON on stdout
//   kdlogin approve <name> --page URL --action URL    Touch ID to allow one more sign-in page
//
// Each login is locked to the sign-in pages it has been used on (page URL + where the form sends it).
// A page it hasn't seen gets a Touch ID prompt that names the page, and is remembered once approved.
//   kdlogin save-new <name> --site S --username U     Touch ID, then saves a login whose generated password is on stdin
//   kdlogin save-key <name> --host <api host>        Touch ID, then stores the API key read from stdin
//   kdlogin keys                                      saved API keys as JSON (names and hosts only)
//   kdlogin remove <name>
//
// Passwords are only read from the terminal (no echo, no pipes), so they never pass through an agent.

import Foundation
import LocalAuthentication
import Security

let service = "keydillo-login"

struct LoginPage: Codable, Equatable { var page: String; var action: String }
struct Meta: Codable {
  var site: String; var username: String; var hasTotp: Bool; var pages: [LoginPage]?
}
struct Secret: Codable { var password: String; var totp: String? }

func fail(_ msg: String, _ code: Int32 = 1) -> Never {
  FileHandle.standardError.write((msg + "\n").data(using: .utf8)!)
  exit(code)
}

func baseQuery(_ name: String?) -> [String: Any] {
  var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service]
  if let name { q[kSecAttrAccount as String] = name }
  return q
}

func readHidden(_ prompt: String) -> String {
  var buf = [CChar](repeating: 0, count: 4096)
  guard let p = readpassphrase(prompt, &buf, buf.count, RPP_REQUIRE_TTY) else { fail("Run this in a terminal.") }
  return String(cString: p)
}

func readVisible(_ prompt: String) -> String {
  guard isatty(STDIN_FILENO) == 1 else { fail("Run this in a terminal.") }
  print(prompt, terminator: ""); fflush(stdout)
  return (readLine() ?? "").trimmingCharacters(in: .whitespaces)
}

func normalizeSite(_ s: String) -> String {
  guard let u = URL(string: s.contains("://") ? s : "https://" + s), let scheme = u.scheme, let host = u.host else {
    fail("Site must look like https://github.com")
  }
  let local = host == "localhost" || host == "127.0.0.1"
  guard scheme == "https" || local else { fail("Only https sites (http is allowed for localhost).") }
  return "\(scheme)://\(host.lowercased())" + (u.port.map { ":\($0)" } ?? "")
}

func touchID(_ reason: String) {
  let ctx = LAContext()
  var err: NSError?
  guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { fail("Touch ID unavailable: \(err?.localizedDescription ?? "")") }
  let sem = DispatchSemaphore(value: 0)
  var ok = false
  ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason) { success, _ in ok = success; sem.signal() }
  sem.wait()
  if !ok { fail("Denied.", 2) }
}

let args = Array(CommandLine.arguments.dropFirst())
guard let cmd = args.first else { fail("usage: kdlogin add|list|get|approve|save-new|save-key|keys|remove") }

switch cmd {
case "add":
  guard args.count >= 2 else { fail("usage: kdlogin add <name> --site https://example.com") }
  let name = args[1]
  var site = ""
  if let i = args.firstIndex(of: "--site"), i + 1 < args.count { site = args[i + 1] } else { site = readVisible("Site (https://...): ") }
  let meta0 = normalizeSite(site)
  let username = readVisible("Username or email: ")
  let password = readHidden("Password (hidden): ")
  guard !password.isEmpty else { fail("Empty password.") }
  let totpRaw = readHidden("TOTP secret, base32 (Enter to skip): ").replacingOccurrences(of: " ", with: "").uppercased()
  let meta = Meta(site: meta0, username: username, hasTotp: !totpRaw.isEmpty)
  let secret = Secret(password: password, totp: totpRaw.isEmpty ? nil : totpRaw)
  SecItemDelete(baseQuery(name) as CFDictionary)
  var q = baseQuery(name)
  q[kSecValueData as String] = try! JSONEncoder().encode(secret)
  q[kSecAttrGeneric as String] = try! JSONEncoder().encode(meta)
  q[kSecAttrLabel as String] = "keydillo login: \(name)"
  q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
  let s = SecItemAdd(q as CFDictionary, nil)
  guard s == errSecSuccess else { fail("Keychain error \(s)") }
  print("Saved \(name) for \(meta.site).")

case "save-new":
  guard args.count >= 2, let si = args.firstIndex(of: "--site"), si + 1 < args.count,
        let ui = args.firstIndex(of: "--username"), ui + 1 < args.count else { fail("usage: kdlogin save-new <name> --site S --username U") }
  let name = args[1]
  let site = normalizeSite(args[si + 1]), username = args[ui + 1]
  let password = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
  guard password.count >= 12 else { fail("No password on stdin.") }
  let host = URL(string: site)?.host ?? site
  touchID("create an account on \(host) as \(username) and save its new password as \"\(name)\"")
  let meta = Meta(site: site, username: username, hasTotp: false, pages: [])
  SecItemDelete(baseQuery(name) as CFDictionary)
  var q = baseQuery(name)
  q[kSecValueData as String] = try! JSONEncoder().encode(Secret(password: password, totp: nil))
  q[kSecAttrGeneric as String] = try! JSONEncoder().encode(meta)
  q[kSecAttrLabel as String] = "keydillo login: \(name)"
  q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
  let st = SecItemAdd(q as CFDictionary, nil)
  guard st == errSecSuccess else { fail("Keychain error \(st)") }
  print("{}")

case "list":
  var q = baseQuery(nil)
  q[kSecReturnAttributes as String] = true
  q[kSecMatchLimit as String] = kSecMatchLimitAll
  var out: CFTypeRef?
  let s = SecItemCopyMatching(q as CFDictionary, &out)
  var rows: [[String: Any]] = []
  if s == errSecSuccess, let items = out as? [[String: Any]] {
    for it in items {
      guard let name = it[kSecAttrAccount as String] as? String, let g = it[kSecAttrGeneric as String] as? Data,
            let m = try? JSONDecoder().decode(Meta.self, from: g) else { continue }
      rows.append(["name": name, "site": m.site, "username": m.username, "hasTotp": m.hasTotp,
                   "pages": (m.pages ?? []).map { ["page": $0.page, "action": $0.action] }])
    }
  }
  print(String(data: try! JSONSerialization.data(withJSONObject: rows), encoding: .utf8)!)

case "get", "approve":
  guard args.count >= 2, let pi = args.firstIndex(of: "--page"), pi + 1 < args.count,
        let ai = args.firstIndex(of: "--action"), ai + 1 < args.count else {
    fail("usage: kdlogin \(cmd) <name> --page URL --action URL")
  }
  let name = args[1]
  let lp = LoginPage(page: args[pi + 1], action: args[ai + 1])
  var aq = baseQuery(name)
  aq[kSecReturnAttributes as String] = true
  var attrs: CFTypeRef?
  guard SecItemCopyMatching(aq as CFDictionary, &attrs) == errSecSuccess, let a = attrs as? [String: Any],
        let g = a[kSecAttrGeneric as String] as? Data, var m = try? JSONDecoder().decode(Meta.self, from: g) else {
    fail("No login named \(name).", 3)
  }
  // Pages must be on the saved site.
  for u in [lp.page, lp.action] {
    guard let url = URL(string: u), let host = url.host, let scheme = url.scheme,
          "\(scheme)://\(host)" + (url.port.map { ":\($0)" } ?? "") == m.site else { fail("\(u) is not on \(m.site).", 4) }
  }
  let host = URL(string: m.site)?.host ?? m.site
  let known = (m.pages ?? []).contains(lp)
  if known {
    touchID("sign in to \(host) as \(m.username) in the agent's browser")
  } else {
    let shortAction = URL(string: lp.action)?.path ?? lp.action
    touchID("use your \(host) login on a NEW sign-in page: \(lp.page) (sends to \(shortAction))")
    m.pages = (m.pages ?? []) + [lp]
    let upd = SecItemUpdate(baseQuery(name) as CFDictionary, [kSecAttrGeneric as String: try! JSONEncoder().encode(m)] as CFDictionary)
    guard upd == errSecSuccess else { fail("Keychain error \(upd)") }
  }
  if cmd == "approve" { print("{}"); exit(0) }
  var q = baseQuery(name)
  q[kSecReturnData as String] = true
  var out: CFTypeRef?
  let s = SecItemCopyMatching(q as CFDictionary, &out)
  guard s == errSecSuccess, let d = out as? Data else { fail("Keychain error \(s)") }
  FileHandle.standardOutput.write(d)

case "save-key":
  guard args.count >= 2, let hi = args.firstIndex(of: "--host"), hi + 1 < args.count else { fail("usage: kdlogin save-key <name> --host <host>") }
  let name = args[1], host = args[hi + 1].lowercased()
  let value = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
  guard !value.isEmpty else { fail("No key on stdin.") }
  touchID("save a new API key as \"\(name)\" for \(host)")
  var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service + ".keys", kSecAttrAccount as String: name]
  SecItemDelete(q as CFDictionary)
  q[kSecValueData as String] = Data(value.utf8)
  q[kSecAttrComment as String] = host
  q[kSecAttrLabel as String] = "keydillo key: \(name) (\(host))"
  q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
  let st = SecItemAdd(q as CFDictionary, nil)
  guard st == errSecSuccess else { fail("Keychain error \(st)") }
  print("{}")

case "keys":
  let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service + ".keys",
                          kSecReturnAttributes as String: true, kSecMatchLimit as String: kSecMatchLimitAll]
  var out: CFTypeRef?
  var rows: [[String: String]] = []
  if SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] {
    for it in items { rows.append(["name": it[kSecAttrAccount as String] as? String ?? "", "host": it[kSecAttrComment as String] as? String ?? ""]) }
  }
  print(String(data: try! JSONSerialization.data(withJSONObject: rows), encoding: .utf8)!)

case "remove":
  guard args.count >= 2 else { fail("usage: kdlogin remove <name>") }
  let s = SecItemDelete(baseQuery(args[1]) as CFDictionary)
  print(s == errSecSuccess ? "Removed \(args[1])." : "Not found.")

default:
  fail("usage: kdlogin add|list|get|approve|save-new|save-key|keys|remove")
}
