import SwiftUI
import VaultCore

/// Everything that can use keys right now without asking again, with a way to end each.
struct AccessView: View {
  @Environment(AppModel.self) private var model

  struct ProgramAccess: Identifiable {
    let id: String          // the program's session
    let name: String
    let keys: [String]
    let expires: Date?
    /// The latest reason the AI gave for using keys, if any.
    let purpose: String?
  }

  var programs: [ProgramAccess] {
    var byClient: [String: (name: String, keys: Set<String>, expires: Date?, purpose: String?)] = [:]
    for g in model.activeGrants {   // most recently used first
      let c = g.client
      let id = c?.sessionKey ?? "unknown"
      var e = byClient[id] ?? (c.map { $0.friendlyName + ($0.agent != nil && $0.name != $0.agent && $0.name != "keydillo" ? " (\($0.name))" : "") } ?? "a program", [], g.expires, nil)
      if e.purpose == nil { e.purpose = c?.purpose }
      e.keys.insert(model.service(named: g.service)?.displayName ?? g.service)
      if let x = g.expires { e.expires = max(e.expires ?? x, x) }
      byClient[id] = e
    }
    return byClient.map { ProgramAccess(id: $0.key, name: $0.value.name, keys: $0.value.keys.sorted(), expires: $0.value.expires, purpose: $0.value.purpose) }
      .sorted { $0.name < $1.name }
  }

  var body: some View {
    ScrollView(.vertical) {
    VStack(alignment: .leading, spacing: 18) {
      HStack {
        Text("Access").font(.system(size: 22, weight: .semibold))
        Spacer()
        if !programs.isEmpty || !model.openProjects.isEmpty || !model.backgroundRuns.isEmpty {
          Button("End all") { Task { await model.endAllAccess() } }.buttonStyle(SmallButtonStyle(destructive: true))
        }
      }
      Text("Programs and projects that can use keys right now without a new Touch ID prompt. Ending one makes it ask again.")
        .font(.system(size: 13)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)

      if programs.isEmpty && model.openProjects.isEmpty && model.backgroundRuns.isEmpty {
        Text("Nothing has access right now. Every key will ask before it's used.")
          .font(.system(size: 13)).foregroundStyle(Theme.secondary).padding(.top, 8)
      }
      if !programs.isEmpty {
        section("Programs") {
          ForEach(programs) { p in
            row(title: p.name, detail: (p.purpose.map { "“\($0)” · " } ?? "") + p.keys.joined(separator: ", ") + (p.expires.map { " · until \($0.formatted(date: .omitted, time: .shortened))" } ?? " · until it quits")) {
              Task { await model.endAccess(session: p.id) }
            }
          }
        }
      }
      if !model.backgroundRuns.isEmpty {
        section("Background programs started with kd") {
          ForEach(model.backgroundRuns.values.sorted { $0.pid < $1.pid }, id: \.pid) { r in
            row(title: r.programs.joined(separator: ", "),
                detail: "From kd \(r.command) in \((r.folder as NSString).abbreviatingWithTildeInPath) · until \(r.programs.count == 1 ? "it exits" : "they exit")") {
              model.endBackgroundRun(r.pid)
            }
          }
        }
      }
      if !model.openProjects.isEmpty {
        section("Projects (Ask once per project)") {
          ForEach(model.openProjects, id: \.project) { o in
            row(title: o.project, detail: "Any program in \((o.unlock.folder as NSString).abbreviatingWithTildeInPath) · until keydillo quits · keys kept in memory") {
              model.closeProject(o.project)
            }
          }
        }
      }
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 32).padding(.top, 34).padding(.bottom, 24)
    }
    .scrollBounceBehavior(.basedOnSize)
    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    .task {
      while !Task.isCancelled { await model.refreshGrants(); model.refreshOpenProjects(); model.pruneBackgroundRuns(); try? await Task.sleep(for: .seconds(5)) }
    }
  }

  func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(title).font(.system(size: 12)).foregroundStyle(Theme.secondary)
      VStack(spacing: 0) { content() }.background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
    }
  }

  func row(title: String, detail: String, end: @escaping () -> Void) -> some View {
    HStack(spacing: 10) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title).font(.system(size: 13, weight: .medium)).fixedSize(horizontal: false, vertical: true)
        Text(detail).font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(2)
      }
      Spacer(minLength: 8)
      Button("End", action: end).buttonStyle(SmallButtonStyle())
    }
    .padding(.horizontal, 12).padding(.vertical, 9)
  }
}
