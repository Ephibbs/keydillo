import SwiftUI
import VaultCore

struct MainWindowView: View {
  @Environment(AppModel.self) private var model
  @State private var project: String? = nil   // nil = all keys
  @State private var selected: String?
  @State private var showActivity = false
  @State private var newProject = ""
  @State private var addingProject = false
  @AppStorage("listWidth") private var listWidth: Double = 330
  @State private var dragStart: Double?

  var keys: [ServiceConfig] {
    model.services.filter { project == nil || $0.project == project }
      .sorted {
        let a = ($0.displayName, $0.project), b = ($1.displayName, $1.project)
        if a.0.caseInsensitiveCompare(b.0) != .orderedSame { return a.0.localizedCaseInsensitiveCompare(b.0) == .orderedAscending }
        return a.1.localizedCaseInsensitiveCompare(b.1) == .orderedAscending
      }
  }

  var body: some View {
    HStack(spacing: 0) {
      sidebar
      Divider().overlay(Theme.hairline)
      if showActivity {
        ActivityView().frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        keyList.frame(width: listWidth)
        divider
        detail
      }
    }
    .frame(minWidth: 860, minHeight: 560)
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

  /// Drag to resize the key list; the width is remembered.
  var divider: some View {
    Rectangle().fill(Theme.hairline).frame(width: 1)
      .overlay(Rectangle().fill(Color.clear).frame(width: 9).contentShape(Rectangle())
        .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
        .gesture(DragGesture(minimumDistance: 1)
          .onChanged { v in
            if dragStart == nil { dragStart = listWidth }
            listWidth = min(520, max(240, (dragStart ?? listWidth) + v.translation.width))
          }
          .onEnded { _ in dragStart = nil }))
  }

  // MARK: Key list

  var keyList: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack {
        Text(project ?? "All keys").font(.system(size: 22, weight: .semibold))
          .lineLimit(1).truncationMode(.tail).layoutPriority(1)
        Spacer()
        if let project {
          if let folder = model.folder(for: project) {
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)]) } label: {
              Image(systemName: "folder").font(.system(size: 13)).frame(width: 32, height: 32)
                .overlay(Circle().strokeBorder(Theme.border))
            }
            .buttonStyle(.plain).help("Show \(project) in Finder").accessibilityLabel("Show \(project) in Finder")
            .disabled(!FileManager.default.fileExists(atPath: folder))
          }
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
                  Text(project == nil ? "\(s.project) · \(lastUse(s))" : lastUse(s))
                    .font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
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
      ScrollView { KeyDetailView(config: s).id(s.name) }
        .frame(minWidth: 380, maxWidth: .infinity, maxHeight: .infinity)
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
  @State private var revealed: String?
  @State private var advancedOpen = false
  @State private var copied = false

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

      HStack(spacing: 8) {
        Text(revealed ?? String(repeating: "•", count: 24))
          .font(.system(size: 12.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
          .textSelection(.enabled)
          .foregroundStyle(revealed == nil ? Theme.secondary : Theme.text)
          .padding(.horizontal, 12).frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
          .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
        if let revealed {
          Button(copied ? "Copied" : "Copy") { model.copyConcealed(revealed); copied = true }.buttonStyle(SmallButtonStyle())
            .help("Clears from the clipboard after 30 s")
          Button { hide() } label: { Image(systemName: "eye.slash") }.buttonStyle(SmallButtonStyle()).accessibilityLabel("Hide key")
        } else {
          Button { Task { await reveal() } } label: { Label("Show", systemImage: "eye") }.buttonStyle(SmallButtonStyle())
            .help("Shows the key after Touch ID. Hides again after 30 s.")
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in hide() }

      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
        field("Auth header") { FilledField(placeholder: "Authorization", text: $config.authHeader, monospaced: true) }
        field("Allowed host") { FilledField(placeholder: "api.example.com", text: $config.upstreamHost, monospaced: true) }
        field("Approval") {
          ViewThatFits(in: .horizontal) {
            PillPicker(options: DefaultApproval.allCases.map { ($0, $0.label) }, selection: approvalBinding)
            Picker("", selection: approvalBinding) { ForEach(DefaultApproval.allCases, id: \.self) { Text($0.label).tag($0) } }
              .labelsHidden().fixedSize()
          }
        }
        field("Project") { FilledField(placeholder: "Personal", text: $config.project) }
        field("Env var name") { FilledField(placeholder: "EXAMPLE_API_KEY", text: $config.envVarName, monospaced: true) }
        field("Key page") { FilledField(placeholder: "Where you manage this key (for Rotate)", text: Binding(get: { config.keyPageURL ?? "" }, set: { config.keyPageURL = $0.isEmpty ? nil : $0 })) }
      }
      .font(.system(size: 14))

      Collapsible(title: "Advanced", isOpen: $advancedOpen) {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
          field("Allowed paths") { FilledField(placeholder: "Any path. Example: POST /v1/text-to-speech/*", text: $pathsText, monospaced: true) }
          field("Rate limit") {
            HStack { FilledField(placeholder: "No limit", text: $rateText).frame(width: 110); Text("per hour").foregroundStyle(Theme.secondary) }
          }
        }
        .font(.system(size: 14))
      }

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
        Button("Rotate") {
          if let page = config.keyPageURL, let url = URL(string: page) { NSWorkspace.shared.open(url) }
          WindowManager.shared.showReplaceKey(config)
        }
        .buttonStyle(SmallButtonStyle())
        .help(config.keyPageURL == nil ? "Paste a new key" : "Opens the provider's key page, then paste the new key")
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
    GridRow { Text(label).foregroundStyle(Theme.secondary).lineLimit(1).frame(width: 100, alignment: .leading); content().frame(maxWidth: .infinity, alignment: .leading) }
  }

  func reveal() async {
    guard let v = await model.reveal(config) else { return }
    revealed = v; copied = false
    try? await Task.sleep(for: .seconds(30))
    if revealed == v { hide() }
  }

  func hide() { revealed = nil; copied = false }

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
