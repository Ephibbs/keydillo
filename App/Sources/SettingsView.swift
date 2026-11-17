import SwiftUI

struct SettingsView: View {
  @Environment(AppModel.self) private var model
  @State private var approval: DefaultApproval = AppModel.shared.defaultApproval
  @State private var loginItem = AppModel.shared.openAtLogin
  @State private var connectStatus: String?
  @State private var undoStatus: String?
  @State private var showUninstall = false


  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Settings").font(.system(size: 20, weight: .semibold))
      VStack(alignment: .leading, spacing: 8) {
        Text("Ask for Touch ID (new keys)").font(.system(size: 13, weight: .medium))
        PillPicker(options: DefaultApproval.allCases.map { ($0, $0.label) }, selection: $approval)
          .onChange(of: approval) { _, v in model.defaultApproval = v }
      }
      VStack(alignment: .leading, spacing: 8) {
        Text("Touch ID for projects").font(.system(size: 13, weight: .medium))
        Picker("", selection: Binding(get: { model.projectAccessDefault }, set: { v in Task { await model.setDefaultAccess(v) } })) {
          ForEach(ProjectAccess.allCases) { Text($0.label).tag($0) }
        }
        .labelsHidden().fixedSize()
        Text("\"Don't ask again\" covers any program in the project's folder, not just Claude. Applies to projects without their own setting; change one project on its page.").font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
      }
      VStack(alignment: .leading, spacing: 4) {
        Text("Terminal").font(.system(size: 13, weight: .medium))
        Text("Put kd in front of commands that use your keys, e.g. kd npm run dev. Claude does it for you.")
          .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
      }
      Toggle("Keep keydillo running (start at login, restart if it stops)", isOn: $loginItem).toggleStyle(.switch)
        .onChange(of: loginItem) { _, v in model.openAtLogin = v }
      VStack(alignment: .leading, spacing: 8) {
        Text(".env files").font(.system(size: 13, weight: .medium))
        HStack {
          Button("Import keys…") { WindowManager.shared.showImport() }.buttonStyle(SmallButtonStyle())
          Button("Undo last import") { Task { undoStatus = await ImportModel.undoLast(model: model) } }.buttonStyle(SmallButtonStyle())
          if let undoStatus { Text(undoStatus).font(.system(size: 12)).foregroundStyle(Theme.secondary) }
        }
      }
      VStack(alignment: .leading, spacing: 8) {
        Text("Claude Code").font(.system(size: 13, weight: .medium))
        HStack {
          Button("Connect again") {
            Task { connectStatus = await ClaudeConnector.connect() ?? "Connected." }
          }.buttonStyle(SmallButtonStyle())
          if let connectStatus { Text(connectStatus).font(.system(size: 12)).foregroundStyle(Theme.secondary) }
        }
      }
      VStack(alignment: .leading, spacing: 8) {
        Button("Uninstall keydillo…") { showUninstall = true }.buttonStyle(SmallButtonStyle(destructive: true))
      }
      VStack(alignment: .leading, spacing: 4) {
        Text("Proxy: localhost:\(String(model.port))").font(.system(size: 13))
        Text("Storage: \(model.storageDescription)").font(.system(size: 12)).foregroundStyle(Theme.secondary)
      }
    }
    .padding(24).frame(width: 460, alignment: .leading).background(Theme.background).foregroundStyle(Theme.text)
    .sheet(isPresented: $showUninstall) { UninstallView { showUninstall = false } }
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
    VStack(alignment: .leading, spacing: 16) {
      Text("Uninstall keydillo").font(.system(size: 20, weight: .semibold))
      Text("Apps that use keydillo placeholders will stop working once keydillo is gone.")
        .font(.system(size: 14)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
      Toggle("Put the real keys back into my .env files first", isOn: $restore).toggleStyle(.checkbox)
      Toggle("Delete my keys from the Keychain", isOn: $deleteKeys).toggleStyle(.checkbox)
      Text("Also removes keydillo from Claude Code and stops it starting at login. keydillo then moves to the Trash.")
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
    .padding(24).frame(width: 440).background(Theme.background).foregroundStyle(Theme.text)
  }
}
