import SwiftUI
import VaultCore

/// Debug-only screen previews for screenshots: `open keydillo.app --args -kdPreview main`.
/// Uses sample data in memory; nothing is written to the Keychain.
@MainActor
enum Preview {
  static func sample() {
    let m = AppModel.shared
    m.services = [
      ServiceConfig(name: "elevenlabs", displayName: "ElevenLabs", project: "voiceover", upstreamHost: "api.elevenlabs.io", authHeader: "xi-api-key",
                    approval: .eachRequest, allowed: [PathRule(method: "POST", pattern: "/v1/text-to-speech/*"), PathRule(method: "GET", pattern: "/v1/voices")], maxRequestsPerHour: 30),
      ServiceConfig(name: "anthropic", displayName: "Anthropic", project: "voiceover", upstreamHost: "api.anthropic.com", authHeader: "x-api-key", approval: .window(minutes: 15)),
      ServiceConfig(name: "supabase", displayName: "Supabase service role", project: "voiceover", upstreamHost: "xyz.supabase.co", authHeader: "apikey", approval: .perProcess),
      ServiceConfig(name: "revenuecat", displayName: "RevenueCat", project: "notes-app", upstreamHost: "api.revenuecat.com", authHeader: "Authorization", authPrefix: "Bearer "),
    ]
    m.proxyState = "ready"   // previews show the normal running state
    for i in m.services.indices { m.services[i].folder = "/Users/you/Desktop/" + m.services[i].project }
    let now = Date()
    func ev(_ ago: Double, _ svc: String, _ m: String, _ p: String, _ proc: String, _ o: ActivityEvent.Outcome, _ st: Int, _ note: String? = nil) -> ActivityEvent {
      ActivityEvent(date: now.addingTimeInterval(-ago), service: svc, method: m, path: p, process: proc, pid: 48211, outcome: o, status: st, note: note)
    }
    m.events = [
      ev(120, "elevenlabs", "POST", "/v1/text-to-speech/21m00Tcm4TlvDq8ikWAM", "curl via claude", .sent, 200),
      ev(240, "elevenlabs", "GET", "/v1/voices", "claude", .sent, 200),
      ev(300, "elevenlabs", "DELETE", "/v1/voices/abc", "python3", .blocked, 403, "path not allowed"),
      ev(3600, "anthropic", "POST", "/v1/messages", "node", .sent, 200),
    ]
  }

  static func show(_ screen: String) {
    if let a = UserDefaults.standard.string(forKey: "kdAppearance") { NSApp.appearance = NSAppearance(named: a == "dark" ? .darkAqua : .aqua) }
    sample()
    let wm = WindowManager.shared
    switch screen {
    case "main": wm.showMain()
    case "setup2": wm.show("setup", title: "Setup") { SetupView(step: 1) }
    case "setup3": wm.show("setup", title: "Setup") { SetupView(step: 2) }
    case "setup4": wm.show("setup", title: "Setup") { SetupView(step: 3) }
    case "key":
      wm.showKeyWindow(KeyRequest(service: "elevenlabs", displayName: "ElevenLabs", host: "api.elevenlabs.io", header: "xi-api-key",
                                  prefix: "", envVarName: "ELEVENLABS_API_KEY", project: "voiceover", requester: "Claude Code", cwd: NSHomeDirectory() + "/Desktop/voiceover", keyPageURL: "https://elevenlabs.io/app/settings/api-keys"))
    case "keybad":
      wm.showKeyWindow(KeyRequest(service: "elevenlabs", displayName: "ElevenLabs", host: "api.elevenlabs-proxy.net", header: "xi-api-key",
                                  prefix: "", envVarName: "ELEVENLABS_API_KEY", project: "voiceover", requester: "Claude Code", cwd: nil, keyPageURL: "https://elevenlabs-keys.net/login"))
    case "saved":
      wm.show("saved", title: "Saved") { SavedView(config: AppModel.shared.services[0], fromAgent: true) {}.sheetCard() }
    case "add": wm.showAddKey(project: "voiceover")
    case "readout":
      wm.showReadout(project: "voiceover", values: [("ELEVENLABS_API_KEY", "sample-not-a-real-key-1"), ("ANTHROPIC_API_KEY", "sample-not-a-real-key-2")])
    case "settings": wm.showSettings()
    case "pairphone": wm.show("pair", title: "Pair iPhone") { PairPhoneView {} }
    case "restore": wm.showRestore()
    case "project":
      wm.showMain()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NotificationCenter.default.post(name: .selectProject, object: "voiceover") }
    case "frontend":
      AppModel.shared.inFrontend = ["voiceover": [(file: "/Users/x/Desktop/voiceover/.env.local", name: "NEXT_PUBLIC_OPENAI_API_KEY")]]
      wm.showMain()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NotificationCenter.default.post(name: .selectProject, object: "voiceover") }
    case "exposed":
      AppModel.shared.exposed = ["voiceover": [(file: "/Users/x/Desktop/voiceover/.env", name: "TOGETHER_API_KEY"), (file: "/Users/x/Desktop/voiceover/.env.local", name: "OPENAI_API_KEY")]]
      wm.showMain()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NotificationCenter.default.post(name: .selectProject, object: "voiceover") }
    case "access":
      wm.showMain()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NotificationCenter.default.post(name: .showAccess, object: nil) }
    case "change":
      let p = ChangeProposal(title: "Change how your Anthropic key is sent", requester: "Claude Code",
                             rows: [(label: "Header", old: "Authorization", new: "x-api-key"), (label: "Prefix", old: "Bearer ", new: "")],
                             note: "Anthropic's API reads the key from x-api-key; requests are failing with 401.", warning: nil,
                             touchReason: "preview") { _ in "" }
      wm.show("change", title: p.title) { ChangeWindow(proposal: p) { _ in }.sheetCard() }
    case "import":
      let d = NSTemporaryDirectory() + "kd-preview-import"
      try? FileManager.default.createDirectory(atPath: d + "/beta", withIntermediateDirectories: true)
      try? "ACME_API_KEY=acme_FAKEpreview0123456789\nWIDGET_TOKEN=wdg_FAKEpreview0123456789\nJWT_SECRET=FAKEjwtpreview0123456789abcdef\n".write(toFile: d + "/beta/.env", atomically: true, encoding: .utf8)
      wm.show("import", title: "Import keys") { ImportView(reviewOpen: true, inSetup: false, onlyPaths: [d + "/beta/.env"]) {}.sheetCard() }
    case "popover":
      AppModel.shared.realKeyFiles = ["/Users/x/Desktop/voiceover/.env", "/Users/x/Desktop/notes-app/.env"]
      AppModel.shared.exposed = ["voiceover": [(file: "/Users/x/Desktop/voiceover/.env.local", name: "OPENAI_API_KEY")]]
      AppModel.shared.agentsSeen = ["Cursor": Date()]
      DispatchQueue.main.asyncAfter(deadline: .now() + 1) { StatusItem.shared?.open() }
    default: wm.showSetup()
    }
  }
}

