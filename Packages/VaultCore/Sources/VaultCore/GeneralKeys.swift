import Foundation

/// "General" holds keys that aren't tied to one project folder. Any folder can use them with the usual
/// Touch ID; nobody needs to share or copy them first. Hosts stay bound as for every key.
public enum GeneralKeys {
  public static let project = "General"
  /// Names older versions used for keys with no project.
  static let legacyNames: Set<String> = ["Personal"]

  /// Temporary places (scratch folders, worktrees under /tmp) that can't stand for a lasting project.
  public static func isTemporary(_ path: String) -> Bool {
    let p = (path as NSString).standardizingPath
    let roots = ["/tmp", "/private/tmp", "/var/folders", "/private/var/folders", (NSTemporaryDirectory() as NSString).standardizingPath]
    return roots.contains { !$0.isEmpty && $0 != "/" && (p == $0 || p.hasPrefix($0 + "/")) }
  }

  /// The project a new key gets when the caller didn't name one: General for a temporary folder or no folder,
  /// otherwise the folder's name.
  public static func defaultProject(cwd: String?) -> String {
    guard let cwd, !cwd.isEmpty, !isTemporary(cwd) else { return project }
    let name = URL(fileURLWithPath: cwd).lastPathComponent
    return name.isEmpty || name == "/" ? project : name
  }

  /// Moves keys into General when their project has no lasting folder: the old default name ("Personal"), or a
  /// project whose recorded folders are all temporary or gone from disk and that nobody chose a folder for.
  /// A project with no folder recorded at all (one you named yourself) is left alone.
  /// Returns the new list and the project names that were folded in.
  public static func fold(_ services: [ServiceConfig], exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) })
    -> (services: [ServiceConfig], folded: [String]) {
    var folded = Set<String>()
    for name in Set(services.map(\.project)) where name != project {
      let keys = services.filter { $0.project == name }
      if legacyNames.contains(name) { folded.insert(name); continue }
      if keys.contains(where: { $0.folderChosen == true }) { continue }
      let folders = keys.compactMap(\.folder)
      guard !folders.isEmpty else { continue }
      if folders.allSatisfy({ isTemporary($0) || !exists($0) }) { folded.insert(name) }
    }
    guard !folded.isEmpty else { return (services, []) }
    let next = services.map { s -> ServiceConfig in
      guard folded.contains(s.project) else { return s }
      var c = s; c.project = project; c.folder = nil; c.folderChosen = nil; return c
    }
    return (next, folded.sorted())
  }
}

public extension ServiceConfig {
  /// In General: usable from any folder without being shared first.
  var isGeneral: Bool { project == GeneralKeys.project }
}
