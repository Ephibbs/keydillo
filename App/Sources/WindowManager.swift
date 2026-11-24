import SwiftUI
import AppKit
import VaultCore

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
    // Layout snapshots (development only) show the window without taking focus from whatever you're typing in.
    let snapshot = ProcessInfo.processInfo.environment["KEYDILLO_DEV"] == "1" && UserDefaults.standard.string(forKey: "kdShot") != nil
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
    // Open at the content's natural size (the screen permitting); content that can scroll mustn't open at its minimum.
    w.setContentSize(size ?? host.view.fittingSize)
    if floating { w.level = .floating }
    // Windows that can show a key value can't be screen-captured or recorded.
    let devPreview = ProcessInfo.processInfo.environment["KEYDILLO_DEV"] == "1" && UserDefaults.standard.string(forKey: "kdPreview") != nil
    if !devPreview, id == "readout" || id == "main" || id.hasPrefix("key-") { w.sharingType = .none }
    w.delegate = self
    w.identifier = NSUserInterfaceItemIdentifier(id)
    w.center()
    fitOnScreen(w)
    windows[id] = w
    if let onClose { self.onClose[id] = onClose }
    if snapshot { w.orderFrontRegardless(); return }
    w.makeKeyAndOrderFront(nil)
    NSApp.activate()
  }

  /// Never open a window taller or wider than the screen: its content scrolls instead of running off the edge.
  private func fitOnScreen(_ w: NSWindow) {
    guard var visible = (w.screen ?? NSScreen.main)?.visibleFrame else { return }
    visible.size.height = min(visible.height, ScreenRoom.height)
    var f = w.frame
    guard f.height > visible.height || f.width > visible.width else { return }
    f.size = CGSize(width: min(f.width, visible.width), height: min(f.height, visible.height))
    f.origin = CGPoint(x: visible.midX - f.width / 2, y: visible.maxY - f.height)
    w.setFrame(f, display: false)
  }

  func close(_ id: String) { windows[id]?.close() }

  /// The window for a pending key request, with the details and an embedded Touch ID control. It must be on
  /// screen before the context is evaluated so macOS uses it instead of a sheet. Closing it denies the request.
  func showApprovalCard(_ p: PendingApproval, moreOpen: Bool = false) {
    let id = "approval-\(p.id)"
    show(id, title: "keydillo", floating: true, onClose: {
      // Closed by the user while still waiting: deny. Closed because Touch ID finished: leave the result alone.
      if AppModel.shared.pending.contains(where: { $0.id == p.id }) { AppModel.shared.deny(p) }
    }) {
      ApprovalCard(pending: p, moreOpen: moreOpen).sheetCard()
    }
    guard let w = windows[id] else { return }
    w.center()
    w.makeKeyAndOrderFront(nil)
    NSApp.activate(ignoringOtherApps: true)
  }
  func bringToFront(_ id: String) { windows[id]?.makeKeyAndOrderFront(nil) }

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
                        project: project ?? defaults.projects.first ?? GeneralKeys.project, requester: nil, cwd: nil)
    showKeyWindow(kr, id: "key-\(kr.id)")
  }

  /// Replace an existing key (Rotate): same settings, new value.
  @discardableResult func showReplaceKey(_ s: ServiceConfig, requester: String? = nil) -> UUID {
    let kr = KeyRequest(service: s.name, displayName: s.displayName, host: s.upstreamHost, header: s.authHeader, prefix: s.authPrefix,
                        envVarName: s.envVarName, project: s.project, requester: requester, cwd: s.folder, keyPageURL: s.keyPageURL ?? "")
    showKeyWindow(kr, id: "key-\(kr.id)")
    return kr.id
  }

  func showRestore() {
    show("restore", title: "Put real keys back") { RestoreView().sheetCard() }
  }

  func showImport(only: [String]? = nil) {
    show("import", title: "Import keys") { ImportView(inSetup: false, onlyPaths: only) { WindowManager.shared.close("import") }.sheetCard() }
  }

  private func showKeyWindow(_ kr: KeyRequest, id: String) {
    show(id, title: "Add a key", onClose: { AppModel.shared.finishKeyRequest(kr.id, saved: nil) }) { KeyWindowView(request: kr, windowID: id) }
  }

  func showReadout(project: String, values: [(String, String)]) {
    windows["readout"]?.close()
    show("readout", title: "\(project) keys") { ReadoutView(project: project, values: values) }
  }

  func showSettings() {
    show("settings", title: "Settings", resizable: true) { SettingsView() }
  }
}
