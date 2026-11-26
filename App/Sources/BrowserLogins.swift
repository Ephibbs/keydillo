import SwiftUI
import AppKit
import Security
import LocalAuthentication
import VaultCore

/// Website logins and keydillo's browser tool: Claude signs in, signs up and creates API keys in a browser keydillo
/// controls, and never sees the password or key. The app starts the tool and is the only thing it can ask for one.
@MainActor
final class BrowserService {
  static let shared = BrowserService()
  private var host: BrowserHost?

  var keychain: KeychainBackend { AppModel.shared.keychain }

  var logins: [LoginRecord] { keychain.loadLogins() }

  /// Where the tool lives: inside the signed app bundle. A debug build can point at a checkout instead.
  nonisolated static func toolPaths() -> (node: String, server: String)? {
    #if DEBUG
    if let root = UserDefaults.standard.string(forKey: "browserDevRoot") {
      return ("/opt/homebrew/bin/node", (root as NSString).appendingPathComponent("src/server.mjs"))
    }
    #endif
    guard let res = Bundle.main.resourceURL?.appendingPathComponent("browser") else { return nil }
    let node = res.appendingPathComponent("node").path, server = res.appendingPathComponent("server/src/server.mjs").path
    guard FileManager.default.isExecutableFile(atPath: node), FileManager.default.fileExists(atPath: server) else { return nil }
    return (node, server)
  }

  /// The tool's code ships inside the app, so the app's signature covers it. Refuse to start it if the bundle was changed.
  nonisolated static func bundleIntact() -> Bool {
    #if DEBUG
    if UserDefaults.standard.string(forKey: "browserDevRoot") != nil { return true }
    #endif
    var code: SecStaticCode?
    guard SecStaticCodeCreateWithPath(Bundle.main.bundleURL as CFURL, [], &code) == errSecSuccess, let code else { return false }
    let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
    return SecStaticCodeCheckValidity(code, flags, nil) == errSecSuccess
  }

  func start() throws -> String {
    if let host, host.isRunning { return host.paths.socket }
    guard AppModel.shared.storageSecure else { throw VaultError.invalidConfig(AppModel.insecureMessage) }
    guard let tool = Self.toolPaths() else { throw VaultError.invalidConfig("This build of keydillo doesn't include the browser tool.") }
    guard Self.bundleIntact() else { throw VaultError.invalidConfig("keydillo's app bundle has been changed, so it won't start the browser tool. Reinstall keydillo.") }
    let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/keydillo/browser").path
    let broker = BrowserBroker(
      store: keychain,
      approve: { reason in await MainActor.run { AppModel.shared }.authenticate(reason) },
      saveKey: { key in try await MainActor.run { BrowserService.shared }.saveCaptured(key) },
      note: { text in Task { @MainActor in BrowserService.shared.log(text) } },
      requestLogin: { name, site, username in
        await withCheckedContinuation { cont in
          Task { @MainActor in
            WindowManager.shared.showAddLogin(prefill: AddLoginRequest(name: name, site: site, username: username, requester: "Claude")) { cont.resume(returning: $0) }
          }
        }
      },
      handoff: { op, args in try await BrowserHandoff.shared.handle(op, args) })
    // Prototype switch: drive the user's own Chrome through the keydillo extension instead of a separate browser.
    //   defaults write com.studiokillswitch.keydillo browserUseChrome -bool true
    let chrome = UserDefaults.standard.bool(forKey: "browserUseChrome") ? ["--chrome"] : []
    let h = BrowserHost(paths: .init(node: tool.node, server: tool.server, dataDir: support, socket: BrowserHost.defaultSocket), broker: broker, extraArgs: chrome)
    try h.ensureRunning()
    host = h
    return h.paths.socket
  }

  func stop() { host?.stop(); host = nil }

  func log(_ text: String) {
    AppModel.shared.events.insert(ActivityEvent(date: Date(), service: "browser", method: "", path: "", process: "keydillo browser",
                                                pid: 0, outcome: .sent, status: 0, note: text), at: 0)
  }

  /// How known providers take their key. Anything else defaults to a Bearer token, which Claude can change
  /// with request_key_change (Touch ID).
  static let providerAuth: [String: (header: String, prefix: String, display: String)] = [
    "api.openai.com": ("Authorization", "Bearer ", "OpenAI"),
    "api.anthropic.com": ("x-api-key", "", "Anthropic"),
    "api.github.com": ("Authorization", "Bearer ", "GitHub"),
    "api.stripe.com": ("Authorization", "Bearer ", "Stripe"),
    "api.elevenlabs.io": ("xi-api-key", "", "ElevenLabs"),
  ]

  /// A key the browser tool captured. Touch ID already happened in the broker.
  func saveCaptured(_ key: BrowserBroker.CapturedKey) async throws -> String {
    let model = AppModel.shared
    if model.service(named: key.name) != nil { throw VaultError.invalidConfig("A key named \(key.name) already exists. Pick another name, or ask the user to rotate it in keydillo.") }
    let auth = Self.providerAuth[key.host] ?? ("Authorization", "Bearer ", HostCheck.displayName(key.name))
    var config = ServiceConfig(name: key.name, displayName: auth.display, project: key.project.flatMap { $0.isEmpty ? nil : $0 } ?? "Personal",
                               upstreamHost: key.host, authHeader: auth.header, authPrefix: auth.prefix)
    config.keyPageURL = AppModel.safeKeyPage(key.keysURL)
    try model.saveApproved(config, secret: key.value)
    // .env lines for the app: the local base URL and the placeholder.
    return model.summary(config).placeholderEnvLines.joined(separator: "\n")
  }

