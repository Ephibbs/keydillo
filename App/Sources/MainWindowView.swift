import SwiftUI
import AppKit
import VaultCore

struct MainWindowView: View {
  @Environment(AppModel.self) private var model
  @State private var project: String? = nil   // nil = all keys
  @State private var selected: String?
  @State private var showActivity = false
  @State private var showAccess = false
  @State private var newProject = ""
  @State private var addingProject = false
  @State private var search = ""
  @AppStorage("listWidth") private var listWidth: Double = 330
  @State private var dragStart: Double?

  var keys: [ServiceConfig] {
    let q = search.trimmingCharacters(in: .whitespaces).lowercased()
    return model.services
      .filter { project == nil || $0.project == project }
      .filter { q.isEmpty || [$0.displayName, $0.name, $0.project, $0.upstreamHost, $0.envVarName].contains { $0.lowercased().contains(q) } }
      .sorted {
        if $0.displayName.caseInsensitiveCompare($1.displayName) != .orderedSame {
          return $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
        }
        return $0.project.localizedCaseInsensitiveCompare($1.project) == .orderedAscending
      }
  }

  var selectedName: String? { selected.flatMap { n in keys.contains { $0.name == n } ? n : nil } ?? keys.first?.name }

  var body: some View {
    HStack(spacing: 0) {
      sidebar
      Divider().overlay(Theme.hairline)
      if showAccess {
        AccessView().frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if showActivity {
        ActivityView().frame(maxWidth: .infinity, maxHeight: .infinity)
      } else {
        keyList.frame(width: listWidth)
        divider
        detail
      }
    }
    .frame(minWidth: 860, minHeight: 560)
    .onReceive(NotificationCenter.default.publisher(for: .showAccess)) { _ in showAccess = true; showActivity = false }
    // Marks where the draggable title bar ends.
    .overlay(alignment: .top) { Rectangle().fill(Theme.hairline).frame(height: 1).allowsHitTesting(false) }
    .background(Theme.background)
    .foregroundStyle(Theme.text)
  }

  var accessCount: Int { Set(model.activeGrants.map { $0.client?.sessionKey ?? "" }).count + model.openProjects.count }

  // MARK: Sidebar

  var sidebar: some View {
    VStack(alignment: .leading, spacing: 18) {
      Text("keydillo").font(.system(size: 17, weight: .semibold)).padding(.horizontal, 8).padding(.top, 34)
      sideRow("All keys", count: "\(model.services.count)", isOn: project == nil && !showActivity && !showAccess) { project = nil; showActivity = false; showAccess = false }
      VStack(alignment: .leading, spacing: 2) {
        sectionLabel("Projects")
        ForEach(model.projects, id: \.self) { p in
          sideRow(model.unlocks.valid(p) != nil && model.openProjects.contains(where: { $0.project == p }) ? "\(p)  ·  open" : p, count: "\(model.services.filter { $0.project == p }.count)", isOn: project == p && !showActivity && !showAccess) {
            project = p; showActivity = false; showAccess = false
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
        sideRow("Access", count: accessCount == 0 ? "" : "\(accessCount)", isOn: showAccess) { showAccess = true; showActivity = false }
        sideRow("Activity", count: "\(todayCount) today", isOn: showActivity) { showActivity = true; showAccess = false }
        sideRow("Settings", count: "", isOn: false) { WindowManager.shared.showSettings() }
      }
      Spacer()
      HStack(spacing: 7) {
        StatusDot(on: model.proxyRunning)
        Text(model.proxyRunning ? "localhost:\(String(model.port))" : "Proxy \(model.proxyState)")
          .font(.system(size: 13)).foregroundStyle(Theme.tertiary).lineLimit(1)
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
      HStack { Text(title).lineLimit(1); Spacer(); Text(count).foregroundStyle(Theme.secondary) }
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
      HStack(spacing: 6) {
        Text(project ?? "All keys").font(.system(size: 22, weight: .semibold))
          .lineLimit(1).truncationMode(.tail).layoutPriority(1)
        Spacer(minLength: 4)
        if let project {
          if let folder = model.folder(for: project) {
            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder)]) } label: {
              Image(systemName: "folder").font(.system(size: 13)).frame(width: 30, height: 30).overlay(Circle().strokeBorder(Theme.border))
            }
            .buttonStyle(.plain).help("Show \(project) in Finder").accessibilityLabel("Show \(project) in Finder")
            .disabled(!FileManager.default.fileExists(atPath: folder))
          }
          Button("Readout") { Task { await openReadout(project) } }.buttonStyle(SmallButtonStyle())
        }
        Button("Add key") { WindowManager.shared.showAddKey(project: project) }.buttonStyle(SmallPrimaryStyle())
      }
      .padding(.horizontal, 16).padding(.top, 34).padding(.bottom, 10)

      if let project {
        trustRow(project).padding(.horizontal, 16).padding(.bottom, 10)
      }

      HStack(spacing: 6) {
        Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Theme.secondary)
        TextField("Search keys", text: $search).textFieldStyle(.plain).font(.system(size: 13))
        if !search.isEmpty {
          Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Theme.secondary) }
            .buttonStyle(.plain).accessibilityLabel("Clear search")
        }
      }
      .padding(.horizontal, 10).frame(height: 30)
      .background(RoundedRectangle(cornerRadius: 10).fill(Theme.fill))
      .padding(.horizontal, 16).padding(.bottom, 10)

      if keys.isEmpty {
        VStack(alignment: .leading, spacing: 6) {
          Text(search.isEmpty ? "No keys yet" : "No matches").font(.system(size: 14, weight: .medium))
          if search.isEmpty {
            Text("Add one here, or let Claude ask for one when it needs it.").font(.system(size: 13)).foregroundStyle(Theme.secondary)
          }
        }
        .padding(.horizontal, 16)
      }
      ScrollView {
        LazyVStack(spacing: 2) {
          ForEach(keys) { s in
            let isSel = selectedName == s.name
            Button { selected = s.name } label: {
              HStack(spacing: 12) {
                ServiceBadge(service: s.name, name: s.displayName, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                  Text(s.displayName).font(.system(size: 14, weight: .medium)).lineLimit(1)
                  if let sub = subtitle(s) {
                    Text(sub).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
                  }
                }
                Spacer(minLength: 0)
              }
              .padding(.horizontal, 10).padding(.vertical, 7)
              .background(RoundedRectangle(cornerRadius: 12).fill(isSel ? Theme.selected : .clear))
              .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
          }
        }
        .padding(.horizontal, 8)
      }
    }
  }

  @State private var confirmAlways: String?

  func chooseFolder(_ project: String) {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = false
    panel.message = "Choose \(project)'s folder"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task { folderError = await model.setFolder(url.path, for: project) }
  }
  @State private var folderError: String?

  @ViewBuilder func trustRow(_ project: String) -> some View {
    let folder = model.folder(for: project)
    let access = model.access(for: project)
    let override = model.accessOverride(for: project)
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 8) {
        Text("Ask for Touch ID").font(.system(size: 12)).foregroundStyle(Theme.secondary)
        Menu {
          Button("Default (\(model.projectAccessDefault.label))") { Task { await model.setAccess(project, nil) } }
          Divider()
          ForEach(ProjectAccess.allCases) { a in
            Button(a == .always && folder == nil ? a.label + " (needs a project folder)" : a.label) {
              if a == .always { confirmAlways = project } else { Task { await model.setAccess(project, a) } }
            }
            .disabled(a == .always && folder == nil)
          }
        } label: { Text(override == nil ? "Default (\(access.label))" : access.label).font(.system(size: 12, weight: .medium)) }
          .menuStyle(.borderlessButton).fixedSize()
        if folder == nil {
          Button("Set folder…") { chooseFolder(project) }.buttonStyle(.plain).font(.system(size: 12)).underline()
        }
      }
      Text(folder == nil ? (access == .always ? "Set a folder to use this." : "Programs ask \(access.label.lowercased()) before using these keys. \"Ask once per project\" needs a project folder.")
           : access != .always ? "Programs ask \(access.label.lowercased()) before using these keys."
           : "Note: Any program in \((folder! as NSString).abbreviatingWithTildeInPath) can use these keys until keydillo quits, even when your Mac is locked.")
        .font(.system(size: 11)).foregroundStyle(access == .always ? Theme.danger : Theme.secondary).fixedSize(horizontal: false, vertical: true)
      if let folderError { Text(folderError).font(.system(size: 11)).foregroundStyle(Theme.danger) }
    }
    .sheet(isPresented: Binding(get: { confirmAlways == project }, set: { if !$0 { confirmAlways = nil } })) {
      VStack(alignment: .leading, spacing: 14) {
        Text("Ask once for \(project)?").font(.system(size: 17, weight: .semibold))
        Text("Note: Any program in \(folder.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "the folder") can use its keys until keydillo quits, even when your Mac is locked.")
          .font(.system(size: 13)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
        HStack {
          Spacer()
          Button("Cancel") { confirmAlways = nil }.buttonStyle(SecondaryButtonStyle()).keyboardShortcut(.cancelAction)
          Button("Continue with Touch ID") { confirmAlways = nil; Task { await model.setAccess(project, .always) } }
            .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
        }
      }
      .padding(24).frame(width: 400).background(Theme.background).foregroundStyle(Theme.text)
    }
  }

  /// "notes-app · used 2 min ago by claude"; nothing for unused keys inside a project.
  func subtitle(_ s: ServiceConfig) -> String? {
    var parts: [String] = []
    if project == nil { parts.append(s.project) }
    if !s.isProxyReady { parts.append("needs setup") }
    if model.rejected.contains(s.name) { parts.append("rejected by \(s.displayName)") }
    if let e = model.events.first(where: { $0.service == s.name && $0.outcome == .sent }) {
      parts.append("used \(e.date.formatted(.relative(presentation: .named)))")
    }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  func openReadout(_ project: String) async {
    guard let values = await model.readout(project: project) else { return }
    WindowManager.shared.showReadout(project: project, values: values.map { ($0.0.envVarName, $0.1) })
  }

  // MARK: Detail

  @ViewBuilder var detail: some View {
    if let name = selectedName, let s = model.service(named: name) {
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
  @State private var copiedNote: String?
  @State private var editing = false
  @State private var authenticating = false

  init(config: ServiceConfig) {
    _config = State(initialValue: config)
    _pathsText = State(initialValue: Self.pathsString(config))
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


  var summary: ServiceSummary { model.summary(config) }

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      header
      if model.rejected.contains(config.name) {
        HStack(spacing: 10) {
          Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.danger)
          Text("\(config.displayName) rejected this key the last time it was used. It may have been revoked.")
            .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
          Spacer(minLength: 8)
          Button("Rotate") { rotate() }.buttonStyle(SmallPrimaryStyle())
        }
        .padding(12).background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
      }
      keyRow
      fields
      Collapsible(title: "Advanced", isOpen: $advancedOpen) { advanced }
      recentUse
      if let error { Text(error).font(.system(size: 12)).foregroundStyle(Theme.danger) }
    }
    .padding(.horizontal, 26).padding(.top, 34).padding(.bottom, 22)
    .alert("Delete the \(config.displayName) key?", isPresented: $confirmDelete) {
      Button("Delete", role: .destructive) { model.delete(config.name) }
      Button("Cancel", role: .cancel) {}
    } message: { Text("It's removed from your Keychain. Anything using it will stop working.") }
  }

  var header: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(alignment: .center, spacing: 12) {
        ServiceBadge(service: config.name, name: config.displayName, size: 40)
        Text(config.displayName).font(.system(size: 19, weight: .semibold)).lineLimit(1)
        Spacer(minLength: 8)
        Menu {
          Button("Rotate…") { rotate() }
          Divider()
          Button("Delete key…", role: .destructive) { confirmDelete = true }
        } label: { Image(systemName: "ellipsis").frame(width: 28, height: 28) }
          .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel("More")
      }
      HStack(spacing: 8) {
        Text(summary.baseURL).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.secondary)
          .lineLimit(1).truncationMode(.middle).textSelection(.enabled).layoutPriority(1)
        Button { copy(summary.baseURL, "Address copied") } label: { Image(systemName: "doc.on.doc").font(.system(size: 11)) }
          .buttonStyle(.plain).foregroundStyle(Theme.secondary).help("Copy address").accessibilityLabel("Copy address")
        Spacer(minLength: 8)
        if let copiedNote { Text(copiedNote).font(.system(size: 11)).foregroundStyle(Theme.secondary).lineLimit(1) }
        Button("Copy .env lines") { copy(summary.placeholderEnvLines.joined(separator: "\n"), "Copied, no secret in them") }
          .buttonStyle(SmallButtonStyle()).help(summary.placeholderEnvLines.joined(separator: "\n")).fixedSize()
      }
    }
  }

  var keyRow: some View {
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
    // Hide when the user leaves the window, but not because the Touch ID sheet took focus.
    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in if !authenticating { hide() } }
  }

  var fields: some View {
    VStack(alignment: .leading, spacing: 12) {
      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
        row(config.isLaunchTime ? "How it's used" : "Sent only to") {
          if config.isLaunchTime {
            Text("Given to the app when it starts with kd. The running program can see it, so a command that prints its environment could reveal it.")
              .font(.system(size: 12)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
          } else if editing {
            FilledField(placeholder: "api.example.com", text: $config.upstreamHost, monospaced: true)
          } else {
            VStack(alignment: .leading, spacing: 6) {
              HStack(spacing: 6) {
                Image(systemName: "lock.fill").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                Text(config.upstreamHost.isEmpty ? "Set the first time it's used (you approve the site with Touch ID)" : config.upstreamHost)
                  .font(.system(size: 13, design: config.upstreamHost.isEmpty ? .default : .monospaced))
                  .foregroundStyle(config.upstreamHost.isEmpty ? Theme.secondary : Theme.text)
              }
              if let extra = config.extraHosts, !extra.isEmpty {
                DisclosureGroup("Also sent to \(extra.count) other site\(extra.count == 1 ? "" : "s")") {
                  VStack(alignment: .leading, spacing: 4) {
                    ForEach(extra, id: \.self) { h in
                      HStack(spacing: 8) {
                        Text(h).font(.system(size: 12, design: .monospaced))
                        Button("Remove") { model.removeHost(h, from: config.name); config.extraHosts = model.service(named: config.name)?.extraHosts }
                          .buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(Theme.danger)
                      }
                    }
                  }
                  .padding(.top, 4)
                }
                .font(.system(size: 12)).foregroundStyle(Theme.secondary)
              }
            }
          }
        }
        row("Auth header") {
          if editing { FilledField(placeholder: "Authorization", text: $config.authHeader, monospaced: true) }
          else { Text(config.authHeader.isEmpty ? "Not set" : config.authPrefix + config.authHeader).font(.system(size: 13, design: .monospaced)) }
        }
        row("Project") {
          if editing { FilledField(placeholder: "Personal", text: $config.project) } else { Text(config.project).font(.system(size: 13)) }
        }
        row("Env name") {
          if editing { FilledField(placeholder: "EXAMPLE_API_KEY", text: $config.envVarName, monospaced: true) }
          else { Text(config.envVarName).font(.system(size: 13, design: .monospaced)).textSelection(.enabled) }
        }
        row("Key page") {
          if editing {
            FilledField(placeholder: "Where you manage this key (for Rotate)", text: Binding(get: { config.keyPageURL ?? "" }, set: { config.keyPageURL = $0.isEmpty ? nil : $0 }))
          } else if let page = config.keyPageURL, let url = URL(string: page) {
            Link(url.host ?? page, destination: url).font(.system(size: 13))
          } else {
            Text("Not set").font(.system(size: 13)).foregroundStyle(Theme.secondary)
          }
        }
      }
      .font(.system(size: 14))
      HStack(spacing: 8) {
        if editing {
          Button("Cancel") { discard() }.buttonStyle(SmallButtonStyle())
          Button("Save") { Task { await saveChanges() } }.buttonStyle(SmallPrimaryStyle()).disabled(!dirty)
          Text("Changing where the key is sent needs Touch ID.").font(.system(size: 11)).foregroundStyle(Theme.secondary)
        } else {
          Button("Edit") { editing = true }.buttonStyle(SmallButtonStyle())
          if dirty { Button("Save") { Task { await saveChanges() } }.buttonStyle(SmallPrimaryStyle()) }
        }
      }
    }
  }

  var advanced: some View {
    Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 10) {
      row("Allowed paths") { FilledField(placeholder: "Any path. Example: POST /v1/text-to-speech/*", text: $pathsText, monospaced: true) }
      row("Rate limit") {
        HStack { FilledField(placeholder: "No limit", text: $rateText).frame(width: 110); Text("per hour").foregroundStyle(Theme.secondary) }
      }
      row("Placeholder") {
        Toggle("Allow anywhere in a request (path, body, other headers)", isOn: Binding(get: { config.placeholderAnywhere == true }, set: { config.placeholderAnywhere = $0 ? true : nil }))
          .toggleStyle(.checkbox).font(.system(size: 12))
          .help("Off is safer: the key only goes in its auth spot. Turn on only for APIs that need the key elsewhere (OAuth bodies, bot tokens in URLs). The site could then echo or store the key.")
      }
      row("Key in URL") {
        FilledField(placeholder: "Query parameter, e.g. key (leave empty to use the header)",
                    text: Binding(get: { config.authQueryParam ?? "" }, set: { config.authQueryParam = $0.isEmpty ? nil : $0 }), monospaced: true)
      }
    }
    .font(.system(size: 14))
  }

  @ViewBuilder var recentUse: some View {
    let recent = model.events.filter { $0.service == config.name }.prefix(6)
    if !recent.isEmpty {
      VStack(alignment: .leading, spacing: 8) {
        Text("Recent use").font(.system(size: 12)).foregroundStyle(Theme.secondary)
        VStack(spacing: 0) {
          ForEach(Array(recent)) { e in
            HStack {
              Text(e.date, format: .dateTime.hour().minute()).foregroundStyle(Theme.secondary).frame(width: 64, alignment: .leading)
              Text(e.process).frame(width: 120, alignment: .leading).lineLimit(1)
              Text(e.note ?? "\(e.method) \(e.path)").font(.system(size: 12, design: .monospaced)).lineLimit(1).truncationMode(.middle)
              Spacer()
              Text(e.outcome == .sent ? (e.status == 0 ? "" : "\(e.status)") : e.outcome.rawValue.capitalized)
                .foregroundStyle(e.outcome == .sent ? Theme.text : Theme.danger)
            }
            .font(.system(size: 13)).padding(.horizontal, 14).frame(height: 38)
            if e.id != recent.last?.id { Divider().overlay(Theme.hairline) }
          }
        }
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.hairline))
      }
    }
  }

  func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
    GridRow {
      Text(label).foregroundStyle(Theme.secondary).lineLimit(1).frame(width: 100, alignment: .leading)
      content().frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  func copy(_ text: String, _ note: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    copiedNote = note
    Task { try? await Task.sleep(for: .seconds(2)); copiedNote = nil }
  }

  func rotate() {
    if let page = AppModel.safeKeyPage(config.keyPageURL), let url = URL(string: page) {
      let alert = NSAlert()
      alert.messageText = "Open \(url.host ?? page)?"
      alert.informativeText = "keydillo will open \(page) so you can make a new key, then show the window to paste it."
      alert.addButton(withTitle: "Open"); alert.addButton(withTitle: "Just paste a new key")
      if alert.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(url) }
    }
    WindowManager.shared.showReplaceKey(config)
  }

  func reveal() async {
    authenticating = true
    let v = await model.reveal(config)
    // Touch ID hands focus to another app; authenticate() brings this window back. Keep ignoring the focus change
    // for a moment so the key isn't hidden as the window becomes key again.
    try? await Task.sleep(nanoseconds: 500_000_000)
    authenticating = false
    guard let v else { return }
    revealed = v; copied = false
    try? await Task.sleep(for: .seconds(30))
    if revealed == v { hide() }
  }

  func hide() { revealed = nil; copied = false }

  func discard() {
    if let o = original { config = o; pathsText = Self.pathsString(o); rateText = o.maxRequestsPerHour.map(String.init) ?? "" }
    editing = false; error = nil
  }

  func saveChanges() async {
    do { if try await model.update(edited) { error = nil; editing = false } }
    catch { self.error = error.localizedDescription }
  }

  static func pathsString(_ c: ServiceConfig) -> String { c.allowed.map { "\($0.method) \($0.pattern)" }.joined(separator: "   ") }

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

extension Notification.Name { static let showAccess = Notification.Name("keydillo.showAccess") }
