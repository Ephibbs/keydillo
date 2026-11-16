import SwiftUI
import VaultCore

/// Debug-only screen previews for screenshots: `open keydillo.app --args -kdPreview main`.
/// Uses sample data in memory; nothing is written to the Keychain.
@MainActor
enum Preview {
  static func sample() {
    let m = AppModel.shared
    m.services = [
      ServiceConfig(name: "elevenlabs", displayName: "ElevenLabs", project: "Notes", upstreamHost: "api.elevenlabs.io", authHeader: "xi-api-key",
                    approval: .eachRequest, allowed: [PathRule(method: "POST", pattern: "/v1/text-to-speech/*"), PathRule(method: "GET", pattern: "/v1/voices")], maxRequestsPerHour: 30),
      ServiceConfig(name: "anthropic", displayName: "Anthropic", project: "Notes", upstreamHost: "api.anthropic.com", authHeader: "x-api-key", approval: .window(minutes: 15)),
      ServiceConfig(name: "supabase", displayName: "Supabase service role", project: "Notes", upstreamHost: "xyz.supabase.co", authHeader: "apikey", approval: .perProcess),
      ServiceConfig(name: "revenuecat", displayName: "RevenueCat", project: "voiceover", upstreamHost: "api.revenuecat.com", authHeader: "Authorization", authPrefix: "Bearer "),
    ]
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
    sample()
    let wm = WindowManager.shared
    switch screen {
    case "main": wm.showMain()
    case "setup2": wm.show("setup", title: "Setup") { SetupView(step: 1) }
    case "setup3": wm.show("setup", title: "Setup") { SetupView(step: 2) }
    case "key":
      wm.showKeyWindow(KeyRequest(service: "elevenlabs", displayName: "ElevenLabs", host: "api.elevenlabs.io", header: "xi-api-key",
                                  prefix: "", envVarName: "ELEVENLABS_API_KEY", project: "notes-app", requester: "claude", cwd: NSHomeDirectory() + "/Desktop/notes-app"))
    case "keybad":
      wm.showKeyWindow(KeyRequest(service: "elevenlabs", displayName: "ElevenLabs", host: "api.elevenlabs-proxy.net", header: "xi-api-key",
                                  prefix: "", envVarName: "ELEVENLABS_API_KEY", project: "notes-app", requester: "claude", cwd: nil))
    case "saved":
      wm.show("saved", title: "Saved") { SavedView(config: AppModel.shared.services[0], fromAgent: true) {}.sheetCard() }
    case "add": wm.showAddKey(project: "Notes")
    case "readout":
      wm.showReadout(project: "Notes", values: [("ELEVENLABS_API_KEY", "sample-not-a-real-key-1"), ("ANTHROPIC_API_KEY", "sample-not-a-real-key-2")])
    case "settings": wm.showSettings()
    case "popover": DispatchQueue.main.asyncAfter(deadline: .now() + 1) { StatusItem.shared?.open() }
    default: wm.showSetup()
    }
  }
}
