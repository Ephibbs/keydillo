import SwiftUI
import VaultCore
import LocalAuthentication

/// A change Claude (or another program) asked for. Shown in a window that names exactly what changes;
/// nothing happens until the user approves with Touch ID.
struct ChangeProposal: Identifiable {
  let id = UUID()
  var title: String
  var requester: String
  var rows: [(label: String, old: String, new: String)]
  var note: String?
  var warning: String?
  /// Shown in the Touch ID prompt after "keydillo is trying to".
  var touchReason: String
  /// Lets the key be used more widely (another project, another folder): shown as a red action, Decline is the default.
  var loosens = false
  var apply: (LAContext) async throws -> String
}

struct ChangeWindow: View {
  @Environment(AppModel.self) private var model
  let proposal: ChangeProposal
  let finish: (ControlResponse) -> Void
  @State private var busy = false
  @State private var error: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text(proposal.title).font(.system(size: 20, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
        Text("Asked by \(proposal.requester). Nothing changes unless you approve with Touch ID.")
          .font(.system(size: 13)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
      }
      Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
        ForEach(proposal.rows.indices, id: \.self) { i in
          let r = proposal.rows[i]
          GridRow {
            Text(r.label).font(.system(size: 12)).foregroundStyle(Theme.secondary)
            Text(r.old.isEmpty ? "—" : r.old).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.secondary).strikethrough(r.old != r.new)
            Image(systemName: "arrow.right").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
            Text(r.new.isEmpty ? "—" : r.new).font(.system(size: 12, weight: .semibold, design: .monospaced))
          }
        }
      }
      .padding(12).frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
      if let n = proposal.note { Text(n).font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true) }
      if let w = proposal.warning { Text("Note: " + w).font(.system(size: 12)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true) }
      if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger) }
      HStack(spacing: 8) {
        Spacer()
        Button("Decline") { finish(.declined) }.buttonStyle(SecondaryButtonStyle())
        Button(busy ? "Approving…" : "Approve with Touch ID") {
          busy = true
          Task {
            defer { busy = false }
            guard let ctx = await model.authenticate(proposal.touchReason) else { return }
            do { finish(.changed(try await proposal.apply(ctx))) } catch { self.error = error.localizedDescription }
          }
        }
        .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction).disabled(busy)
      }
    }
  }
}

