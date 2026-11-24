import SwiftUI
import VaultCore

/// Wording shared by onboarding and Settings, so both say the same thing.
enum TrustCopy {
  static let section = "Trusted apps"
  static let explain = "A trusted app, and everything it runs, uses and changes your keys without asking, even while your Mac is locked. It still asks to add a key, send a key to a new site, start a program with a startup key, or show a key. Other programs ask as usual."
  static let onboarding = "Claude Code and everything it runs use your keys without asking, even while your Mac is locked. Adding a key, a new site, startup keys and showing a key still ask. Other programs ask once per session."
}

/// Settings section: each app keydillo can verify, with a switch. Trusting one takes Touch ID; removing is instant.
struct TrustedAppsView: View {
  @Environment(AppModel.self) private var model
  @State private var working: String?
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(TrustCopy.section).font(.system(size: 13, weight: .medium))
      ForEach(AppModel.trustableAgents, id: \.self) { agent in
        HStack {
          Text(agent).font(.system(size: 13))
          Spacer()
          Toggle(agent, isOn: Binding(get: { model.trustedAgents.contains(agent) }, set: { v in
            working = agent
            Task { error = await model.setTrusted(agent, v); working = nil }
          }))
          .toggleStyle(.switch).labelsHidden().disabled(working != nil)
        }
        .padding(.horizontal, 12).frame(height: 40)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.fill))
      }
      Text(TrustCopy.explain + (model.neverAsk ? "" : " Trusting an app takes Touch ID."))
        .font(.system(size: 12)).foregroundStyle(model.neverAsk ? Theme.danger : Theme.secondary).fixedSize(horizontal: false, vertical: true)
      if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true) }
    }
  }
}
