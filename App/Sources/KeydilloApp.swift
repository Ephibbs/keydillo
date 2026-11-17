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
    let preview = ProcessInfo.processInfo.environment["KEYDILLO_DEV"] == "1" && UserDefaults.standard.string(forKey: "kdPreview") != nil
    func others() -> [NSRunningApplication] {
      NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
        .filter { $0.processIdentifier != getpid() }
    }
    // Under launchd, give a copy that's handing over to us a moment to quit.
    if Handover.underLaunchd {
      for _ in 0..<20 where !others().isEmpty { Thread.sleep(forTimeInterval: 0.1) }
    }
    // One keydillo at a time: if another copy is running, ask it to show its window.
    if !others().isEmpty && !preview {
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
    // Opened by hand while the keep-alive agent is on: let launchd run keydillo so crashes are restarted.
    if !preview && !Handover.underLaunchd && MainActor.assumeIsolated({ AppModel.agent.status == .enabled }) {
      Handover.toLaunchd(); exit(0)
    }
    MainActor.assumeIsolated {
      AppModel.shared.noteUncleanExit()
      StatusItem.shared = StatusItem()
      // Screenshot previews with sample data: development only (`open --env KEYDILLO_DEV=1 … --args -kdPreview main`).
      if ProcessInfo.processInfo.environment["KEYDILLO_DEV"] == "1", let screen = UserDefaults.standard.string(forKey: "kdPreview") { Preview.show(screen); return }
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

enum Handover {
  static let label = "com.studiokillswitch.keydillo.agent"
  static var underLaunchd: Bool { ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] == label }

  /// Asks launchd to (re)start the keep-alive copy of keydillo.
  static func toLaunchd() {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    p.arguments = ["kickstart", "gui/\(getuid())/\(label)"]
    try? p.run()
  }
}
