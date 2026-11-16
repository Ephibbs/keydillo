import SwiftUI
import AppKit
import VaultCore

/// "Protect all your existing keys in 1 click": used as setup step 3 and from Settings.
struct ImportView: View {
  @Environment(AppModel.self) private var model
  @State private var im = ImportModel()
  @State private var reviewOpen = false
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
        if im.selectedCount > 0 {
          Button(busy ? "Importing…" : "Import \(im.selectedCount) key\(im.selectedCount == 1 ? "" : "s")") {
            busy = true
            Task { if await im.run(model: model) { done() }; busy = false }
          }
          .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction).disabled(busy)
        }
      }
      .padding(.top, 4)
    }
    .task { if !im.scanned { im.onlyPaths = onlyPaths; await im.scan() } }
  }

  var summary: String {
    if im.scanning || !im.scanned { return "Looking for .env files on this Mac…" }
    if im.totalCount == 0 { return "No keys found in .env files. You can import later from Settings." }
    return "We found \(im.totalCount) key\(im.totalCount == 1 ? "" : "s") in \(im.files.count) .env file\(im.files.count == 1 ? "" : "s"). Each folder becomes a project; keydillo locks the keys away and leaves a placeholder in each file."
  }

  var review: some View {
    VStack(alignment: .leading, spacing: 10) {
      ScrollView {
        VStack(spacing: 10) {
          ForEach(im.files) { f in group(f) }
        }
      }
      .frame(maxHeight: 300)
      Text("Settings like PORT are left alone. If an app reads a key directly, start it with `keydillo run` to keep it working.")
        .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }

  func group(_ f: ImportScanner.FileResult) -> some View {
    let ids = Set(f.keys.map(\.id))
    return VStack(spacing: 0) {
      HStack(spacing: 10) {
        Toggle("", isOn: Binding(get: { ids.isSubset(of: im.selected) }, set: { _ in im.toggleGroup(f) }))
          .toggleStyle(.checkbox).labelsHidden().accessibilityLabel("Import all \(f.project) keys")
        VStack(alignment: .leading, spacing: 1) {
          Text(f.project).font(.system(size: 13, weight: .semibold))
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
      ForEach(f.keys) { k in
        Divider().overlay(Theme.hairline)
        HStack(spacing: 10) {
          Toggle("", isOn: Binding(get: { im.selected.contains(k.id) }, set: { on in if on { im.selected.insert(k.id) } else { im.selected.remove(k.id) } }))
            .toggleStyle(.checkbox).labelsHidden().accessibilityLabel("Import \(k.name)")
          Text(k.name).font(.system(size: 12, design: .monospaced)).lineLimit(1)
          Spacer()
          Text(k.service?.displayName ?? "Needs a host").font(.system(size: 12)).foregroundStyle(Theme.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 7)
      }
    }
    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
  }
}
