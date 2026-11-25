import SwiftUI
import VaultCore
import LocalAuthentication
import LocalAuthenticationEmbeddedUI

/// macOS's own Touch ID control, drawn inside keydillo's window. While it's on screen, evaluating the request's
/// LAContext shows the fingerprint prompt here instead of a separate system sheet. "Use Password…" still falls back
/// to the system's password sheet.
struct EmbeddedTouchID: NSViewRepresentable {
  let context: LAContext
  let id: UUID
  func makeNSView(context ctx: Context) -> EmbeddedAuthHost { EmbeddedAuthHost(context: context, id: id) }
  func updateNSView(_ v: EmbeddedAuthHost, context ctx: Context) {}
}

/// Holds macOS's Touch ID control and says when it's on screen. The request's LAContext must not be evaluated
/// before then, or macOS shows its own separate Touch ID sheet instead of the control in the card.
final class EmbeddedAuthHost: NSView {
  /// Cards whose Touch ID control is in a window (read off the main thread by the approver).
  static let ready = StringsBox()
  let id: UUID
  init(context: LAContext, id: UUID) {
    self.id = id
    super.init(frame: NSRect(x: 0, y: 0, width: 36, height: 36))
    let v = LAAuthenticationView(context: context, controlSize: .small)
    v.frame = bounds; v.autoresizingMask = [.width, .height]
    addSubview(v)
  }
  required init?(coder: NSCoder) { nil }
  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    var r = Self.ready.value.filter { $0 != id.uuidString }
    if window != nil { r.append(id.uuidString) }
    Self.ready.value = r
  }
  /// Waits (up to 2 s) until the card for this request shows its Touch ID control.
  static func waitUntilShown(_ id: UUID) async {
    for _ in 0..<40 {
      if ready.value.contains(id.uuidString) {
        try? await Task.sleep(nanoseconds: 50_000_000)   // one more beat for the control to attach to its context
        return
      }
      try? await Task.sleep(nanoseconds: 50_000_000)
    }
  }
}

/// The one window for a key request: the details plus macOS's Touch ID control. Deny cancels it.
struct ApprovalCard: View {
  @Environment(AppModel.self) private var model
  let pending: PendingApproval
  @State var moreOpen = false
  /// Read once when the card opens: the caller may exit while the card is up.
  @State private var command: String = ""
  private let asked = Date()

  var r: ApprovalRequest { pending.request }

  var rows: [(String, String)] {
    let path = r.path.count > 48 ? String(r.path.prefix(47)) + "…" : r.path
    var out: [(String, String)] = [("Site", r.host), ("Request", "\(r.method) \(path)")]
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
            Text(rows[i].1).font(.system(size: 12, design: i < 2 ? .monospaced : .default)).lineLimit(1).truncationMode(.middle)
          }
        }
      }
      .padding(12).frame(maxWidth: .infinity, alignment: .leading)
      .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
      Collapsible(title: "More details", isOpen: $moreOpen) {
        Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 6) {
          ForEach(more.indices, id: \.self) { i in
            GridRow(alignment: .top) {
              Text(more[i].0).font(.system(size: 11)).foregroundStyle(Theme.secondary)
              Text(more[i].1).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
      }
      .onAppear {
        let args = ProcessLookup.arguments(of: r.client.pid)
        command = args.joined(separator: " ")
      }
      if !r.client.agentVerified, r.client.agent != nil {
        Text("Unverified app.").font(.system(size: 12)).foregroundStyle(Theme.danger)
      }
      HStack(spacing: 12) {
        EmbeddedTouchID(context: pending.context, id: pending.id).frame(width: 36, height: 36)
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

  /// Everything else keydillo knows about the request. The key's value is never part of it.
  var more: [(String, String)] {
    var out: [(String, String)] = [("Request", "\(r.method) \(r.host)\(r.path)"), ("Key", "\(r.displayName) (\(r.service))")]
    if !pending.project.isEmpty { out.append(("Project", pending.project)) }
    if !command.isEmpty { out.append(("Command", command)) }
    if !r.client.path.isEmpty { out.append(("Program file", (r.client.path as NSString).abbreviatingWithTildeInPath)) }
    out.append(("Process", "\(r.client.name) (pid \(r.client.pid))"))
    if let a = r.client.agent {
      let who = r.client.agentVerified ? r.client.friendlyName + ", signature checked" : a + ", signature not checked"
      out.append(("Started by", "\(who)\(r.client.agentPid.map { " (pid \($0))" } ?? "")"))
    }
    if let cwd = r.client.cwd { out.append(("Folder", cwd)) }
    out.append(("Asked at", asked.formatted(date: .omitted, time: .standard)))
    return out
  }

  var span: String {
    if let app = pending.trustApp { return "\(app) won't ask again" }
    switch model.access(for: pending.project) {
    case .everyTime: return "For this request"
    default: return "For this session"
    }
  }
}
