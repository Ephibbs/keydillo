import Foundation

/// Puts `keydillo` and `kd` in ~/.local/bin, where Claude Code's own installer puts `claude`, so they work in the
/// Terminal without editing any shell file. If that folder isn't on PATH, Setup shows the one line to add.
enum ShellIntegration {
  static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
  static var binDir: URL { home.appendingPathComponent(".local/bin", isDirectory: true) }

  /// Keeps ~/.local/bin/{keydillo,kd} pointing at this copy of the app. Never replaces a file keydillo didn't make.
  /// True when macOS runs this copy from a temporary, randomized path because it was opened straight from
  /// Downloads (App Translocation). Links to it would break once it quits, so they're left alone.
  static var isTranslocated: Bool { Bundle.main.bundlePath.contains("/AppTranslocation/") }

  static func refreshLinks() {
    if isTranslocated { return }
    let fm = FileManager.default
    try? fm.createDirectory(at: binDir, withIntermediateDirectories: true)
    for name in ["keydillo", "kd"] {
      let link = binDir.appendingPathComponent(name)
      let current = try? fm.destinationOfSymbolicLink(atPath: link.path)
      if current == ClaudeConnector.cliPath { continue }
      if current == nil && fm.fileExists(atPath: link.path) { continue }      // someone else's file
      if let current, !current.contains("keydillo") { continue }              // someone else's link
      try? fm.removeItem(at: link)
      try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: ClaudeConnector.cliPath)
    }
  }

  static func removeLinks() {
    let fm = FileManager.default
    for name in ["keydillo", "kd"] {
      let link = binDir.appendingPathComponent(name)
      if (try? fm.destinationOfSymbolicLink(atPath: link.path))?.contains("keydillo") == true { try? fm.removeItem(at: link) }
    }
  }

  /// Whether a login shell finds `kd` on its PATH.
  static func kdOnPath() -> Bool {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/bin/zsh")
    p.arguments = ["-lic", "whence -p kd"]
    p.standardOutput = Pipe(); p.standardError = Pipe()
    guard (try? p.run()) != nil else { return false }
    p.waitUntilExit()
    return p.terminationStatus == 0
  }

  /// The line to add to ~/.zshrc when ~/.local/bin isn't on PATH yet. keydillo shows it; it never edits the file.
  static let pathLine = "export PATH=\"$HOME/.local/bin:$PATH\""
}
