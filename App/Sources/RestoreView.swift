import SwiftUI
import VaultCore

/// "Put my real keys back": the way to stop using keydillo for one project or everything. Needs Touch ID.
struct RestoreView: View {
  @Environment(AppModel.self) private var model
  @State private var status: String?
  @State private var busy = false

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Put your real keys back").font(.system(size: 20, weight: .semibold))
        Text("Writes the real values back into your .env files in place of keydillo's placeholders, so your apps work without kd. Programs, including AI tools, can read them again. Your keys stay in keydillo too.")
          .font(.system(size: 13)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
      }
      VStack(spacing: 0) {
        ForEach(model.projects, id: \.self) { p in
          HStack {
            Text(p).font(.system(size: 13, weight: .medium))
            Spacer()
            Button("Put back") { run(p) }.buttonStyle(SmallButtonStyle()).disabled(busy)
          }
          .padding(.horizontal, 12).padding(.vertical, 8)
          if p != model.projects.last { Divider().overlay(Theme.hairline) }
        }
      }
      .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
      if let status { Text(status).font(.system(size: 12)).foregroundStyle(Theme.secondary) }
      HStack {
        Spacer()
        Button("Close") { WindowManager.shared.close("restore") }.buttonStyle(SecondaryButtonStyle())
        Button("Put all keys back") { run(nil) }.buttonStyle(PrimaryButtonStyle()).disabled(busy)
      }
    }
  }

  func run(_ project: String?) {
    busy = true
    Task { status = await ImportModel.restoreRealValues(model: model, project: project); busy = false }
  }
}
