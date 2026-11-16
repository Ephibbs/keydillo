import SwiftUI
import VaultCore

struct MainWindowView: View {
  @Environment(AppModel.self) private var model
  @State private var project: String? = nil   // nil = all keys
  @State private var selected: String?
  @State private var showActivity = false
  @State private var newProject = ""
  @State private var addingProject = false

  var keys: [ServiceConfig] {
    model.services.filter { project == nil || $0.project == project }
      .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
  }

  var body: some View {
    HStack(spacing: 0) {
      sidebar
      Divider().overlay(Theme.hairline)
      if showActivity {
        ActivityView().frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        keyList
        Divider().overlay(Theme.hairline)
        detail
      }
    }
    .frame(minWidth: 980, minHeight: 600)
    .background(Theme.background)
    .foregroundStyle(Theme.text)
  }

  // MARK: Sidebar

  var sidebar: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("keydillo").font(.system(size: 17, weight: .semibold)).padding(.horizontal, 8).padding(.top, 34)
      VStack(alignment: .leading, spacing: 2) {
        sectionLabel("Projects")
        sideRow("All keys", count: "\(model.services.count)", isOn: project == nil && !showActivity) { project = nil; showActivity = false; selected = nil }
        ForEach(model.projects, id: \.self) { p in
          sideRow(p, count: "\(model.services.filter { $0.project == p }.count)", isOn: project == p && !showActivity) {
            project = p; showActivity = false; selected = nil
          }
        }
        if addingProject {
          TextField("Project name", text: $newProject).textFieldStyle(.plain).font(.system(size: 14))
            .padding(8).background(RoundedRectangle(cornerRadius: 10).fill(Theme.fill))
            .onSubmit { model.addProject(newProject); project = newProject; newProject = ""; addingProject = false }
        } else {
          Button { addingProject = true } label: {
            Label("New project", systemImage: "plus").font(.system(size: 14)).padding(8)
          }.buttonStyle(.plain)
        }
      }
      VStack(alignment: .leading, spacing: 2) {
        sectionLabel("Monitor")
        sideRow("Activity", count: "\(todayCount) today", isOn: showActivity) { showActivity = true }
        sideRow("Settings", count: "", isOn: false) { WindowManager.shared.showSettings() }
      }
      Spacer()
      HStack(spacing: 7) {
        StatusDot(on: model.proxyRunning)
        Text(model.proxyRunning ? "localhost:\(String(model.port))" : "Proxy \(model.proxyState)")
          .font(.system(size: 13)).foregroundStyle(Theme.tertiary)
      }
      .padding(.horizontal, 8).padding(.bottom, 14)
    }
    .padding(.horizontal, 10)
    .frame(width: 224)
    .frame(maxHeight: .infinity, alignment: .top)
    .background(Theme.sidebar)
  }

  var todayCount: Int { model.events.filter { Calendar.current.isDateInToday($0.date) }.count }

  func sectionLabel(_ s: String) -> some View {
    Text(s).font(.system(size: 12)).foregroundStyle(Theme.secondary).padding(.horizontal, 8).padding(.bottom, 6)
  }

  func sideRow(_ title: String, count: String, isOn: Bool, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      HStack { Text(title); Spacer(); Text(count).foregroundStyle(Theme.secondary) }
        .font(.system(size: 14)).padding(8)
        .background(RoundedRectangle(cornerRadius: 10).fill(isOn ? Theme.selected : .clear))
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  // MARK: Key list

  var keyList: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(project ?? "All keys").font(.system(size: 22, weight: .semibold))
        Spacer()
        if let project {
          Button("Readout") { Task { await openReadout(project) } }.buttonStyle(SmallButtonStyle())
        }
        Button("Add key") { WindowManager.shared.showAddKey(project: project) }
          .buttonStyle(SmallPrimaryStyle())
      }
      .padding(.horizontal, 16).padding(.top, 34).padding(.bottom, 12)

      if keys.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text("No keys yet").font(.system(size: 14, weight: .medium))
          Text("Add one here, or let Claude ask for one when it needs it.").font(.system(size: 13)).foregroundStyle(Theme.secondary)
        }
        .padding(16)
      }
      ScrollView {
        VStack(spacing: 2) {
          ForEach(keys) { s in
            Button { selected = s.name } label: {
              HStack(spacing: 12) {
                ServiceBadge(name: s.displayName)
                VStack(alignment: .leading, spacing: 1) {
                  Text(s.displayName).font(.system(size: 14, weight: .medium))
                  Text(lastUse(s)).font(.system(size: 12)).foregroundStyle(Theme.secondary)
                }
                Spacer()
              }
              .padding(10)
              .background(RoundedRectangle(cornerRadius: 12).fill(selected == s.name ? Theme.fill : .clear))
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 8)
      }
    }
    .frame(width: 330)
  }

  func lastUse(_ s: ServiceConfig) -> String {
    guard let e = model.events.first(where: { $0.service == s.name && $0.outcome == .sent }) else { return "Never used" }
    return "Used \(e.date.formatted(.relative(presentation: .named))) by \(e.process)"
  }

  func openReadout(_ project: String) async {
    guard let values = await model.readout(project: project) else { return }
    WindowManager.shared.showReadout(project: project, values: values.map { ($0.0.envVarName, $0.1) })
  }

  // MARK: Detail

  @ViewBuilder var detail: some View {
    if let name = selected ?? keys.first?.name, let s = model.service(named: name) {
      KeyDetailView(config: s).id(s.name).frame(maxWidth: .infinity, maxHeight: .infinity)
    } else {
      Color.clear.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
  }
}

