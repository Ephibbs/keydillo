import Foundation

/// Puts `keydillo` and `kd` on the user's PATH and, if they opt in, adds one line to ~/.zshrc that loads the
/// shell hook (`keydillo shell-init`). The hook only touches commands that run in, or point into, a keydillo project.
enum ShellIntegration {
  static var home: URL { FileManager.default.homeDirectoryForCurrentUser }
  static var binDir: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("keydillo/bin", isDirectory: true)
  }
  static var zshrc: URL { home.appendingPathComponent(".zshrc") }
  static let marker = "# keydillo: routes commands in keydillo projects (turn off in keydillo Settings)"

  /// The line added to ~/.zshrc. It does nothing if keydillo has been removed.
  static var line: String {
    let cli = "$HOME/Library/Application Support/keydillo/bin/keydillo"
    return "[[ -x \"\(cli)\" ]] && eval \"$(\"\(cli)\" shell-init)\"  \(marker)"
  }

  /// Keeps ~/Library/Application Support/keydillo/bin/{keydillo,kd} pointing at this copy of the app.
  static func refreshLinks() {
    let fm = FileManager.default
    try? fm.createDirectory(at: binDir, withIntermediateDirectories: true)
    for name in ["keydillo", "kd"] {
      let link = binDir.appendingPathComponent(name)
      if (try? fm.destinationOfSymbolicLink(atPath: link.path)) != ClaudeConnector.cliPath {
        try? fm.removeItem(at: link)
        try? fm.createSymbolicLink(atPath: link.path, withDestinationPath: ClaudeConnector.cliPath)
      }
    }
  }

  static var installed: Bool { ((try? String(contentsOf: zshrc, encoding: .utf8)) ?? "").contains(marker) }

  static func install() throws {
    refreshLinks()
    guard !installed else { return }
    var text = (try? String(contentsOf: zshrc, encoding: .utf8)) ?? ""
    if FileManager.default.fileExists(atPath: zshrc.path) {
      try? text.write(to: zshrc.appendingPathExtension("keydillo-backup"), atomically: true, encoding: .utf8)
    }
    if !text.isEmpty && !text.hasSuffix("\n") { text += "\n" }
    text += line + "\n"
    try text.write(to: zshrc, atomically: true, encoding: .utf8)
  }

  static func remove() {
    guard let text = try? String(contentsOf: zshrc, encoding: .utf8), text.contains(marker) else { return }
    let kept = text.components(separatedBy: "\n").filter { !$0.contains(marker) }.joined(separator: "\n")
    try? kept.write(to: zshrc, atomically: true, encoding: .utf8)
  }
}
