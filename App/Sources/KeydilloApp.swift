import SwiftUI
import AppKit

@main
struct KeydilloApp: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
  var body: some Scene {
    Settings { EmptyView() }
  }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
  func applicationDidFinishLaunching(_ notification: Notification) {
    MainActor.assumeIsolated {
      _ = AppModel.shared
      StatusItem.shared = StatusItem()
      if let screen = UserDefaults.standard.string(forKey: "kdPreview") { Preview.show(screen); return }
      if !AppModel.shared.setupDone { WindowManager.shared.showSetup() }
    }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    MainActor.assumeIsolated { WindowManager.shared.showMain() }
    return true
  }
}
