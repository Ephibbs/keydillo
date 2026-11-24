import SwiftUI
import VaultCore

/// Shown next to the Touch ID dialog for a key request, so the dialog itself can stay one short line.
/// Approving happens in the Touch ID dialog; Deny here cancels it.
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
      HStack(spacing: 8) {
        Image(systemName: "touchid").foregroundStyle(Theme.secondary)
        Text(span).font(.system(size: 12)).foregroundStyle(Theme.secondary)
        Spacer()
        Button("Deny") { model.deny(pending) }.buttonStyle(SecondaryButtonStyle())
      }
    }
    .frame(width: 340)
  }

  var span: String {
    switch model.access(for: pending.project) {
    case .everyTime: return "Touch ID for this request"
    default: return "Touch ID for this session"
    }
  }
}