/// Development-only UI checks: `KEYDILLO_DEV=1 keydillo.app/Contents/MacOS/keydillo -kdSelfTest import`.
/// Renders a real window from fixture files, reads its accessibility tree in-process, prints PASS/FAIL lines and quits.
@MainActor
enum SelfTest {
  /// The first-run "Connect" step against a throwaway home: run with HOME and CFFIXED_USER_HOME set to a temp folder.
  static func connect() {
    let home = ClaudeConnector.home.path
    guard home.hasPrefix("/private/tmp/") || home.hasPrefix("/tmp/") || home.contains("/T/") else {
      FileHandle.standardError.write(Data("FAIL refusing to touch a real home (\(home))\n".utf8)); exit(1)
    }
    Task {
      let err = await ClaudeConnector.connect()
      FileHandle.standardError.write(Data(((err.map { "FAIL connect: \($0)" } ?? "PASS connect") + "\n").utf8))
      exit(err == nil ? 0 : 1)
    }
  }

  static func run(_ name: String) {
    FileHandle.standardError.write(Data("self-test \(name) starting\n".utf8))
    if name == "connect" { connect(); return }
    guard name == "import" else { FileHandle.standardError.write(Data("FAIL unknown self-test\n".utf8)); exit(1) }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kd-selftest-\(getpid())")
    let a = dir.appendingPathComponent("alpha"), b = dir.appendingPathComponent("beta")
    try? FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
    try? FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
    // Fake values only. alpha: a recognised API (ticked by default). beta: unrecognised keys only (nothing ticked).
    try? "OPENAI_API_KEY=sk-proj-FAKEselftest0123456789abcdef\nPORT=3000\n".write(to: a.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    try? "ACME_API_KEY=acme_FAKEselftest0123456789\nWIDGET_TOKEN=wdg_FAKEselftest0123456789\n".write(to: b.appendingPathComponent(".env"), atomically: true, encoding: .utf8)
    let scenarios: [(String, [String], Int)] = [
      ("two projects, one recognised key", [a.path + "/.env", b.path + "/.env"], 3),
      ("only unrecognised keys", [b.path + "/.env"], 2),
    ]
    var failures = 0
    func say(_ t: String) { FileHandle.standardError.write(Data((t + "\n").utf8)) }
    func check(_ ok: Bool, _ what: String) { say((ok ? "PASS  " : "FAIL  ") + what); if !ok { failures += 1 } }
    func next(_ i: Int) {
      guard i < scenarios.count else {
        try? FileManager.default.removeItem(at: dir)
        say("\n\(failures == 0 ? "all passed" : "\(failures) failed")"); exit(failures == 0 ? 0 : 1)
      }
      let (label, paths, keys) = scenarios[i]
      UIProbe.values = [:]
      // The same window code the app uses for setup and Settings → Import.
      let id = "selftest-\(i)"
      WindowManager.shared.show(id, title: "Import keys") { ImportView(reviewOpen: true, inSetup: true, onlyPaths: paths) {}.sheetCard() }
      DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
        guard let w = NSApp.windows.first(where: { $0.isVisible && $0.title == "Import keys" }), let host = w.contentView else {
          check(false, "the import window opened"); next(i + 1); return
        }
        _ = host
        let listHeight = UIProbe.values["import-list-height"] ?? 0
        let rows = Int(UIProbe.values["import-rows"] ?? 0)
        let primary = UIProbe.values["import-primary"] != nil
        UIProbe.values = [:]
        say("— \(label)")
        check(listHeight > 60, "the list of files and keys is visible (height \(Int(listHeight)))")
        check(rows == keys + paths.count, "a row with a checkbox for every project and key (\(rows) shown, want \(keys + paths.count))")
        check(primary, "there's a primary import button")
        WindowManager.shared.close(id)
        next(i + 1)
      }
    }
    next(0)
  }
}


/// Measurements the UI self-test reads back (sizes and counts as actually laid out). Tiny and always on.
@MainActor
enum UIProbe {
  static var values: [String: Double] = [:]
  static func set(_ k: String, _ v: Double) { values[k] = v }
  static func add(_ k: String, _ v: Double) { values[k, default: 0] += v }
}