  /// A login typed by the user in keydillo's window.
  func add(name: String, site: String, username: String, password: String, totp: String) async -> String? {
    guard LoginRules.isValidName(name) else { return "Name: letters, digits, dots and dashes." }
    guard let site = LoginRules.normalizeSite(site) else { return "Site must be an https address, like https://github.com." }
    guard !password.isEmpty else { return "Enter the password." }
    let t = totp.replacingOccurrences(of: " ", with: "").uppercased()
    guard await AppModel.shared.authenticate("save your \(URL(string: site)?.host ?? site) login") != nil else { return "Cancelled." }
    do {
      try keychain.setLoginSecret(LoginSecret(password: password, totp: t.isEmpty ? nil : t), for: name)
      var all = keychain.loadLogins().filter { $0.name != name }
      all.append(LoginRecord(name: name, site: site, username: username, hasTotp: !t.isEmpty))
      try keychain.saveLogins(all.sorted { $0.name < $1.name })
    } catch { return error.localizedDescription }
    return nil
  }

  func remove(_ name: String) async -> Bool {
    guard await AppModel.shared.authenticate("delete your \(name) login") != nil else { return false }
    keychain.deleteLoginSecret(name)
    try? keychain.saveLogins(keychain.loadLogins().filter { $0.name != name })
    return true
  }
}

// MARK: Views

struct LoginsView: View {
  /// Screen previews only.
  static var previewLogins: [LoginRecord]?
  @State private var logins: [LoginRecord] = []
  @State private var adding = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      HStack {
        VStack(alignment: .leading, spacing: 4) {
          Text("Website logins").font(.system(size: 20, weight: .semibold))
          Text("Claude signs in with these in keydillo's browser. It never sees the passwords.")
            .font(.system(size: 13)).foregroundStyle(Theme.secondary)
        }
        Spacer()
        Button("Add login") { WindowManager.shared.showAddLogin(prefill: nil) { _ in reload() } }.buttonStyle(SmallPrimaryStyle())
      }
      if logins.isEmpty {
        Text("No logins yet.").foregroundStyle(Theme.secondary).padding(.top, 20)
      } else {
        ScrollView {
          VStack(spacing: 8) {
            ForEach(logins, id: \.name) { l in
              HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                  Text(l.name).font(.system(size: 14, weight: .medium))
                  Text("\(l.username) · \(l.site)\(l.hasTotp ? " · 2FA" : "")").font(.system(size: 12)).foregroundStyle(Theme.secondary)
                  if !l.pages.isEmpty {
                    Text("Approved pages: " + l.pages.map { URL(string: $0.page)?.path ?? $0.page }.joined(separator: ", "))
                      .font(.system(size: 11)).foregroundStyle(Theme.secondary)
                  }
                }
                Spacer()
                Button("Delete") { Task { if await BrowserService.shared.remove(l.name) { reload() } } }.buttonStyle(SmallButtonStyle(destructive: true))
              }
              .padding(12).background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
            }
          }
        }
      }
      Spacer(minLength: 0)
    }
    .padding(24)
    .onAppear(perform: reload)
  }

  func reload() { logins = Self.previewLogins ?? BrowserService.shared.logins }
}

struct AddLoginView: View {
  var prefill: AddLoginRequest?
  var done: (Bool) -> Void
  @State private var name = ""
  @State private var site = ""
  @State private var username = ""
  @State private var password = ""
  @State private var totp = ""
  @State private var error: String?
  @State private var saving = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Save a website login").font(.system(size: 17, weight: .semibold))
      if let who = prefill?.requester {
        Text("\(who) asked for this. Claude won't see the password.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
      }
      FilledField(placeholder: "Name, e.g. github", text: $name)
      FilledField(placeholder: "Site, e.g. https://github.com", text: $site)
      FilledField(placeholder: "Username or email", text: $username)
      FilledField(placeholder: "Password", text: $password, secure: true)
      FilledField(placeholder: "2FA setup key (optional)", text: $totp, secure: true, monospaced: true)
      if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger) }
      HStack {
        Spacer()
        Button("Cancel") { done(false) }.buttonStyle(SmallButtonStyle())
        Button(saving ? "Saving…" : "Save") {
          saving = true
          Task {
            error = await BrowserService.shared.add(name: name, site: site, username: username, password: password, totp: totp)
            saving = false
            if error == nil { password = ""; totp = ""; done(true) }
          }
        }.buttonStyle(SmallPrimaryStyle()).disabled(saving)
      }
    }
    .padding(20).frame(width: 380)
    .onAppear {
      if let p = prefill { name = p.name ?? ""; site = p.site ?? ""; username = p.username ?? "" }
    }
  }
}

extension WindowManager {
  func showAddLogin(prefill: AddLoginRequest?, finished: @escaping (Bool) -> Void) {
    let id = "add-login"
    var reported = false
    let report: (Bool) -> Void = { ok in guard !reported else { return }; reported = true; finished(ok) }
    show(id, title: "Save a website login", floating: true, onClose: { report(false) }) {
      AddLoginView(prefill: prefill) { ok in report(ok); WindowManager.shared.close(id) }.sheetCard()
    }
  }
}
