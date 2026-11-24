import AppKit
import SwiftUI
import VaultCore

/// Wording shared by onboarding and Settings, so both say the same thing.
enum NeverAskCopy {
  static let title = "Never ask for Touch ID"
  static let warning = "keydillo won't ask for Touch ID for anything. Any program on this Mac that goes through keydillo can use your keys, including while your Mac is locked, and anyone at your Mac can show them. Keys still stay out of your files and AI chats."
  static let sitesClick = "The first time a key goes to a new site, you'll still get a one-click Allow window."
  static let sitesAuto = "New sites are allowed without asking. A program that's been misled can send your keys to any site."
}

/// The one question left in "Never ask for Touch ID" mode: a click, no Touch ID.
@MainActor enum NewSiteAlert {
  static func ask(_ r: ApprovalRequest) -> Bool {
    NSApp.activate(ignoringOtherApps: true)
    let a = NSAlert()
    a.messageText = "Send your \(r.displayName) key to \(r.host)?"
    let shared = ApprovalRequest.sharedHostingSuffix(r.host).map { " Anyone can host a site on \($0)." } ?? ""
    a.informativeText = "A new site for this key, asked for by \(r.client.friendlyName). keydillo will remember it.\(shared)"
    a.addButton(withTitle: "Don't allow")
    a.addButton(withTitle: "Allow")
    a.window.level = .floating
    return a.runModal() == .alertSecondButtonReturn
  }
}

/// Settings block: the switch, the warning and the new-site choice.
struct NeverAskSettingsView: View {
  @Environment(AppModel.self) private var model
  @State private var working = false
  @State private var error: String?
  @State private var confirmAuto = false

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Toggle(NeverAskCopy.title, isOn: Binding(get: { model.neverAsk }, set: { v in
        working = true
        Task { error = await model.setNeverAsk(v); working = false }
      }))
      .toggleStyle(.switch).disabled(working)
      Text(model.neverAsk ? NeverAskCopy.warning : NeverAskCopy.warning + " Turning it on takes one last Touch ID.")
        .font(.system(size: 12)).foregroundStyle(model.neverAsk ? Theme.danger : Theme.secondary).fixedSize(horizontal: false, vertical: true)
      if model.neverAsk {
        Toggle("Allow new sites without asking", isOn: Binding(get: { model.newSitesAuto }, set: { v in
          if v { confirmAuto = true } else { model.setNewSitesAuto(false) }
        }))
        .toggleStyle(.checkbox)
        Text(model.newSitesAuto ? NeverAskCopy.sitesAuto : NeverAskCopy.sitesClick)
          .font(.system(size: 12)).foregroundStyle(model.newSitesAuto ? Theme.danger : Theme.secondary).fixedSize(horizontal: false, vertical: true)
      }
      if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true) }
    }
    .confirmationDialog("Allow new sites without asking?", isPresented: $confirmAuto) {
      Button("Allow without asking", role: .destructive) { model.setNewSitesAuto(true) }
      Button("Cancel", role: .cancel) {}
    } message: { Text(NeverAskCopy.sitesAuto) }
  }
}
