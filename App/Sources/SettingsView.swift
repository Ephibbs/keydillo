import SwiftUI
import ServiceManagement

struct SettingsView: View {
  @Environment(AppModel.self) private var model
  @State private var loginItem = AppModel.shared.openAtLogin
  @State private var connectStatus: [String: String] = [:]
  @State private var tools = AgentTools.all
  @State private var undoStatus: String?
  @State private var showUninstall = false
  @State private var moreOpen = AppModel.devHarness && CommandLine.arguments.contains("-kdMoreOpen")
  @State private var askError: String?
  @State private var askWorking = false
  @State private var loginApproval = AppModel.shared.loginItemNeedsApproval

  static let docsURL = URL(string: "https://ephibbs.github.io/keydillo-site/docs.html")!

  var body: some View {
    FitOrScroll {
    VStack(alignment: .leading, spacing: 18) {
      Text("Settings").font(.system(size: 20, weight: .semibold))
      VStack(alignment: .leading, spacing: 8) {
        Text("Ask for Touch ID").font(.system(size: 13, weight: .medium))
        Picker("", selection: Binding(get: { model.askMode }, set: { m in
          askWorking = true
          Task { askError = await model.setAskMode(m); askWorking = false }
        })) {
          ForEach(AppModel.AskMode.allCases) { Text($0.label).tag($0) }
        }
        .labelsHidden().fixedSize().disabled(askWorking)
        Text(askNote).font(.system(size: 12)).foregroundStyle(model.askMode == .perProject ? Theme.danger : Theme.secondary)
          .fixedSize(horizontal: false, vertical: true)
        if model.askMode == .perApp && !model.trustedAgents.isEmpty {
          ForEach(model.trustedAgents, id: \.self) { agent in
            HStack(spacing: 10) {
              Text(agent).font(.system(size: 13))
              Text("trusted").font(.system(size: 12)).foregroundStyle(Theme.secondary)
              Spacer()
              Button("Remove") { Task { askError = await model.setTrusted(agent, false) } }.buttonStyle(SmallButtonStyle()).fixedSize()
            }
            .padding(.horizontal, 12).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.fill))
          }
        }
        if let askError { Text(askError).font(.system(size: 12)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true) }
      }
      PhoneSettingsSection()
      Toggle("Keep keydillo running", isOn: $loginItem).toggleStyle(.checkbox)
        .help("Starts at login and restarts if it stops.")
        .onChange(of: loginItem) { _, v in model.openAtLogin = v; loginApproval = model.loginItemNeedsApproval }
      if loginApproval {
        HStack(spacing: 8) {
          Text("Turn on keydillo under Allow in the Background in Login Items.").font(.system(size: 12)).foregroundStyle(Theme.danger)
            .fixedSize(horizontal: false, vertical: true)
          Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }.buttonStyle(SmallButtonStyle()).fixedSize()
        }
      }
      Link("How to use keydillo ↗", destination: Self.docsURL).font(.system(size: 13))
      Collapsible(title: "More", isOpen: $moreOpen) {
        VStack(alignment: .leading, spacing: 16) {
          VStack(alignment: .leading, spacing: 8) {
            Text(".env files").font(.system(size: 13, weight: .medium))
            ViewThatFits(in: .horizontal) {
              HStack { envButtons }
              VStack(alignment: .leading, spacing: 8) { envButtons }
            }
          }
          VStack(alignment: .leading, spacing: 8) {
            Text("AI tools").font(.system(size: 13, weight: .medium))
            ForEach(tools.filter(\.installed)) { t in
              HStack {
                Text(t.name).font(.system(size: 13)).frame(width: 96, alignment: .leading)
                Button(t.status == .notConnected ? "Connect" : "Connect again") {
                  Task {
                    let err = await t.connect()
                    connectStatus[t.name] = err ?? t.afterConnect ?? "Connected."
                    tools = AgentTools.all
                  }
                }.buttonStyle(SmallButtonStyle()).fixedSize()
                Text(connectStatus[t.name] ?? (t.status == .needsReconnecting ? "Needs connecting again" : t.status == .connected ? "Connected" : ""))
                  .font(.system(size: 12)).foregroundStyle(t.status == .needsReconnecting && connectStatus[t.name] == nil ? Theme.danger : Theme.secondary)
                  .fixedSize(horizontal: false, vertical: true)
              }
            }
          }
          VStack(alignment: .leading, spacing: 4) {
            Text("Proxy: localhost:\(String(model.port))").font(.system(size: 12)).foregroundStyle(Theme.secondary)
            Text("Storage: \(model.storageDescription)").font(.system(size: 12)).foregroundStyle(Theme.secondary)
          }
          Button("Uninstall keydillo…") { showUninstall = true }.buttonStyle(SmallButtonStyle(destructive: true)).fixedSize()
        }
      }
    }
    .padding(24).frame(minWidth: 340, idealWidth: 460, maxWidth: 640, alignment: .leading)
    }
    .background(Theme.background).foregroundStyle(Theme.text)
    .sheet(isPresented: $showUninstall) { UninstallView { showUninstall = false } }
  }

  var askNote: String {
    switch model.askMode {
    case .everyTime, .perSession: return "Projects can change this on their page."
    case .perApp: return "Claude Code and Cursor ask once, then use your keys without asking, even while your Mac is locked. New keys, new sites and showing a key still ask. Other programs ask once per session."
    case .perProject: return "Any program in a project's folder can use its keys until keydillo quits, even while your Mac is locked."
    }
  }

  @ViewBuilder var envButtons: some View {
    Button("Import keys…") { WindowManager.shared.showImport() }.buttonStyle(SmallButtonStyle()).fixedSize()
    Button("Put my real keys back…") { WindowManager.shared.showRestore() }.buttonStyle(SmallButtonStyle()).fixedSize()
    if let undoStatus { Text(undoStatus).font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true) }
  }
}


struct UninstallView: View {
  @Environment(AppModel.self) private var model
  var close: () -> Void
  @State private var restore = true
  @State private var deleteKeys = false
  @State private var busy = false
  @State private var status: String?

  var body: some View {
    FitOrScroll {
    VStack(alignment: .leading, spacing: 16) {
      Text("Uninstall keydillo").font(.system(size: 20, weight: .semibold))
      Text("Apps that use keydillo placeholders will stop working once keydillo is gone.")
        .font(.system(size: 14)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
      Toggle("Put the real keys back into my .env files first", isOn: $restore).toggleStyle(.checkbox)
      Toggle("Delete my keys from the Keychain", isOn: $deleteKeys).toggleStyle(.checkbox)
      Text("Also removes keydillo from Claude Code, Cursor, Codex and Pi, and stops it starting at login. keydillo then moves to the Trash.")
        .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
      if let status { Text(status).font(.system(size: 12)).foregroundStyle(Theme.danger) }
      HStack {
        Spacer()
        Button("Cancel", action: close).buttonStyle(SecondaryButtonStyle())
        Button(busy ? "Uninstalling…" : "Uninstall") {
          busy = true
          Task {
            if let err = await model.uninstall(restoreEnvFiles: restore, deleteKeys: deleteKeys) { status = err; busy = false; return }
            NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _, _ in exit(0) }
          }
        }
        .buttonStyle(PrimaryButtonStyle()).disabled(busy)
      }
    }
    .padding(24).frame(width: 440)
    }
    .background(Theme.background).foregroundStyle(Theme.text)
  }
}
