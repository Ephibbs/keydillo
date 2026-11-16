import SwiftUI
import VaultCore

struct AddKeyView: View {
  @Environment(AppModel.self) private var model
  @Environment(\.dismissWindow) private var dismissWindow
  @State private var name = "elevenlabs"
  @State private var displayName = "ElevenLabs"
  @State private var project = "Personal"
  @State private var host = "api.elevenlabs.io"
  @State private var header = "xi-api-key"
  @State private var prefix = ""
  @State private var secret = ""
  @State private var approval = 0
  @State private var error: String?

  var body: some View {
    Form {
      Section {
        TextField("Name in URL", text: $name)
        TextField("Display name", text: $displayName)
        TextField("Project", text: $project)
      }
      Section {
        TextField("Host", text: $host).font(.body.monospaced())
        TextField("Header", text: $header).font(.body.monospaced())
        TextField("Value prefix (e.g. \"Bearer \")", text: $prefix).font(.body.monospaced())
      } footer: {
        Text("Your key is sent only to https://\(host.isEmpty ? "…" : host).").font(.caption)
      }
      Section {
        SecureField("Paste your key", text: $secret)
        Picker("Approval", selection: $approval) {
          Text("Each request").tag(0)
          Text("Per process").tag(1)
          Text("15 min window").tag(2)
        }
        .pickerStyle(.segmented)
      }
      if let error { Text(error).foregroundStyle(.red).font(.callout) }
      HStack {
        Spacer()
        Button("Cancel") { dismissWindow(id: "add-key") }
        Button("Save to Keychain") { save() }.keyboardShortcut(.defaultAction)
      }
    }
    .formStyle(.grouped)
    .frame(width: 440)
  }

  func save() {
    let mode: ApprovalMode = approval == 0 ? .eachRequest : approval == 1 ? .perProcess : .window(minutes: 15)
    let cfg = ServiceConfig(name: name.lowercased(), displayName: displayName, project: project, upstreamHost: host,
                            authHeader: header, authPrefix: prefix, approval: mode)
    do {
      try model.add(cfg, secret: secret)
      secret = ""
      error = nil
      dismissWindow(id: "add-key")
    } catch {
      self.error = error.localizedDescription
    }
  }
}
