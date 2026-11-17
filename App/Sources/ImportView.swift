import SwiftUI
import AppKit
import VaultCore

/// "Protect all your existing keys in 1 click": used as setup step 3 and from Settings.
struct ImportView: View {
  @Environment(AppModel.self) private var model
  @State private var im = ImportModel()
  @State var reviewOpen = false
  @State private var busy = false
  let inSetup: Bool
  var onlyPaths: [String]? = nil
  var done: () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 8) {
        Text("Protect all your existing keys in 1 click").font(.system(size: 22, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
        Text(summary).font(.system(size: 14)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
      }
      if im.totalCount > 0 {
        Collapsible(title: "Review keys and files", isOpen: $reviewOpen) { review }
        Text("Your original files are backed up. Undo anytime in Settings.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
      }
      if let e = im.error { Text(e).font(.system(size: 12)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true) }
      HStack {
        if inSetup { StepDots(count: 4, current: 2) }
        Spacer()
        Button(im.totalCount == 0 && im.scanned ? "Continue" : "Skip") { done() }.buttonStyle(SecondaryButtonStyle())
        if im.totalCount > 0 {
          // Always there once keys are found; with nothing ticked it says so and opens the list.
          Button(busy ? "Importing…" : im.selectedCount == 0 ? (reviewOpen ? "Tick keys to import" : "Choose keys to import") : "Import \(im.selectedCount) key\(im.selectedCount == 1 ? "" : "s")") {
            if im.selectedCount == 0 { reviewOpen = true; return }
            busy = true
            Task { if await im.run(model: model) { done() }; busy = false }
          }
          .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction).disabled(busy || (reviewOpen && im.selectedCount == 0))
          .accessibilityIdentifier("import-primary")
          .onAppear { UIProbe.set("import-primary", 1) }
        }
      }
      .padding(.top, 4)
    }
    .task { if !im.scanned { im.onlyPaths = onlyPaths; await im.scan() } }
  }

  var summary: String {
    if im.scanning || !im.scanned { return "Looking for .env files on this Mac…" }
    if im.totalCount == 0 { return "No keys found in .env files. You can import later from Settings." }
    let ready = im.selectedCount
    let found = "We found \(im.totalCount) key\(im.totalCount == 1 ? "" : "s") in \(im.files.count) .env file\(im.files.count == 1 ? "" : "s"). Each folder becomes a project; keydillo locks the keys away and leaves a placeholder in each file."
    if ready == im.totalCount { return found }
    return found + " \(ready == 0 ? "None are" : "\(ready) are") ticked yet: keydillo only ticks keys for APIs it recognises. Open the list to choose the rest."
  }

  /// Room for every row, up to 320 points (then it scrolls).
  var listHeight: CGFloat {
    let rows = im.files.reduce(0) { $0 + $1.keys.count }
    return min(320, CGFloat(im.files.count) * 56 + CGFloat(rows) * 31 + CGFloat(max(0, im.files.count - 1)) * 10)
  }

  var review: some View {
    VStack(alignment: .leading, spacing: 10) {
      // A ScrollView inside a window that sizes to fit has no height of its own, so give it one.
      ScrollView {
        VStack(spacing: 10) {
          ForEach(im.files) { f in group(f) }
        }
      }
      .frame(height: listHeight)
      .accessibilityIdentifier("import-list")
      .background(GeometryReader { g in
        Color.clear.onAppear { UIProbe.set("import-list-height", g.size.height) }
          .onChange(of: g.size.height) { _, h in UIProbe.set("import-list-height", h) }
      })
      Text("Settings like PORT and public keys (publishable, anon, NEXT_PUBLIC_…) are left alone. After importing, restart running dev servers so they read the new values. If an app reads a key directly, put kd in front: kd npm run dev. Files tracked by git will show the change in your next commit.")
        .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }

  func group(_ f: ImportScanner.FileResult) -> some View {
    let ids = Set(f.keys.filter { $0.localOnly == nil && !$0.isPublic }.map(\.id))
    return VStack(spacing: 0) {
      HStack(spacing: 10) {
        Toggle("", isOn: Binding(get: { ids.isSubset(of: im.selected) }, set: { _ in im.toggleGroup(f) }))
          .toggleStyle(.checkbox).labelsHidden().accessibilityLabel("Import all \(f.project) keys")
        VStack(alignment: .leading, spacing: 1) {
          Text(f.path.hasPrefix(NSHomeDirectory() + "/.") && !f.path.contains("/.env") ? "Shell profile" : f.project).font(.system(size: 13, weight: .semibold))
            + Text(im.gitTracked.contains(f.path) ? "  ·  tracked by git" : "").font(.system(size: 11)).foregroundColor(Theme.danger)
          Text((f.path as NSString).abbreviatingWithTildeInPath).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.secondary)
            .lineLimit(1).truncationMode(.middle)
        }
        Spacer()
        Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: f.path)]) } label: {
          Image(systemName: "folder").font(.system(size: 12)).frame(width: 30, height: 30).background(Circle().fill(Theme.background))
        }
        .buttonStyle(.plain).help("Show in Finder").accessibilityLabel("Show \(f.project) in Finder")
      }
      .padding(.leading, 12).padding(.trailing, 8).padding(.vertical, 8)
      .onAppear { UIProbe.add("import-rows", 1) }
      ForEach(f.keys) { k in
        Divider().overlay(Theme.hairline)
        HStack(spacing: 10) {
          Toggle("", isOn: Binding(get: { im.selected.contains(k.id) && k.localOnly == nil }, set: { on in if on { im.selected.insert(k.id) } else { im.selected.remove(k.id) } }))
            .toggleStyle(.checkbox).labelsHidden().accessibilityLabel("Import \(k.name)").disabled(k.localOnly != nil)
          Text(k.name).font(.system(size: 12, design: .monospaced)).lineLimit(1)
          Spacer()
          Text(k.localOnly.map { "Left as is: \($0)" } ?? (k.isPublic ? "Public, left as is" : (k.service?.displayName ?? "Needs a host")))
            .font(.system(size: 12)).foregroundStyle(Theme.secondary).lineLimit(1)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
        .onAppear { UIProbe.add("import-rows", 1) }
      }
    }
    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
  }
}


enum GitCheck {
  /// True when the file is committed to a git repo (rewriting it will show up as a change).
  nonisolated(unsafe) static var cache: [String: Bool] = [:]
  static func isTracked(_ path: String) -> Bool {
    if let c = cache[path] { return c }
    let r = check(path); cache[path] = r; return r
  }
  static func check(_ path: String) -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    p.arguments = ["-C", (path as NSString).deletingLastPathComponent, "ls-files", "--error-unmatch", (path as NSString).lastPathComponent]
    p.standardOutput = Pipe(); p.standardError = Pipe()
    guard (try? p.run()) != nil else { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
  }
}
