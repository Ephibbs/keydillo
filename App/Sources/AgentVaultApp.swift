import SwiftUI
import VaultCore

@main
struct AgentVaultApp: App {
  @State private var model = AppModel()

  var body: some Scene {
    MenuBarExtra {
      MenuContent().environment(model)
    } label: {
      Image(systemName: "key.horizontal")
    }
    .menuBarExtraStyle(.window)

    Window("Add key", id: "add-key") {
      AddKeyView().environment(model)
    }
    .windowResizability(.contentSize)
  }
}

struct MenuContent: View {
  @Environment(AppModel.self) private var model
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        VStack(alignment: .leading, spacing: 2) {
          Text("agent-vault").font(.headline)
          HStack(spacing: 6) {
            Circle().fill(model.proxyState == "ready" ? Color.green : Color.orange).frame(width: 7, height: 7)
            Text(model.proxyState == "ready" ? "Proxy running on localhost:\(String(model.port))" : "Proxy \(model.proxyState)")
              .font(.caption).foregroundStyle(.secondary)
          }
        }
        Spacer()
      }

      if model.services.isEmpty {
        Text("No keys yet.").font(.callout).foregroundStyle(.secondary)
      }
      ForEach(model.projects, id: \.self) { project in
        VStack(alignment: .leading, spacing: 6) {
          Text(project.uppercased()).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
          ForEach(model.services.filter { $0.project == project }) { svc in
            HStack {
              VStack(alignment: .leading, spacing: 1) {
                Text(svc.displayName).font(.callout.weight(.medium))
                Text(svc.upstreamHost).font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Button(role: .destructive) { model.delete(svc.name) } label: { Image(systemName: "trash") }
                .buttonStyle(.borderless).help("Delete key")
            }
          }
        }
      }

      if !model.events.isEmpty {
        Divider()
        Text("RECENT").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        ForEach(model.events.prefix(5)) { e in
          HStack {
            Text(e.date, style: .time).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            Text("\(e.process) → \(e.service)").font(.caption).lineLimit(1)
            Spacer()
            Text(e.outcome == .sent ? "\(e.status)" : e.outcome.rawValue.capitalized)
              .font(.caption).foregroundStyle(e.outcome == .sent ? Color.green : Color.red)
          }
        }
      }

      Divider()
      HStack {
        Button("Add key…") { openWindow(id: "add-key"); NSApp.activate() }
        Spacer()
        Button("Quit") { NSApp.terminate(nil) }
      }
      Text(model.storageDescription).font(.caption2).foregroundStyle(.secondary)
    }
    .padding(14)
    .frame(width: 340)
  }
}
