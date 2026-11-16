import SwiftUI

struct SettingsView: View {
  @Environment(AppModel.self) private var model
  @State private var approval: DefaultApproval = AppModel.shared.defaultApproval
  @State private var loginItem = AppModel.shared.openAtLogin
  @State private var connectStatus: String?
  @State private var undoStatus: String?

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("Settings").font(.system(size: 20, weight: .semibold))
      VStack(alignment: .leading, spacing: 8) {
        Text("Ask for Touch ID (new keys)").font(.system(size: 13, weight: .medium))
        PillPicker(options: DefaultApproval.allCases.map { ($0, $0.label) }, selection: $approval)
          .onChange(of: approval) { _, v in model.defaultApproval = v }
      }
      Toggle("Keep keydillo running (start at login, restart if it stops)", isOn: $loginItem).toggleStyle(.switch)
        .onChange(of: loginItem) { _, v in model.openAtLogin = v }
      VStack(alignment: .leading, spacing: 8) {
        Text(".env files").font(.system(size: 13, weight: .medium))
        HStack {
          Button("Import keys…") { WindowManager.shared.showImport() }.buttonStyle(SmallButtonStyle())
          Button("Undo last import") { undoStatus = ImportModel.undoLast() }.buttonStyle(SmallButtonStyle())
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
      VStack(alignment: .leading, spacing: 4) {
        Text("Proxy: localhost:\(String(model.port))").font(.system(size: 13))
        Text("Storage: \(model.storageDescription)").font(.system(size: 12)).foregroundStyle(Theme.secondary)
      }
    }
    .padding(24).frame(width: 460, alignment: .leading).background(Theme.background).foregroundStyle(Theme.text)
  }
}
