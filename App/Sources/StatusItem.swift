import SwiftUI
import AppKit

/// Menu-bar icon and its popover.
@MainActor
final class StatusItem: NSObject {
  static var shared: StatusItem?
  let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
  let popover = NSPopover()

  override init() {
    super.init()
    let icon = NSImage(named: "MenuBarIcon") ?? NSImage(systemSymbolName: "key.horizontal", accessibilityDescription: "keydillo")
    icon?.isTemplate = true
    icon?.accessibilityDescription = "keydillo"
    item.button?.image = icon
    item.button?.target = self
    item.button?.action = #selector(toggle)
    popover.behavior = .transient
    popover.contentViewController = NSHostingController(rootView: PopoverView().environment(AppModel.shared))
    trackState()
  }

  /// Dims the menu-bar armadillo whenever the proxy isn't running (paused, port taken), so it's visible without opening it.
  func trackState() {
    let model = AppModel.shared
    let off = withObservationTracking { !model.proxyRunning } onChange: { [weak self] in
      DispatchQueue.main.async { self?.trackState() }
    }
    item.button?.appearsDisabled = off
    item.button?.toolTip = off ? "keydillo is off (\(model.proxyState))" : "keydillo"
    item.button?.image?.accessibilityDescription = off ? "keydillo, off" : "keydillo"
  }

  @objc func toggle() {
    if popover.isShown { popover.performClose(nil) } else { open() }
  }

  func open() {
    guard let b = item.button else { return }
    popover.show(relativeTo: b.bounds, of: b, preferredEdge: .minY)
    popover.contentViewController?.view.window?.makeKey()
  }

  func close() { popover.performClose(nil) }

  /// A request is waiting: show the popover so the user sees who's asking.
  func flash() { if !popover.isShown { open() } }
}
