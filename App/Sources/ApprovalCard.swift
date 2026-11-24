import SwiftUI
import VaultCore
import LocalAuthentication
import LocalAuthenticationEmbeddedUI

/// macOS's own Touch ID control, drawn inside keydillo's window. While it's on screen, evaluating the request's
/// LAContext shows the fingerprint prompt here instead of a separate system sheet. "Use Password…" still falls back
/// to the system's password sheet.
struct EmbeddedTouchID: NSViewRepresentable {
  let context: LAContext
  func makeNSView(context ctx: Context) -> LAAuthenticationView { LAAuthenticationView(context: context, controlSize: .regular) }
  func updateNSView(_ v: LAAuthenticationView, context ctx: Context) {}
}

/// The one window for a key request: the details plus macOS's Touch ID control. Deny cancels it.
struct ApprovalCard: View {
  @Environment(AppModel.self) private var model
  let pending: PendingApproval

  var r: ApprovalRequest { pending.request }

  var rows: [(String, String)] {
    var out: [(String, String)] = [("Site", r.host)]
    if let via = r.viaProgram { out.append(("Program", via)) }
    if let cwd = r.client.cwd { out.append(("Folder", (cwd as NSString).abbreviatingWithTildeInPath)) }
    return out
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("\(r.client.friendlyName) wants to use \(r.displayName)")
        .font(.system(size: 18, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
      if let p = r.client.purpose, !p.isEmpty {
        Text("“\(p)”").font(.system(size: 13)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
      }
      Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 7) {
        ForEach(rows.indices, id: \.self) { i in
          GridRow {
            Text(rows[i].0).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            Text(rows[i].1).font(.system(size: 12, design: i == 0 ? .monospaced : .default)).lineLimit(1).truncationMode(.middle)
          }
        }
      }
      .padding(12).frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
      if !r.client.agentVerified, r.client.agent != nil {
        Text("Unverified app.").font(.system(size: 12)).foregroundStyle(Theme.danger)
      }
      HStack(spacing: 12) {
        EmbeddedTouchID(context: pending.context).frame(width: 32, height: 32)
        VStack(alignment: .leading, spacing: 2) {
          Text("Touch ID to allow").font(.system(size: 13, weight: .medium))
          Text(span).font(.system(size: 12)).foregroundStyle(Theme.secondary)
        }
        Spacer()
        Button("Deny") { model.deny(pending) }.buttonStyle(SecondaryButtonStyle())
      }
    }
    .frame(width: 340)
  }

  var span: String {
    switch model.access(for: pending.project) {
    case .everyTime: return "For this request"
    default: return "For this session"
    }
  }
}
