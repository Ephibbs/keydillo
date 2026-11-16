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
    item.button?.image = NSImage(systemSymbolName: "key.horizontal", accessibilityDescription: "keydillo")
    item.button?.target = self
    item.button?.action = #selector(toggle)
    popover.behavior = .transient
    popover.contentViewController = NSHostingController(rootView: PopoverView().environment(AppModel.shared))
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
