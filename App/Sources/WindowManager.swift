import SwiftUI
import AppKit

/// Owns the app's windows. keydillo is a menu-bar app, so windows are created on demand.
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
  static let shared = WindowManager()
  private var windows: [String: NSWindow] = [:]
  private var onClose: [String: () -> Void] = [:]

  func show<V: View>(_ id: String, title: String, floating: Bool = false, resizable: Bool = false,
                     size: CGSize? = nil, onClose: (() -> Void)? = nil, @ViewBuilder _ view: () -> V) {
    if let w = windows[id] {
      w.makeKeyAndOrderFront(nil); NSApp.activate(); return
    }
    let host = NSHostingController(rootView: view().environment(AppModel.shared))
    var style: NSWindow.StyleMask = [.titled, .closable, .fullSizeContentView]
    if resizable { style.insert(.resizable); style.insert(.miniaturizable) }
    let w = NSWindow(contentViewController: host)
    w.styleMask = style
    w.title = title
    w.titleVisibility = .hidden
    w.titlebarAppearsTransparent = true
    w.isMovableByWindowBackground = true
    w.isReleasedWhenClosed = false
    if let size { w.setContentSize(size) }
    if floating { w.level = .floating }
    w.delegate = self
    w.identifier = NSUserInterfaceItemIdentifier(id)
    w.center()
    windows[id] = w
    if let onClose { self.onClose[id] = onClose }
    w.makeKeyAndOrderFront(nil)
    NSApp.activate()
  }

  func close(_ id: String) { windows[id]?.close() }

  func windowWillClose(_ notification: Notification) {
    guard let w = notification.object as? NSWindow, let id = w.identifier?.rawValue else { return }
    windows[id] = nil
    onClose.removeValue(forKey: id)?()
  }

  // MARK: Specific windows

  func showMain() {
    show("main", title: "keydillo", resizable: true, size: CGSize(width: 1080, height: 680)) { MainWindowView() }
  }

  func showSetup() {
    show("setup", title: "Welcome to keydillo") { SetupView() }
  }

  func showKeyWindow(_ request: KeyRequest) {
    let id = "key-\(request.id)"
    show(id, title: "Add a key", floating: request.fromAgent,
         onClose: { AppModel.shared.finishKeyRequest(request.id, saved: nil) }) {
      KeyWindowView(request: request, windowID: id)
    }
  }

  func showAddKey(project: String? = nil) {
    let defaults = AppModel.shared
    let kr = KeyRequest(service: "", displayName: "", host: "", header: "", prefix: "", envVarName: "",
                        project: project ?? defaults.projects.first ?? "Personal", requester: nil, cwd: nil)
    let id = "key-\(kr.id)"
    show(id, title: "Add a key") { KeyWindowView(request: kr, windowID: id) }
  }

  func showReadout(project: String, values: [(String, String)]) {
    windows["readout"]?.close()
    show("readout", title: "\(project) keys") { ReadoutView(project: project, values: values) }
  }

  func showSettings() {
    show("settings", title: "Settings") { SettingsView() }
  }
}
