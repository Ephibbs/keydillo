import AppKit
import SwiftUI
import VaultCore

/// Wording shared by onboarding and Settings, so both say the same thing.
enum NeverAskCopy {
  static let title = "Only ask for new keys, new sites and reveals"
  static let short = "Only new keys, sites and reveals"
  static let warning = "Touch ID only to add a key, send a key to a new site, start a program with a startup key, or show a key. AI tools and kd otherwise use and change your keys without asking, even while your Mac is locked."
}


/// Settings block: the switch and the warning.
struct NeverAskSettingsView: View {
  @Environment(AppModel.self) private var model
  @State private var working = false
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Toggle(NeverAskCopy.title, isOn: Binding(get: { model.neverAsk }, set: { v in
        working = true
        Task { error = await model.setNeverAsk(v); working = false }
      }))
      .toggleStyle(.switch).disabled(working)
      Text(model.neverAsk ? NeverAskCopy.warning : NeverAskCopy.warning + " Turning it on takes one last Touch ID.")
        .font(.system(size: 12)).foregroundStyle(model.neverAsk ? Theme.danger : Theme.secondary).fixedSize(horizontal: false, vertical: true)
      if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true) }
    }
  }
}
