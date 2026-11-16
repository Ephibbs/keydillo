import Foundation
import AppKit
import VaultCore

/// Moves keys from .env files into keydillo, leaving placeholders behind. Originals are backed up for undo.
@MainActor
@Observable
final class ImportModel {
  var files: [ImportScanner.FileResult] = []
  var selected: Set<String> = []
  var scanning = false
  var scanned = false
  var error: String?
  var lastResult: String?

  var selectedCount: Int { files.flatMap(\.keys).filter { selected.contains($0.id) }.count }
  var totalCount: Int { files.flatMap(\.keys).count }

  func scan() async {
    scanning = true
    let found = await Task.detached(priority: .userInitiated) { ImportScanner.scan() }.value
    files = found
    // Known services are selected by default; unknown ones are the user's call.
    selected = Set(found.flatMap(\.keys).filter { $0.service != nil }.map(\.id))
    scanning = false
    scanned = true
  }

  func toggleGroup(_ f: ImportScanner.FileResult) {
    let ids = Set(f.keys.map(\.id))
    if ids.isSubset(of: selected) { selected.subtract(ids) } else { selected.formUnion(ids) }
  }

  static var backupRoot: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("keydillo/backups", isDirectory: true)
  }

  struct Manifest: Codable { var date: Date; var files: [Entry]; struct Entry: Codable { var original: String; var backup: String } }

  /// Returns true when the import ran.
  func run(model: AppModel) async -> Bool {
    let chosen = files.flatMap(\.keys).filter { selected.contains($0.id) }
    guard !chosen.isEmpty else { return true }
    guard await model.authenticate("import \(chosen.count) key\(chosen.count == 1 ? "" : "s") from your .env files") != nil else { return false }

    var newServices: [ServiceConfig] = []
    var nameByValue: [String: String] = [:]
    var taken = Set(model.services.map(\.name))
    var replacementsByFile: [String: [String: (service: String, baseURL: String?, baseURLEnvName: String?)]] = [:]

    for key in chosen {
      let file = files.first { $0.path == key.file }!
      let projectSlug = file.project.lowercased().filter { $0.isLetter || $0.isNumber }
      let name: String
      if let existing = nameByValue[key.value] {
        name = existing
      } else {
        var base = key.service?.service ?? Self.slug(key.name)
        if taken.contains(base) { base += "-" + projectSlug }
        var candidate = base; var i = 2
        while taken.contains(candidate) { candidate = "\(base)-\(i)"; i += 1 }
        name = candidate
        taken.insert(name); nameByValue[key.value] = name
        var cfg = ServiceConfig(name: name, displayName: key.service?.displayName ?? Self.title(key.name), project: file.project,
                                upstreamHost: key.service?.host ?? "", authHeader: key.service?.header ?? "",
                                authPrefix: key.service?.prefix ?? "", envVarName: key.name, approval: model.defaultApproval.mode)
        cfg.keyPageURL = key.service?.keyPage
        cfg.folder = file.folder
        do { try model.keychain.setSecret(Data(key.value.utf8), for: name, label: cfg.displayName) }
        catch { self.error = "Couldn't store \(key.name): \(error.localizedDescription)"; return false }
        newServices.append(cfg)
      }
      let summary = (newServices.first { $0.name == name } ?? model.service(named: name)).map(model.summary)
      replacementsByFile[key.file, default: [:]][key.name] =
        (name, summary?.baseURL, (key.service == nil) ? nil : summary?.baseURLEnvName)
    }
    do { try model.addImported(newServices) } catch { self.error = error.localizedDescription; return false }

    // Back up, then rewrite each file.
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let dir = Self.backupRoot.appendingPathComponent(stamp, isDirectory: true)
    var manifest = Manifest(date: Date(), files: [])
    do {
      try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
      for (path, reps) in replacementsByFile {
        let url = URL(fileURLWithPath: path)
        let text = try String(contentsOf: url, encoding: .utf8)
        let backup = dir.appendingPathComponent(path.replacingOccurrences(of: "/", with: "_"))
        try text.write(to: backup, atomically: true, encoding: .utf8)
        chmod(backup.path, 0o600)
        manifest.files.append(.init(original: path, backup: backup.path))
        try ImportScanner.rewrite(text, replacements: reps).write(to: url, atomically: true, encoding: .utf8)
      }
      try JSONEncoder().encode(manifest).write(to: dir.appendingPathComponent("manifest.json"))
    } catch {
      self.error = "Keys were stored, but a file couldn't be rewritten: \(error.localizedDescription). Originals are in \(dir.path)."
      return false
    }
    lastResult = "Imported \(chosen.count) key\(chosen.count == 1 ? "" : "s") from \(replacementsByFile.count) file\(replacementsByFile.count == 1 ? "" : "s")."
    return true
  }

  /// Puts back the .env files from the most recent import. Keys stay in keydillo.
  static func undoLast() -> String {
    guard let dirs = try? FileManager.default.contentsOfDirectory(at: backupRoot, includingPropertiesForKeys: nil)
      .filter({ FileManager.default.fileExists(atPath: $0.appendingPathComponent("manifest.json").path) })
      .sorted(by: { $0.lastPathComponent > $1.lastPathComponent }),
          let last = dirs.first,
          let data = try? Data(contentsOf: last.appendingPathComponent("manifest.json")),
          let m = try? JSONDecoder().decode(Manifest.self, from: data) else { return "Nothing to undo." }
    var restored = 0
    for e in m.files {
      if let text = try? String(contentsOfFile: e.backup, encoding: .utf8),
         (try? text.write(toFile: e.original, atomically: true, encoding: .utf8)) != nil { restored += 1 }
    }
    try? FileManager.default.moveItem(at: last, to: last.appendingPathExtension("undone"))
    return "Restored \(restored) file\(restored == 1 ? "" : "s")."
  }

  static func slug(_ envName: String) -> String {
    var s = envName.lowercased()
    for suffix in ["_api_key", "_key", "_token", "_secret"] where s.hasSuffix(suffix) && s.count > suffix.count { s = String(s.dropLast(suffix.count)); break }
    let out = s.replacingOccurrences(of: "_", with: "-").filter { $0.isLetter || $0.isNumber || $0 == "-" }
    return out.first?.isLetter == true ? String(out.prefix(40)) : "key-" + out.prefix(36)
  }

  static func title(_ envName: String) -> String {
    slug(envName).split(separator: "-").map { $0.capitalized }.joined(separator: " ")
  }
}
