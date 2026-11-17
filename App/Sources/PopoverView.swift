import SwiftUI
import VaultCore

struct PopoverView: View {
  @Environment(AppModel.self) private var model

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text("keydillo").font(.system(size: 16, weight: .semibold))
        Spacer()
        HStack(spacing: 6) {
          StatusDot(on: model.proxyRunning)
          Text(model.proxyRunning ? "On · :\(String(model.port))" : (model.paused ? "Paused" : "Off"))
        }
        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
      }
      .padding(.horizontal, 16).padding(.top, 14).padding(.bottom, 10)

      if model.storageSecure && !model.servicesLoaded {
        Text("Your keys load once the Mac is unlocked.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
      }
      if !model.storageSecure {
        Text(AppModel.insecureMessage).font(.system(size: 12)).foregroundStyle(Theme.danger)
          .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 16).padding(.bottom, 12)
      }
      if let c = model.portConflict { portCard(c) }
      if !model.realKeyFiles.isEmpty { realKeysCard }
      ForEach(model.pending) { p in pendingCard(p) }

      if !model.activeGrants.isEmpty {
        Text("Open right now").font(.system(size: 12)).foregroundStyle(Theme.secondary).padding(.horizontal, 16).padding(.bottom, 6)
        VStack(spacing: 0) {
          ForEach(model.activeGrants, id: \.service) { g in
            HStack {
              VStack(alignment: .leading, spacing: 1) {
                let s = model.service(named: g.service)
                Text("\(s?.displayName ?? g.service)\(s.map { " · " + $0.project } ?? "")").font(.system(size: 13, weight: .medium))
                Text(grantText(g)).font(.system(size: 12)).foregroundStyle(Theme.secondary)
              }
              Spacer()
              Button("End") { model.endGrant(g.service) }.buttonStyle(SmallButtonStyle())
            }
            .padding(10)
          }
        }
        .padding(.horizontal, 6)
      } else if model.pending.isEmpty {
        Text(model.services.isEmpty ? "No keys yet." : "\(model.services.count) key\(model.services.count == 1 ? "" : "s") locked. Nothing open right now.")
          .font(.system(size: 13)).foregroundStyle(Theme.secondary).padding(.horizontal, 16).padding(.bottom, 12)
      }

      Divider().overlay(Theme.hairline).padding(.top, 8)
      VStack(alignment: .leading, spacing: 0) {
        menuRow("Open keydillo…") { StatusItem.shared?.close(); WindowManager.shared.showMain() }
        menuRow(model.paused ? "Resume proxy" : "Pause proxy") { model.togglePause() }
        menuRow("Quit") { NSApp.terminate(nil) }
      }
      .padding(6)
    }
    .frame(width: 340)
    .background(Theme.background)
    .foregroundStyle(Theme.text)
    .task { await model.refreshGrants() }
  }

  var realKeysCard: some View {
    let names = model.realKeyFiles.map { (($0 as NSString).deletingLastPathComponent as NSString).lastPathComponent }
    return VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 3) {
        Text("Real keys are back in \(names.count == 1 ? names[0] + "'s .env" : "\(names.count) .env files")").font(.system(size: 14, weight: .semibold))
        Text("Something wrote real values over the placeholders (for example `vercel env pull`). Lock them away again?")
          .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
      }
      Button("Review and re-import") { StatusItem.shared?.close(); WindowManager.shared.showImport(only: model.realKeyFiles) }
        .buttonStyle(SmallPrimaryStyle())
    }
    .padding(14)
    .background(RoundedRectangle(cornerRadius: 18).fill(Theme.fill))
    .padding(.horizontal, 12).padding(.bottom, 14)
  }

  func pendingCard(_ p: PendingApproval) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 3) {
        Text("\(p.request.client.friendlyName) wants your \(p.request.displayName) key").font(.system(size: 14, weight: .semibold))
        Text("\(p.project.isEmpty ? "" : p.project + " · ")\(p.request.method) \(p.request.path) · pid \(String(p.request.client.pid))")
          .font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1).truncationMode(.middle)
      }
      HStack(spacing: 6) {
        Button("Deny") { model.deny(p) }.buttonStyle(SmallButtonStyle())
        Button(model.windowUpgrades.contains(p.id) ? "15 min ✓" : "15 min") { model.allowWindow(p) }.buttonStyle(SmallButtonStyle())
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