struct SmallPrimaryStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label.font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.onPrimary)
      .padding(.horizontal, 14).frame(height: 32)
      .background(Capsule().fill(Theme.primary.opacity(configuration.isPressed ? 0.8 : 1)))
      .contentShape(Capsule())
  }
}

struct KeyDetailView: View {
  @Environment(AppModel.self) private var model
  @State var config: ServiceConfig
  @State private var pathsText = ""
  @State private var rateText = ""
  @State private var error: String?
  @State private var confirmDelete = false

  init(config: ServiceConfig) {
    _config = State(initialValue: config)
    _pathsText = State(initialValue: config.allowed.map { "\($0.method) \($0.pattern)" }.joined(separator: "   "))
    _rateText = State(initialValue: config.maxRequestsPerHour.map(String.init) ?? "")
  }

  var original: ServiceConfig? { model.service(named: config.name) }
  var dirty: Bool { original != edited }

  var edited: ServiceConfig {
    var c = config
    c.allowed = Self.parsePaths(pathsText)
    c.maxRequestsPerHour = Int(rateText.trimmingCharacters(in: .whitespaces))
    return c
  }

  var approvalBinding: Binding<DefaultApproval> {
    Binding(get: { config.approval.asDefault }, set: { config.approval = $0.mode })
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text(config.displayName).font(.system(size: 19, weight: .semibold))
          Text(model.summary(config).baseURL).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.secondary)
            .textSelection(.enabled)
        }
        Spacer()
        Label("In Keychain", systemImage: "lock").font(.system(size: 12)).foregroundStyle(Theme.tertiary)
          .padding(.horizontal, 11).frame(height: 26).background(Capsule().fill(Theme.fill))
      }

      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
        field("Auth header") { FilledField(placeholder: "Authorization", text: $config.authHeader, monospaced: true) }
        field("Allowed host") { FilledField(placeholder: "api.example.com", text: $config.upstreamHost, monospaced: true) }
        field("Allowed paths") { FilledField(placeholder: "Any path. Example: POST /v1/text-to-speech/*", text: $pathsText, monospaced: true) }
        field("Approval") { PillPicker(options: DefaultApproval.allCases.map { ($0, $0.label) }, selection: approvalBinding) }
        field("Rate limit") {
          HStack { FilledField(placeholder: "No limit", text: $rateText).frame(width: 120); Text("requests / hour").foregroundStyle(Theme.secondary) }
        }
        field("Project") { FilledField(placeholder: "Personal", text: $config.project) }
        field("Env var name") { FilledField(placeholder: "EXAMPLE_API_KEY", text: $config.envVarName, monospaced: true) }
      }
      .font(.system(size: 14))

      VStack(alignment: .leading, spacing: 8) {
        Text("Recent use").font(.system(size: 12)).foregroundStyle(Theme.secondary)
        let recent = model.events.filter { $0.service == config.name }.prefix(6)
        if recent.isEmpty {
          Text("Nothing yet.").font(.system(size: 13)).foregroundStyle(Theme.secondary)
        } else {
          VStack(spacing: 0) {
            ForEach(Array(recent)) { e in
              HStack {
                Text(e.date, format: .dateTime.hour().minute()).foregroundStyle(Theme.secondary).frame(width: 56, alignment: .leading)
                Text(e.process).frame(width: 130, alignment: .leading).lineLimit(1)
                Text("\(e.method) \(e.path)").font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(e.outcome == .sent ? "\(e.status)" : e.outcome.rawValue.capitalized)
                  .foregroundStyle(e.outcome == .sent ? Theme.text : Theme.danger)
              }
              .font(.system(size: 13)).padding(.horizontal, 14).frame(height: 38)
              if e.id != recent.last?.id { Divider().overlay(Theme.hairline) }
            }
          }
          .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.hairline))
        }
      }

      if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger) }
      Spacer()
      HStack {
        Button("Delete key") { confirmDelete = true }.buttonStyle(SmallButtonStyle(destructive: true))
        Spacer()
        if dirty {
          Button("Discard") { if let o = original { config = o; pathsText = o.allowed.map { "\($0.method) \($0.pattern)" }.joined(separator: "   ") } }
            .buttonStyle(SmallButtonStyle())
          Button("Save changes") { Task { await saveChanges() } }.buttonStyle(SmallPrimaryStyle())
        }
      }
    }
    .padding(.horizontal, 26).padding(.top, 34).padding(.bottom, 22)
    .alert("Delete the \(config.displayName) key?", isPresented: $confirmDelete) {
      Button("Delete", role: .destructive) { model.delete(config.name) }
      Button("Cancel", role: .cancel) {}
    } message: { Text("It's removed from your Keychain. Anything using it will stop working.") }
  }

  func field<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
    GridRow { Text(label).foregroundStyle(Theme.secondary).frame(width: 110, alignment: .leading); content() }
  }

  func saveChanges() async {
    do { if try await model.update(edited) { error = nil } }
    catch { self.error = error.localizedDescription }
  }

  /// "POST /v1/tts/*   GET /v1/voices" → rules. A bare path means any method.
  static func parsePaths(_ s: String) -> [PathRule] {
    let tokens = s.split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\n" }).map(String.init)
    var rules: [PathRule] = []; var method: String?
    for t in tokens {
      if t.hasPrefix("/") { rules.append(PathRule(method: method ?? "*", pattern: t)); method = nil }
      else { method = t.uppercased() }
    }
    return rules
  }
}
