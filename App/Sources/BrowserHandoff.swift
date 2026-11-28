import SwiftUI
import AppKit
import PhoneLink
import VaultCore

extension PhoneApprovals {
  /// What a hand-off needs: this Mac's identity, the paired phone and a transport that carries hand-offs.
  func handoffContext() -> (macID: String, signer: SoftwareSigner, phone: PairedPhone, transport: HandoffTransport)? {
    guard let phone, let t = transport as? HandoffTransport, let me = try? handoffIdentity() else { return nil }
    return (me.id, me.signer, phone, t)
  }
}

/// "Claude needs you in the browser": shown on the Mac, and streamed to the paired iPhone, which can tap and type.
/// The browser tool drives it through the broker (`handoffStart`, `handoffFrame`, `handoffEnd`).
final class BrowserHandoff: @unchecked Sendable {
  static let shared = BrowserHandoff()

  final class Session: @unchecked Sendable {
    let id = UUID().uuidString
    let reason: String
    var url: String
    var host: HandoffHost?
    var macDone = false
    var cancelled = false
    init(reason: String, url: String) { self.reason = reason; self.url = url }
  }

  private var sessions: [String: Session] = [:]
  private let lock = NSLock()

  func session(_ id: String?) -> Session? { lock.withLock { id.flatMap { sessions[$0] } } }

  func handle(_ op: String, _ args: [String: Any]) async throws -> Any {
    switch op {
    case "handoffStart":
      let reason = String((args["reason"] as? String ?? "Finish this step in the browser").prefix(140))
      let url = args["url"] as? String ?? ""
      let s = Session(reason: reason, url: url)
      lock.withLock { sessions[s.id] = s }
      let site = URL(string: url)?.host ?? "the browser"
      if let ctx = PhoneApprovals.shared.handoffContext() {
        // The title the phone shows is keydillo's own wording around Claude's reason.
        s.host = try? HandoffHost(title: "Claude needs you on \(site): \(reason)", url: url, macID: ctx.macID, phone: ctx.phone,
                                  signer: ctx.signer, transport: ctx.transport)
        try? await s.host?.post()
        // The fast direct pipe, for when the phone is near this Mac. Frames and inputs over it are signed and sealed
        // the same way as over iCloud.
        if let h = s.host { h.useDirect(MultipeerDirect(role: .mac, sessionID: h.start.sessionID, name: Host.current().localizedName ?? "Mac")) }
      }
      let phone = s.host != nil
      await MainActor.run { Self.showWindow(s, site: site, phone: phone) }
      return ["session": s.id, "phone": phone]

    case "handoffFrame":
      guard let s = session(args["session"] as? String) else { return ["inputs": [] as [Any], "done": true, "cancelled": true] }
      if let u = args["url"] as? String { s.url = u }
      var inputs: [[String: Any]] = []
      var done = s.macDone, via = "the Mac"
      if let host = s.host, await host.checkJoin() {
        if let b64 = args["jpeg"] as? String, let jpeg = Data(base64Encoded: b64), !jpeg.isEmpty {
          try? await host.send(jpeg: jpeg, width: args["width"] as? Int ?? 0, height: args["height"] as? Int ?? 0, url: s.url)
        }
        for i in await host.newInputs() {
          switch i.action {
          case .done: done = true; via = "their iPhone"
          case .cancel: done = true; s.cancelled = true
          case .tap: if let x = i.x, let y = i.y, (0...1).contains(x), (0...1).contains(y) { inputs.append(["action": "tap", "x": x, "y": y]) }
          case .text, .key: if let t = i.text, t.count <= 200 { inputs.append(["action": i.action.rawValue, "text": t]) }
          case .drag: if let pts = handoffDragPoints(i.text) { inputs.append(["action": "drag", "points": pts.map { [$0.0, $0.1] }]) }
          case .down, .move, .up: if let x = i.x, let y = i.y, (0...1).contains(x), (0...1).contains(y) { inputs.append(["action": i.action.rawValue, "x": x, "y": y]) }
          }
        }
      }
      // "fast": the phone is linked directly, so the browser tool sends frames many times a second.
      return ["inputs": inputs, "done": done, "cancelled": s.cancelled, "via": via, "fast": s.host?.isDirect == true]

    case "handoffEnd":
      guard let s = session(args["session"] as? String) else { return [:] as [String: Any] }
      lock.withLock { sessions[s.id] = nil }
      await s.host?.end()
      await MainActor.run { WindowManager.shared.close("handoff-\(s.id)") }
      return [:] as [String: Any]

    default:
      throw VaultError.invalidConfig("unknown hand-off op")
    }
  }

  @MainActor static func showWindow(_ s: Session, site: String, phone: Bool) {
    WindowManager.shared.show("handoff-\(s.id)", title: "Claude needs you", floating: true, onClose: { s.macDone = true }) {
      VStack(alignment: .leading, spacing: 12) {
        Text("Claude needs you in the browser").font(.system(size: 17, weight: .semibold))
        Text(s.reason).font(.system(size: 14)).fixedSize(horizontal: false, vertical: true)
        Text(phone ? "On \(site). Use the browser window here, or open keydillo on your iPhone. Claude can't see what you type."
                   : "On \(site). Use the browser window here. Claude can't see what you type.")
          .font(.system(size: 12)).foregroundStyle(Theme.secondary)
          .fixedSize(horizontal: false, vertical: true)
        HStack {
          Button("Show browser") {
            NSRunningApplication.runningApplications(withBundleIdentifier: "com.google.Chrome").first?.activate()
          }.buttonStyle(SmallButtonStyle())
          Spacer()
          Button("Cancel") { s.macDone = true; s.cancelled = true; WindowManager.shared.close("handoff-\(s.id)") }.buttonStyle(SmallButtonStyle())
          Button("Done") { s.macDone = true; WindowManager.shared.close("handoff-\(s.id)") }.buttonStyle(SmallPrimaryStyle())
        }
      }
      .padding(20).frame(width: 380).sheetCard()
    }
    StatusItem.shared?.flash()
  }
}
