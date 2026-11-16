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
  static var termSource: DispatchSourceSignal?
  func applicationDidFinishLaunching(_ notification: Notification) {
    // One keydillo at a time: if another copy is running (e.g. started by launchd), ask it to show its window.
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
      .filter { $0.processIdentifier != getpid() }
    if !others.isEmpty && UserDefaults.standard.string(forKey: "kdPreview") == nil {
      DistributedNotificationCenter.default().postNotificationName(.init("com.studiokillswitch.keydillo.show"), object: nil, deliverImmediately: true)
      exit(0)
    }
    DistributedNotificationCenter.default().addObserver(forName: .init("com.studiokillswitch.keydillo.show"), object: nil, queue: .main) { _ in
      MainActor.assumeIsolated { WindowManager.shared.showMain() }
    }
    // Logout, `kill` and launchd stop us with SIGTERM: that's a normal exit, not a crash.
    signal(SIGTERM, SIG_IGN)
    let term = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
    term.setEventHandler { MainActor.assumeIsolated { AppModel.shared.noteCleanExit() }; exit(0) }
    term.resume()
    AppDelegate.termSource = term
    MainActor.assumeIsolated {
      AppModel.shared.noteUncleanExit()
      StatusItem.shared = StatusItem()
      if let screen = UserDefaults.standard.string(forKey: "kdPreview") { Preview.show(screen); return }
      if !AppModel.shared.setupDone { WindowManager.shared.showSetup() }
    }
  }

  func applicationWillTerminate(_ notification: Notification) {
    MainActor.assumeIsolated { AppModel.shared.noteCleanExit() }
  }

  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
    MainActor.assumeIsolated { WindowManager.shared.showMain() }
    return true
  }
}
