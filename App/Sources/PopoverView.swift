import SwiftUI
import VaultCore

struct PopoverView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("keydillo").font(.system(size: 16, weight: .semibold))
        Button("Open") { StatusItem.shared?.close(); WindowManager.shared.showMain() }
          .buttonStyle(SmallButtonStyle(height: 22)).fixedSize().padding(.leading, 4)
        Spacer()
        HStack(spacing: 6) {
          StatusDot(on: model.proxyRunning)
          Text(model.proxyRunning ? "On · :\(String(model.port))" : "Off")
        }
        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
      }
      .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

      // The middle scrolls when there's more than the screen can show; the header and menu stay put.
      FitOrScroll(maxHeight: Self.maxMiddleHeight) {
      VStack(alignment: .leading, spacing: 0) {
      if model.storageSecure && !model.servicesLoaded {
        Text("Your keys load once the Mac is unlocked.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
          .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 16).padding(.bottom, 12)
      }
      if !model.storageSecure {
        Text(AppModel.insecureMessage).font(.system(size: 12)).foregroundStyle(Theme.danger)
          .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 16).padding(.bottom, 12)
      }
      if ShellIntegration.isTranslocated {
        Text("Move keydillo to your Applications folder and open it from there, so kd and Claude can find it.")
          .font(.system(size: 12)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
          .padding(.horizontal, 16).padding(.bottom, 12)
      }
      if let c = model.portConflict { portCard(c) }
      if !model.realKeys.files.isEmpty {
        if dismissedRealKeys == realKeysSignature { realKeysLine } else { realKeysCard }
      }
      ForEach(model.pending) { p in pendingCard(p) }

      if !model.openProjects.isEmpty {
        Text("Open projects").font(.system(size: 12)).foregroundStyle(Theme.secondary).padding(.horizontal, 16).padding(.bottom, 6)
        VStack(spacing: 0) {
          ForEach(model.openProjects, id: \.project) { o in
            HStack {
              VStack(alignment: .leading, spacing: 1) {
                Text(o.project).font(.system(size: 13, weight: .medium))
                Text("Programs in its folder · until keydillo quits")
                  .font(.system(size: 12)).foregroundStyle(Theme.secondary)
              }
              Spacer()
              Button("Close") { model.closeProject(o.project) }.buttonStyle(SmallButtonStyle())
            }
            .padding(10)
          }
        }
        .padding(.horizontal, 6)
      }

      if !model.activeGrants.isEmpty {
        Text("Open right now").font(.system(size: 12)).foregroundStyle(Theme.secondary).padding(.horizontal, 16).padding(.bottom, 6)
        VStack(spacing: 0) {
          ForEach(grantRows.prefix(Self.maxGrantRows)) { r in
            HStack {
              VStack(alignment: .leading, spacing: 1) {
                let s = model.service(named: r.service)
                Text("\(s?.displayName ?? r.service)\(s.map { " · " + $0.project } ?? "")").font(.system(size: 13, weight: .medium))
                HStack(spacing: 0) {
                  // Claude's own words for what the key is being used for, cut short before the lifetime is.
                  if let why = r.purpose { Text("“\(why)” · ").lineLimit(1).truncationMode(.tail) }
                  Text(r.purpose == nil ? r.detail : r.detail.prefix(1).lowercased() + r.detail.dropFirst()).lineLimit(1).fixedSize()
                }
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
              }
              Spacer()
              Button("End") { model.endGrant(r.service) }.buttonStyle(SmallButtonStyle())
            }
            .padding(10)
          }
        }
        .padding(.horizontal, 6)
      } else if model.pending.isEmpty && model.openProjects.isEmpty {
        Text(model.services.isEmpty ? "No keys yet." : "\(model.services.count) key\(model.services.count == 1 ? "" : "s") in keydillo. Nothing has access right now.")
          .font(.system(size: 13)).foregroundStyle(Theme.secondary).padding(.horizontal, 16).padding(.bottom, 12)
      }
      claudeStatusLine

      if !model.activeGrants.isEmpty || !model.openProjects.isEmpty || !model.backgroundRuns.isEmpty {
        let n = Set(model.activeGrants.map { $0.client?.sessionKey ?? "" }).count + model.openProjects.count + model.backgroundRuns.count
        Button {
          StatusItem.shared?.close(); WindowManager.shared.showMain()
          NotificationCenter.default.post(name: .showAccess, object: nil)
        } label: {
          HStack(spacing: 4) {
            let more = grantRows.count - Self.maxGrantRows
            Text(more > 0 ? "\(more) more key\(more == 1 ? "" : "s") ·" : "\(n) \(n == 1 ? "has" : "have") access ·").foregroundStyle(Theme.secondary)
            Text(more > 0 ? "View all" : "View").underline()
          }.font(.system(size: 12))
        }
        .buttonStyle(.plain).padding(.horizontal, 16).padding(.top, 4)
      }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      }

      Divider().overlay(Theme.hairline).padding(.top, 8)
      VStack(alignment: .leading, spacing: 0) {
        menuRow("Put my real keys back…") { StatusItem.shared?.close(); WindowManager.shared.showRestore() }
        menuRow("Quit") {
          // kd won't reopen keydillo after you quit it yourself; opening keydillo again clears this.
          FileManager.default.createFile(atPath: AppModel.quitMarker.path, contents: Data())
          NSApp.terminate(nil)
        }
      }
      .padding(6)
    }
    .frame(width: 340)
    .background(Theme.background)
    .foregroundStyle(Theme.text)
    .task { await model.refreshGrants() }
  }

  @State private var tools = AgentTools.all
  @State private var reconnecting = false
  @State private var reconnectNote: String?

  /// AI tools that use keydillo: one quiet line for the ones that work, and a fix for any whose setup broke.
  /// Tools never set up aren't mentioned.
  var connectedAgents: [String] {
    var out: [String] = tools.filter { $0.status == .connected }.map(\.name)
    let recent = model.agentsSeen.filter { $0.value > Date().addingTimeInterval(-30 * 24 * 3600) }.map(\.key)
    for a in (recent + ClaudeConnector.otherAgentsWithSkill).sorted() where !out.contains(a) { out.append(a) }
    return out
  }

  var broken: [AgentTools.Tool] { tools.filter { $0.status == .needsReconnecting } }

  @ViewBuilder var claudeStatusLine: some View {
    VStack(alignment: .leading, spacing: 4) {
      if !connectedAgents.isEmpty {
        HStack(spacing: 6) { StatusDot(on: true); Text("Connected: " + connectedAgents.joined(separator: ", ")) }
          .font(.system(size: 12)).foregroundStyle(Theme.secondary)
      }
      if !broken.isEmpty {
        Button {
          reconnecting = true
          Task {
            var errs: [String] = []
            for t in broken { if let e = await t.connect() { errs.append(e) } }
            reconnectNote = errs.isEmpty ? nil : errs.joined(separator: "\n")
            tools = AgentTools.all
            reconnecting = false
          }
        } label: {
          HStack(spacing: 4) {
            Text("⚠︎ \(broken.map(\.name).joined(separator: ", ")) needs reconnecting ·").foregroundStyle(Theme.danger)
            Text(reconnecting ? "Connecting…" : "Reconnect").underline()
          }
          .font(.system(size: 12))
        }
        .buttonStyle(.plain).disabled(reconnecting)
      }
      if let reconnectNote {
        Text(reconnectNote).font(.system(size: 12)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
      }
    }
    .padding(.horizontal, 16).padding(.bottom, connectedAgents.isEmpty && broken.isEmpty ? 0 : 10)
    .onAppear { tools = AgentTools.all }
  }

  /// The card shrinks to one line when hidden, until the set of files changes. It never goes away while real keys remain.
  @AppStorage("dismissedRealKeys") private var dismissedRealKeys = ""
  @State private var securing = false
  var realKeysSignature: String { model.realKeys.files.joined(separator: "|") }

  var secureButtonTitle: String { securing ? "Securing…" : "Secure all" }
  func secureAll() { securing = true; Task { _ = await model.secureAll(); securing = false } }

  var realKeysLine: some View {
    Button { secureAll() } label: {
      HStack(spacing: 4) {
        Text("⚠︎ " + model.realKeysText + " ·").foregroundStyle(Theme.danger)
        Text(secureButtonTitle).underline()
      }
      .font(.system(size: 12))
    }
    .buttonStyle(.plain).disabled(securing).padding(.horizontal, 16).padding(.bottom, 10)
  }

  var realKeysCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .top) {
          Text(model.realKeysText).font(.system(size: 14, weight: .semibold))
          Spacer()
          Button { dismissedRealKeys = realKeysSignature } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
            .buttonStyle(.plain).foregroundStyle(Theme.secondary).help("Shrink to one line. It opens again if other files change.").accessibilityLabel("Shrink")
        }
        Text("Any program can read keys in .env files, including AI tools. Keep them there only for tools keydillo doesn't support yet.")
          .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: 8) {
        Button(secureButtonTitle) { secureAll() }.buttonStyle(SmallPrimaryStyle()).disabled(securing)
        Button("Review") { StatusItem.shared?.close(); WindowManager.shared.showImport(only: model.realKeys.files) }.buttonStyle(SmallButtonStyle())
      }
    }
    .padding(14)
    .background(RoundedRectangle(cornerRadius: 18).fill(Theme.fill))
    .padding(.horizontal, 12).padding(.bottom, 14)
  }

  func pendingCard(_ p: PendingApproval) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text("\(p.request.client.friendlyName) wants your \(p.request.displayName) key").font(.system(size: 14, weight: .semibold))
        if let why = p.request.client.purpose {
          Text("“\(why)”").font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.tail)
        }
        Text("\(p.project.isEmpty ? "" : p.project + " · ")\(p.request.method) \(p.request.path) · pid \(String(p.request.client.pid))")
          .font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
      }
      HStack(spacing: 6) {
        Button("Deny") { model.deny(p) }.buttonStyle(SmallButtonStyle())
        Spacer()
        Text("Touch ID to allow").font(.system(size: 12)).foregroundStyle(Theme.secondary)
      }
    }
    .padding(14)
    .background(RoundedRectangle(cornerRadius: 18).fill(Theme.fill))
    .padding(.horizontal, 12).padding(.bottom, 14)
  }

  func portCard(_ c: (port: UInt16, owner: String?, suggestion: UInt16)) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 3) {
        Text("Port \(String(c.port)) is being used\(c.owner.map { " by " + $0 } ?? "")").font(.system(size: 14, weight: .semibold))
        Text("keydillo can't start until it's free, or you can move keydillo to \(String(c.suggestion)). Claude picks up the new address automatically; update any .env files that use :\(String(c.port)).")
          .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
      }
      HStack(spacing: 6) {
        Button("Use \(String(c.suggestion))") { model.movePort(to: c.suggestion) }.buttonStyle(SmallPrimaryStyle())
        Button("Try again") { model.startProxy() }.buttonStyle(SmallButtonStyle())
      }
    }
    .padding(14)
    .background(RoundedRectangle(cornerRadius: 18).fill(Theme.fill))
    .padding(.horizontal, 12).padding(.bottom, 14)
  }

  /// Room for the scrolling middle: the screen's height less the menu bar, the header and the menu rows.
  static var maxMiddleHeight: CGFloat { max(200, ScreenRoom.height - 200) }

  /// The popover shows a few keys; the Access page lists everything.
  static let maxGrantRows = 3

  struct GrantRow: Identifiable {
    let service: String
    let detail: String
    /// The latest reason the AI gave for using this key, if any.
    var purpose: String? = nil
    var id: String { service }
  }

  /// One row per key, however many programs or sessions hold it ("End" ends the key for all of them).
  var grantRows: [GrantRow] {
    let byService = Dictionary(grouping: model.activeGrants, by: \.service)
    return byService.keys.sorted().map { service in
      let gs = byService[service] ?? []
      let sessions = Set(gs.map { $0.client?.sessionKey ?? "" }).count
      let why = gs.lazy.compactMap { $0.client?.purpose }.first   // grants come most recently used first
      if sessions <= 1, let g = gs.first { return GrantRow(service: service, detail: grantText(g), purpose: why) }
      let agents = Set(gs.compactMap { $0.client?.agent })
      let who = agents.count == 1 ? "\(agents.first!) sessions" : "programs"
      return GrantRow(service: service, detail: "\(sessions) \(who) · until each exits", purpose: why)
    }
  }

  func grantText(_ g: (service: String, expires: Date?, client: ClientProcess?)) -> String {
    if let e = g.expires {
      let mins = max(1, Int(e.timeIntervalSinceNow / 60))
      return "\(mins) more minute\(mins == 1 ? "" : "s")"
    }
    return "Until \(g.client?.agent ?? g.client?.name ?? "the program") exits"
  }

  func menuRow(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title).font(.system(size: 13)).frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10).frame(height: 32).contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
