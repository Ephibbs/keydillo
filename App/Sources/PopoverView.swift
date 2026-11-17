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
          Text(model.proxyRunning ? "On · :\(String(model.port))" : "Off")
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
      if !model.realKeyFiles.isEmpty {
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
      } else if model.pending.isEmpty && model.openProjects.isEmpty {
        Text(model.services.isEmpty ? "No keys yet." : "\(model.services.count) key\(model.services.count == 1 ? "" : "s") locked. Nothing has access right now.")
          .font(.system(size: 13)).foregroundStyle(Theme.secondary).padding(.horizontal, 16).padding(.bottom, 12)
      }

      if !model.exposed.isEmpty {
        Button { Task { _ = await model.secureAll() } } label: {
          HStack(spacing: 4) {
            Text("⚠︎ Real keys in \(model.exposed.count) project\(model.exposed.count == 1 ? "" : "s") ·").foregroundStyle(Theme.danger)
            Text("Secure all").underline()
          }.font(.system(size: 12))
        }
        .buttonStyle(.plain).padding(.horizontal, 16).padding(.bottom, 6)
      }
      if !model.activeGrants.isEmpty || !model.openProjects.isEmpty {
        let n = Set(model.activeGrants.map { $0.client?.sessionKey ?? "" }).count + model.openProjects.count
        Button {
          StatusItem.shared?.close(); WindowManager.shared.showMain()
          NotificationCenter.default.post(name: .showAccess, object: nil)
        } label: {
          HStack(spacing: 4) {
            Text("\(n) \(n == 1 ? "has" : "have") access ·").foregroundStyle(Theme.secondary)
            Text("View").underline()
          }.font(.system(size: 12))
        }
        .buttonStyle(.plain).padding(.horizontal, 16).padding(.top, 4)
      }

      Divider().overlay(Theme.hairline).padding(.top, 8)
      VStack(alignment: .leading, spacing: 0) {
        menuRow("Open keydillo…") { StatusItem.shared?.close(); WindowManager.shared.showMain() }
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

  /// Hidden until the set of files changes.
  @AppStorage("dismissedRealKeys") private var dismissedRealKeys = ""
  var realKeysSignature: String { model.realKeyFiles.sorted().joined(separator: "|") }
  var realKeysTitle: String {
    let names = model.realKeyFiles.map { (($0 as NSString).deletingLastPathComponent as NSString).lastPathComponent }
    return "Real keys are back in \(names.count == 1 ? names[0] + "'s .env" : "\(names.count) .env files")"
  }

  var realKeysLine: some View {
    Button { StatusItem.shared?.close(); WindowManager.shared.showImport(only: model.realKeyFiles) } label: {
      HStack(spacing: 4) {
        Text(realKeysTitle + " ·").foregroundStyle(Theme.secondary)
        Text("Review").underline()
      }
      .font(.system(size: 12))
    }
    .buttonStyle(.plain).padding(.horizontal, 16).padding(.bottom, 10)
  }

  var realKeysCard: some View {
    VStack(alignment: .leading, spacing: 10) {
      VStack(alignment: .leading, spacing: 3) {
        HStack(alignment: .top) {
          Text(realKeysTitle).font(.system(size: 14, weight: .semibold))
          Spacer()
          Button { dismissedRealKeys = realKeysSignature } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)) }
            .buttonStyle(.plain).foregroundStyle(Theme.secondary).help("Hide. It comes back if other files change.").accessibilityLabel("Hide")
        }
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
