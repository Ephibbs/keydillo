import Foundation
import AppKit
import LocalAuthentication
import VaultCore

/// Moves keys from .env files into keydillo, leaving placeholders behind.
/// Backups of the original files live in the Keychain (they contain real keys), never on disk.
@MainActor
@Observable
final class ImportModel {
  var files: [ImportScanner.FileResult] = []
  var selected: Set<String> = []
  var scanning = false
  var scanned = false
  var error: String?
  var lastResult: String?
  /// Limit the scan to these files (re-import after something wrote real keys back).
  var onlyPaths: [String]?

  var selectedCount: Int { files.flatMap(\.keys).filter { selected.contains($0.id) }.count }
  var totalCount: Int { files.flatMap(\.keys).count }

  func scan() async {
    scanning = true
    let only = onlyPaths
    let found = await Task.detached(priority: .userInitiated) { () -> [ImportScanner.FileResult] in
      guard let only else { return ImportScanner.scan() }
      return only.compactMap { path in
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        let keys = ImportScanner.parse(text, file: path)
        return keys.isEmpty ? nil : ImportScanner.FileResult(path: path, keys: keys)
      }
    }.value
    files = found
    let model = AppModel.shared
    // Known services and keys keydillo already holds are selected by default; unknown ones are the user's call.
    let all: [ImportScanner.Found] = found.flatMap { $0.keys }
    selected = Set(all.filter { k in k.service != nil || model.existing(for: k) != nil }.map { $0.id })
    scanning = false
    scanned = true
  }

  func toggleGroup(_ f: ImportScanner.FileResult) {
    let ids = Set(f.keys.map(\.id))
    if ids.isSubset(of: selected) { selected.subtract(ids) } else { selected.formUnion(ids) }
  }

  struct Backup: Codable { var date: Date; var files: [Entry]; struct Entry: Codable { var path: String; var text: String } }

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
      let name: String
      if let existing = nameByValue[key.value] {
        name = existing
      } else if let existing = model.existing(for: key) {
        // Same env var in the same folder: it's this key again (e.g. after `vercel env pull`). Update it.
        name = existing.name
        nameByValue[key.value] = name
        do { try model.keychain.setSecret(Data(key.value.utf8), for: name, label: existing.displayName) }
        catch { self.error = "Couldn't store \(key.name): \(error.localizedDescription)"; return false }
        model.clearRejected(name)
      } else {
        let projectSlug = file.project.lowercased().filter { $0.isLetter || $0.isNumber }
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
      let cfg = newServices.first { $0.name == name } ?? model.service(named: name)
      let summary = cfg.map(model.summary)
      replacementsByFile[key.file, default: [:]][key.name] =
        (name, summary?.baseURL, (cfg?.isProxyReady == true) ? summary?.baseURLEnvName : nil)
    }
    do { try model.addImported(newServices) } catch { self.error = error.localizedDescription; return false }

    // Back up the original files into the Keychain, then rewrite them.
    var backup = Backup(date: Date(), files: [])
    var rewritten: [(String, String)] = []
    do {
      for (path, reps) in replacementsByFile {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        backup.files.append(.init(path: path, text: text))
        rewritten.append((path, ImportScanner.rewrite(text, replacements: reps)))
      }
      try model.keychain.setSecret(try JSONEncoder().encode(backup), for: Self.backupAccount(backup.date), label: "keydillo .env backup",
                                   service: Self.backupService)
      for (path, text) in rewritten { try text.write(toFile: path, atomically: true, encoding: .utf8) }
    } catch {
      self.error = "Keys were stored, but the files couldn't be rewritten: \(error.localizedDescription). Nothing was changed on disk."
      return false
    }
    Self.track(Array(replacementsByFile.keys))
    lastResult = "Imported \(chosen.count) key\(chosen.count == 1 ? "" : "s") from \(replacementsByFile.count) file\(replacementsByFile.count == 1 ? "" : "s")."
    return true
  }

  // MARK: Backups (Keychain)

  static let backupService = "keydillo.backup"
  static func backupAccount(_ d: Date) -> String { "backup-" + String(Int(d.timeIntervalSince1970)) }

  /// Puts back the .env files from the most recent import. Keys stay in keydillo.
  static func undoLast(model: AppModel) async -> String {
    guard let account = model.keychain.accounts(service: backupService).sorted().last else { return "Nothing to undo." }
    guard let ctx = await model.authenticate("restore your .env files from before the last import"),
          let data = try? model.keychain.secret(for: account, context: ctx, service: backupService),
          let b = try? JSONDecoder().decode(Backup.self, from: data) else { return "Couldn't read the backup." }
    var restored = 0
    for e in b.files where (try? e.text.write(toFile: e.path, atomically: true, encoding: .utf8)) != nil { restored += 1 }
    model.keychain.deleteSecret(account, service: backupService)
    return "Restored \(restored) file\(restored == 1 ? "" : "s")."
  }

  /// Earlier builds kept backups as files. Move them into the Keychain and delete the files.
  static func migrateFileBackups(model: AppModel) {
    let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("keydillo/backups", isDirectory: true)
    guard let dirs = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
    struct OldManifest: Codable { var date: Date; var files: [E]; struct E: Codable { var original: String; var backup: String } }
    for dir in dirs {
      if let d = try? Data(contentsOf: dir.appendingPathComponent("manifest.json")),
         let m = try? JSONDecoder().decode(OldManifest.self, from: d), !dir.pathExtension.contains("undone") {
        let files = m.files.compactMap { e in (try? String(contentsOfFile: e.backup, encoding: .utf8)).map { Backup.Entry(path: e.original, text: $0) } }
        let b = Backup(date: m.date, files: files)
        if let data = try? JSONEncoder().encode(b) {
          try? model.keychain.setSecret(data, for: backupAccount(m.date), label: "keydillo .env backup", service: backupService)
        }
        track(m.files.map(\.original))
      }
      try? FileManager.default.removeItem(at: dir)
    }
    try? FileManager.default.removeItem(at: root)
  }

  // MARK: Tracking imported files

  static var trackedFiles: [String] { UserDefaults.standard.stringArray(forKey: "importedFiles") ?? [] }
  static func track(_ paths: [String]) {
    UserDefaults.standard.set(Array(Set(trackedFiles + paths)).sorted(), forKey: "importedFiles")
  }

  /// Imported files that have real-looking key values in them again.
  nonisolated static func filesWithRealKeys(_ paths: [String]) -> [String] {
    paths.filter { path in
      guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
      return !ImportScanner.parse(text, file: path).isEmpty
    }
  }

  // MARK: Uninstall

  /// Writes real values back in place of keydillo placeholders in every tracked file.
  static func restoreRealValues(model: AppModel) async -> String {
    guard let ctx = await model.authenticate("put your real keys back into your .env files") else { return "Cancelled." }
    var restored = 0
    for path in trackedFiles {
      guard var text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
      var lines = text.components(separatedBy: "\n")
      var changed = false
      for (i, line) in lines.enumerated() {
        guard let service = Placeholder.service(in: line), let eq = line.firstIndex(of: "="),
              line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces).hasPrefix(Placeholder.prefix),
              let value = try? model.keychain.secret(for: service, context: ctx) else { continue }
        lines[i] = String(line[...eq]) + String(decoding: value, as: UTF8.self)
        changed = true
      }
      if changed {
        text = lines.filter { !$0.hasPrefix("# Added by keydillo") }.joined(separator: "\n")
        if (try? text.write(toFile: path, atomically: true, encoding: .utf8)) != nil { restored += 1 }
      }
    }
    return "Restored real keys in \(restored) file\(restored == 1 ? "" : "s")."
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
