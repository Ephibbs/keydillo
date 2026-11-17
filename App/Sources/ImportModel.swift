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
  var gitTracked: Set<String> = []
  var selected: Set<String> = []
  var scanning = false
  var scanned = false
  var error: String?
  var lastResult: String?
  var restartHint = false
  /// Limit the scan to these files (re-import after something wrote real keys back).
  var onlyPaths: [String]?

  var selectedCount: Int { files.flatMap(\.keys).filter { selected.contains($0.id) }.count }
  var totalCount: Int { files.flatMap(\.keys).filter { !$0.isPublic }.count }

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
    // Which files git tracks, worked out off the main thread: running git while the window draws can crash SwiftUI.
    gitTracked = await Task.detached { Set(found.map(\.path).filter { GitCheck.isTracked($0) }) }.value
    files = found
    let model = AppModel.shared
    // Known services and keys keydillo already holds are selected by default; unknown ones are the user's call.
    let all: [ImportScanner.Found] = found.flatMap { $0.keys }
    // Every secret key is ticked: unknown providers get their site the first time they're used (approved with Touch ID).
    selected = Set(all.filter { k in !k.isPublic && k.localOnly == nil }.map { $0.id })
    _ = model
    scanning = false
    scanned = true
  }

  func toggleGroup(_ f: ImportScanner.FileResult) {
    let ids = Set(f.keys.filter { !$0.isPublic }.map(\.id))
    if ids.isSubset(of: selected) { selected.subtract(ids) } else { selected.formUnion(ids) }
  }

  struct Backup: Codable { var date: Date; var files: [Entry]; struct Entry: Codable { var path: String; var text: String } }

  /// Returns true when the import ran.
  func run(model: AppModel) async -> Bool {
    // Secrets the app uses itself can never be filled back in by a proxy, so they're never replaced.
    let chosen = files.flatMap(\.keys).filter { selected.contains($0.id) }
    guard !chosen.isEmpty else { return true }
    guard model.storageSecure else { self.error = AppModel.insecureMessage; return false }
    guard await model.authenticate("import \(chosen.count) key\(chosen.count == 1 ? "" : "s") from your .env files") != nil else { return false }

    var newServices: [ServiceConfig] = []
    var nameByValue: [String: String] = [:]
    var taken = Set(model.services.map(\.name))
    var replacementsByFile: [String: [String: (service: String, baseURL: String?, baseURLEnvName: String?)]] = [:]
    var prefixesByFile: [String: [String: String]] = [:]

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
        let launch = key.localOnly != nil
        var cfg = ServiceConfig(name: name, displayName: launch ? Self.title(key.name) : (key.service?.displayName ?? Self.title(key.name)), project: file.project,
                                upstreamHost: launch ? "" : (key.service?.host ?? ""), authHeader: launch ? "" : (key.service?.header ?? ""),
                                authPrefix: launch ? "" : (key.service?.prefix ?? ""), envVarName: key.name, approval: model.defaultApproval.mode)
        if launch { cfg.launchTime = true }
        cfg.keyPageURL = key.service?.keyPage
        cfg.folder = file.folder
        if let conv = key.service.flatMap({ ImportScanner.convention(for: $0.service) }) {
          cfg.sdkBasePath = conv.path.isEmpty ? nil : conv.path
          cfg.baseURLEnvName = conv.env
        }
        do { try model.keychain.setSecret(Data(key.value.utf8), for: name, label: cfg.displayName) }
        catch { self.error = "Couldn't store \(key.name): \(error.localizedDescription)"; return false }
        newServices.append(cfg)
      }
      let cfg = newServices.first { $0.name == name } ?? model.service(named: name)
      let summary = cfg.map(model.summary)
      // Only add a base-URL line when the service's SDK actually reads one; otherwise it's noise.
      let readsEnv = cfg.map { $0.baseURLEnvName != nil || ImportScanner.convention(for: $0.name)?.env != nil } ?? false
      if key.localOnly == nil { prefixesByFile[key.file, default: [:]][key.name] = key.keyPrefix }
      replacementsByFile[key.file, default: [:]][key.name] =
        (name, summary?.baseURL, (cfg?.isProxyReady == true && readsEnv) ? summary?.baseURLEnvName : nil)
    }
    do { try model.addImported(newServices) } catch { self.error = error.localizedDescription; return false }

    // Back up the original files into the Keychain, then rewrite them.
    var backup = Backup(date: Date(), files: [])
    var rewritten: [(String, String)] = []
    do {
      for (path, reps) in replacementsByFile {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        backup.files.append(.init(path: path, text: text))
        let launch = Set(chosen.filter { $0.file == path && $0.localOnly != nil }.map(\.name))
        rewritten.append((path, ImportScanner.rewrite(text, replacements: reps, port: model.port, prefixes: prefixesByFile[path] ?? [:], launchNames: launch)))
      }
      try model.keychain.setSecret(try JSONEncoder().encode(backup), for: Self.backupAccount(backup.date), label: "keydillo .env backup",
                                   service: Self.backupService)
      for (path, text) in rewritten { try text.write(toFile: path, atomically: true, encoding: .utf8) }
    } catch {
      self.error = "Keys were stored, but the files couldn't be rewritten: \(error.localizedDescription). Nothing was changed on disk."
      return false
    }
    Self.track(Array(replacementsByFile.keys))
    await model.checkRealKeys()
    restartHint = true
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
  /// Files where a key keydillo manages (same env var, same folder) holds a real value again.
  nonisolated static func filesWithRealKeys(_ paths: [String], managed: [String: Set<String>]) -> [String] {
    paths.filter { path in
      guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return false }
      let folder = (path as NSString).deletingLastPathComponent
      return !ImportScanner.keysBack(text, file: path, managed: managed[folder] ?? []).isEmpty
    }
  }

  /// Earlier imports used the wrong base URLs for some SDKs (OpenAI needs /v1) and odd env names.
  /// Fix the stored settings, then the keydillo-added lines in imported files.
  static func migrateBaseURLs(model: AppModel) {
    guard !UserDefaults.standard.bool(forKey: "migratedBaseURLs1") else { return }
    var changed: [ServiceConfig] = []
    for var s in model.services {
      guard let conv = ImportScanner.convention(for: s.name) else { continue }
      let before = (s.sdkBasePath, s.baseURLEnvName)
      s.sdkBasePath = conv.path.isEmpty ? nil : conv.path
      s.baseURLEnvName = conv.env
      if before != (s.sdkBasePath, s.baseURLEnvName) { changed.append(s) }
    }
    if !changed.isEmpty { try? model.addImported(changed) }
    let byName = Dictionary(uniqueKeysWithValues: model.services.map { ($0.name, $0) })
    for path in trackedFiles {
      guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
      var out: [String] = []
      for line in text.components(separatedBy: "\n") {
        // A keydillo-added line looks like NAME=http://localhost:<port>/<service>...
        if let eq = line.firstIndex(of: "="), !line.hasPrefix("#") {
          let value = line[line.index(after: eq)...]
          // Only keydillo's own address (its port), so a user's local server line is never touched.
          if let r = value.range(of: #"^http://(localhost|127\.0\.0\.1):\#(model.port)/([a-z0-9-]+)"#, options: .regularExpression) {
            let svcName = String(value[r].split(separator: "/").last ?? "")
            if let svc = byName[svcName] {
              let sum = model.summary(svc)
              if svc.baseURLEnvName != nil || ImportScanner.convention(for: svc.name)?.env != nil {
                if !out.contains(where: { $0.hasPrefix(sum.baseURLEnvName + "=") }) { out.append("\(sum.baseURLEnvName)=\(sum.baseURL)") }
              }
              continue   // drop the old line (its replacement, if any, was added above)
            }
          }
        }
        out.append(line)
      }
      let newText = out.joined(separator: "\n")
      if newText != text { try? newText.write(toFile: path, atomically: true, encoding: .utf8) }
    }
    UserDefaults.standard.set(true, forKey: "migratedBaseURLs1")
  }

  /// Short placeholders from earlier imports become the self-explaining form.
  /// Imports the real secret values found in these files (not public or launch-time ones, not ones the user kept).
  static func secure(model: AppModel, files: [String]) async -> String? {
    let im = ImportModel()
    im.onlyPaths = files
    await im.scan()
    let kept = model.keptInFile
    im.selected = Set(im.files.flatMap(\.keys).filter { !$0.isPublic && $0.localOnly == nil && !kept.contains($0.file + "#" + $0.name) }.map(\.id))
    guard !im.selected.isEmpty else { return "Nothing to secure." }
    return await im.run(model: model) ? nil : (im.error ?? "Not secured.")
  }

  /// Launch-time keys imported before random placeholders get one now.
  static func randomizeLaunchPlaceholders(model: AppModel) {
    let launch = Set(model.services.filter(\.isLaunchTime).map(\.name))
    guard !launch.isEmpty else { return }
    for path in trackedFiles {
      guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
      let out = text.components(separatedBy: "\n").map { line -> String in
        guard let eq = line.firstIndex(of: "="), let svc = Placeholder.service(in: line), launch.contains(svc) else { return line }
        let value = String(line[line.index(after: eq)...]).trimmingCharacters(in: CharacterSet(charactersIn: "\"' "))
        guard Placeholder.isPlaceholder(value), !Placeholder.isRandomLaunchValue(value) else { return line }
        return String(line[...eq]) + Placeholder.launchValue(for: svc)
      }.joined(separator: "\n")
      if out != text { try? out.write(toFile: path, atomically: true, encoding: .utf8) }
    }
  }

  static func migratePlaceholders() {
    guard !UserDefaults.standard.bool(forKey: "migratedPlaceholders1") else { return }
    let re = try! NSRegularExpression(pattern: #"^((?:export\s+)?[A-Za-z_][A-Za-z0-9_]*\s*=\s*["']?)keydillo:([a-z0-9-]+)(["']?\s*)$"#)
    for path in trackedFiles {
      guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
      let out = text.components(separatedBy: "\n").map { line -> String in
        let r = NSRange(line.startIndex..., in: line)
        guard let m = re.firstMatch(in: line, range: r) else { return line }
        let head = (line as NSString).substring(with: m.range(at: 1)), name = (line as NSString).substring(with: m.range(at: 2))
        let tail = (line as NSString).substring(with: m.range(at: 3))
        return head + Placeholder.value(for: name) + tail
      }.joined(separator: "\n")
      if out != text { try? out.write(toFile: path, atomically: true, encoding: .utf8) }
    }
    UserDefaults.standard.set(true, forKey: "migratedPlaceholders1")
  }

  /// Files imported before the explanatory header existed get it once.
  /// Adds keydillo's header to tracked .env files, or updates an older version of it in place.
  static func addHeadersToTrackedFiles(port: UInt16) {
    let header = ImportScanner.header(port: port)
    // Files whose keys were all put back keep no keydillo lines (an older put-back left them behind).
    for path in trackedFiles {
      guard let text = try? String(contentsOfFile: path, encoding: .utf8), text.contains(ImportScanner.headerStart),
            !ImportScanner.hasPlaceholders(text) else { continue }
      try? ImportScanner.stripKeydilloLines(text).write(toFile: path, atomically: true, encoding: .utf8)
    }
    for path in trackedFiles {
      guard let text = try? String(contentsOfFile: path, encoding: .utf8), ImportScanner.hasPlaceholders(text) else { continue }
      var lines = text.components(separatedBy: "\n")
      if let a = lines.firstIndex(of: ImportScanner.headerStart), let b = lines[a...].firstIndex(of: ImportScanner.headerEnd) {
        guard Array(lines[a...b]) != header else { continue }
        lines.replaceSubrange(a...b, with: header)
      } else {
        lines.insert(contentsOf: header, at: 0)
      }
      try? lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }
  }

  // MARK: Uninstall

  /// Writes real values back in place of keydillo placeholders in every tracked file.
  /// Puts real values back in place of placeholders, for one project or (nil) everything. The way to stop using keydillo.
  static func restoreRealValues(model: AppModel, project: String? = nil, key: String? = nil) async -> String {
    let whose = key.flatMap { model.service(named: $0)?.displayName }.map { "your \($0)" } ?? project.map { "\($0)'s" } ?? "your"
    guard let ctx = await model.authenticate("put \(whose) real keys back into .env files (programs will see them again)") else { return "Cancelled." }
    var restored = 0
    var missed: [String] = []
    // The lines as they were before import, newest backup first, to keep each value's original quoting.
    var originalText: [String: [String: String]] = [:]
    for a in model.keychain.accounts(service: backupService, context: ctx).sorted(by: >) {
      guard let d = try? model.keychain.secret(for: a, context: ctx, service: backupService),
            let b = try? JSONDecoder().decode(Backup.self, from: d) else { continue }
      for f in b.files {
        for line in f.text.components(separatedBy: "\n") {
          var l = line.trimmingCharacters(in: .whitespaces)
          if l.hasPrefix("export ") { l = String(l.dropFirst(7)) }
          guard let eq = l.firstIndex(of: "="), !l.hasPrefix("#") else { continue }
          let name = String(l[..<eq]).trimmingCharacters(in: .whitespaces)
          let raw = String(l[l.index(after: eq)...])
          if originalText[f.path]?[name] == nil, !Placeholder.isPlaceholder(raw) { originalText[f.path, default: [:]][name] = raw }
        }
      }
    }
    for path in trackedFiles {
      guard var text = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
      var lines = text.components(separatedBy: "\n")
      var changed = false
      var restoredBaseEnvs: [String] = []
      for (i, line) in lines.enumerated() {
        guard let service = Placeholder.service(in: line), project == nil || model.service(named: service)?.project == project,
              key == nil || service == key,
              let eq = line.firstIndex(of: "="),
              Placeholder.isPlaceholder(String(line[line.index(after: eq)...])) else { continue }
        guard let value = try? model.keychain.secret(for: service, context: ctx), !Placeholder.isPlaceholder(String(decoding: value, as: UTF8.self)) else {
          missed.append(String(line[..<eq])); continue
        }
        let name = String(line[..<eq]).replacingOccurrences(of: "export ", with: "").trimmingCharacters(in: .whitespaces)
        lines[i] = String(line[...eq]) + ImportScanner.envValueText(String(decoding: value, as: UTF8.self), original: originalText[path]?[name])
        if let s = model.service(named: service) { restoredBaseEnvs.append(model.summary(s).baseURLEnvName) }
        changed = true
      }
      if changed {
        // Remove keydillo's header and added lines once nothing in the file is locked away any more.
        text = ImportScanner.afterPutBack(lines.joined(separator: "\n"), droppingAdded: Set(restoredBaseEnvs))
        if (try? text.write(toFile: path, atomically: true, encoding: .utf8)) != nil { restored += 1 }
      }
    }
    let done = restored == 0 ? "Nothing to put back\(project.map { " for \($0)" } ?? "")." : "Put real keys back in \(restored) file\(restored == 1 ? "" : "s")."
    return missed.isEmpty ? done : done + " Couldn't restore: \(missed.joined(separator: ", ")) (keydillo doesn't have a real value for these)."
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
