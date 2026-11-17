import Foundation
import Darwin

public struct ClientProcess: Equatable, Hashable, Sendable {
  public var pid: Int32
  public var name: String
  /// Nearest ancestor that looks like an agent (claude, codex, cursor...), if any.
  public var agent: String?
  /// pid of that agent ancestor, used to scope "once per session" approvals.
  public var agentPid: Int32?
  /// Process start time, so a recycled pid is not mistaken for the same process.
  public var startTime: UInt64
  /// Full path of the calling executable.
  public var path: String = ""
  /// The caller's Unix session leader (a terminal tab's login shell, an agent's shell, an app).
  /// Approvals are bound to it, so another terminal or app gets its own prompt.
  public var rootPid: Int32 = -1
  public var rootStart: UInt64 = 0
  public var rootPath: String = ""
  /// Working directory of the caller, when readable (used for per-project rules).
  public var cwd: String?

  public init(pid: Int32, name: String, agent: String? = nil, agentPid: Int32? = nil, startTime: UInt64 = 0) {
    self.pid = pid; self.name = name; self.agent = agent; self.agentPid = agentPid; self.startTime = startTime
  }

  /// False when we couldn't tell who connected. Such callers never get cached approvals.
  public var identified: Bool { pid > 0 && startTime > 0 }

  /// The process tree an approval belongs to. Another terminal, app or session gets its own prompt.
  public var sessionKey: String {
    guard identified else { return "unidentified|\(UUID().uuidString)" }   // never matches a cached grant
    if rootPid > 0 { return "\(rootPid)|\(rootStart)" }
    return "\(pid)|\(startTime)"
  }

  /// True when the agent is Claude Code as signed by Anthropic (set by `describe`).
  public var agentVerified = false

  /// What the approval prompt calls the caller. "Claude Code" only when Anthropic's signature checks out;
  /// anything else is shown by its file name, so a program can't borrow a trusted name by renaming itself.
  public var friendlyName: String {
    if agentVerified { return "Claude Code" }
    if let agent { return "\(agent) (unverified)" }
    return name
  }

  public var displayName: String {
    if let agent, agent != name { return "\(name) via \(agent)" }
    return name
  }

  public static let unknown = ClientProcess(pid: -1, name: "unknown process")
}

/// Maps a loopback TCP connection back to the process that opened it, using libproc.
public enum ProcessLookup {
  static let agentNames = ["claude", "codex", "cursor", "aider", "goose", "gemini", "opencode", "windsurf", "copilot"]

  /// `clientPort` is the client's local port (our remote port).
  /// True when the connection from `clientPort` to `serverPort` was opened by this process itself.
  public static func isOwnConnection(from clientPort: UInt16, to serverPort: UInt16) -> Bool {
    owns(pid: getpid(), localPort: clientPort, remotePort: serverPort)
  }

  public static func process(connectedFrom clientPort: UInt16, to serverPort: UInt16) -> ClientProcess {
    let ownPid = getpid()
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return .unknown }
    var pids = [Int32](repeating: 0, count: Int(count) * 2)
    let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
    for pid in pids.prefix(Int(n)) where pid > 0 && pid != ownPid {
      if owns(pid: pid, localPort: clientPort, remotePort: serverPort) { return describe(pid) }
    }
    return .unknown
  }

  static func owns(pid: Int32, localPort: UInt16, remotePort: UInt16) -> Bool {
    let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
    guard size > 0 else { return false }
    let fdCount = Int(size) / MemoryLayout<proc_fdinfo>.stride
    var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: fdCount)
    let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
    guard got > 0 else { return false }
    for fd in fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
      var info = socket_fdinfo()
      let r = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size))
      guard r == Int32(MemoryLayout<socket_fdinfo>.size), info.psi.soi_kind == SOCKINFO_TCP else { continue }
      let ini = info.psi.soi_proto.pri_tcp.tcpsi_ini
      let lport = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport))
      let fport = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_fport))
      if lport == localPort && fport == remotePort { return true }
    }
    return false
  }

  public static func describe(_ pid: Int32) -> ClientProcess {
    var p = ClientProcess(pid: pid, name: name(of: pid), startTime: startTime(of: pid))
    p.path = path(of: pid)
    p.cwd = cwd(of: pid)
    var cur = pid
    for _ in 0..<12 {
      let n = name(of: cur).lowercased()
      if p.agent == nil, agentNames.contains(where: { n == $0 || n.hasPrefix($0 + "-") || n.hasPrefix($0 + ".") }) { p.agent = name(of: cur); p.agentPid = cur }
      // Claude Code's native installer names its binary after the version (…/claude/versions/2.1.319).
      if p.agent == nil, path(of: cur).contains("/claude/versions/") { p.agent = "claude"; p.agentPid = cur }
      let parent = parentPid(of: cur)
      if parent <= 1 || parent == cur { break }
      cur = parent
    }
    if let a = p.agentPid, (p.agent ?? "").lowercased().hasPrefix("claude") {
      p.agentVerified = signingTeam(a) == anthropicTeam
    }
    // Requests that come through keydillo's own proxy (`kd`, or a Claude Code session's routing) arrive from the
    // keydillo command, not the program that made them. Name the program it serves, after checking it really is
    // keydillo's binary (same signing team as this app). The approval still belongs to that proxy's own session.
    if p.agent == nil, let served = servedBy(pid) {
      if let owner = served.owner {
        let o = describe(owner)
        p.agent = o.agent; p.agentPid = o.agentPid; p.agentVerified = o.agentVerified
        if p.agent == nil { p.name = o.name }
      } else if let command = served.command {
        p.name = command
      }
    }
    // The caller's Unix session (a terminal tab, an agent's shell, an app) is what an approval belongs to.
    let sid = getsid(pid)
    if sid > 1 {
      p.rootPid = sid; p.rootStart = startTime(of: sid); p.rootPath = path(of: sid)
    }
    return p
  }

  public static func path(of pid: Int32) -> String {
    var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    return proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
  }

  public static func cwd(of pid: Int32) -> String? {
    var info = proc_vnodepathinfo()
    let r = proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, Int32(MemoryLayout<proc_vnodepathinfo>.size))
    guard r == Int32(MemoryLayout<proc_vnodepathinfo>.size) else { return nil }
    return withUnsafePointer(to: info.pvi_cdir.vip_path) { $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) } }
  }

  /// True if `pid` is `ancestor` or one of its descendants.
  public static func isDescendant(_ pid: Int32, of ancestor: Int32) -> Bool {
    var cur = pid
    for _ in 0..<32 {
      if cur == ancestor { return true }
      let parent = parentPid(of: cur)
      if parent <= 1 || parent == cur { return false }
      cur = parent
    }
    return false
  }

  static func name(of pid: Int32) -> String {
    var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
    if proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 {
      return URL(fileURLWithPath: String(cString: buf)).lastPathComponent
    }
    var nbuf = [CChar](repeating: 0, count: 256)
    proc_name(pid, &nbuf, UInt32(nbuf.count))
    let s = String(cString: nbuf)
    return s.isEmpty ? "pid \(pid)" : s
  }

  static func bsdInfo(_ pid: Int32) -> proc_bsdinfo? {
    var info = proc_bsdinfo()
    let r = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, Int32(MemoryLayout<proc_bsdinfo>.size))
    return r == Int32(MemoryLayout<proc_bsdinfo>.size) ? info : nil
  }

  static func parentPid(of pid: Int32) -> Int32 { Int32(bsdInfo(pid)?.pbi_ppid ?? 0) }
  /// Every process id on the Mac.
  public static func allPids() -> [Int32] {
    let n = proc_listallpids(nil, 0)
    guard n > 0 else { return [] }
    var buf = [Int32](repeating: 0, count: Int(n) + 64)
    let got = proc_listallpids(&buf, Int32(buf.count * MemoryLayout<Int32>.size))
    return Array(buf.prefix(Int(max(got, 0)))).filter { $0 > 0 }
  }

  public static func startTime(of pid: Int32) -> UInt64 {
    guard let i = bsdInfo(pid) else { return 0 }
    return i.pbi_start_tvsec * 1_000_000 + i.pbi_start_tvusec
  }
}

import Security

public extension ProcessLookup {
  /// Anthropic's Apple team ID, which signs Claude Code.
  static let anthropicTeam = "Q6L2SF6YDW"

  /// The command line of `pid`.
  static func arguments(of pid: Int32) -> [String] {
    var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
    var size = 0
    guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return [] }
    var buf = [UInt8](repeating: 0, count: size)
    guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return [] }
    let argc = Int(buf.withUnsafeBytes { $0.load(as: Int32.self) })
    var i = 4
    while i < size && buf[i] != 0 { i += 1 }   // executable path
    while i < size && buf[i] == 0 { i += 1 }   // padding
    var args: [String] = []
    while args.count < argc && i < size {
      let start = i
      while i < size && buf[i] != 0 { i += 1 }
      args.append(String(decoding: buf[start..<i], as: UTF8.self))
      i += 1
    }
    return args
  }

  /// Apple team that signed `pid` (nil for the current process when `pid` is nil), or nil if unsigned.
  static func signingTeam(_ pid: Int32?) -> String? {
    var code: SecCode?
    if let pid {
      guard SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributePid: NSNumber(value: pid)] as CFDictionary, [], &code) == errSecSuccess else { return nil }
    } else {
      guard SecCodeCopySelf([], &code) == errSecSuccess else { return nil }
    }
    guard let code, SecCodeCheckValidity(code, [], nil) == errSecSuccess else { return nil }
    var staticCode: SecStaticCode?
    guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
    var info: CFDictionary?
    guard SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
          let dict = info as? [String: Any] else { return nil }
    return dict[kSecCodeInfoTeamIdentifier as String] as? String
  }

  /// True when `pid` runs keydillo's own command-line binary, signed by the same team as this process.
  static func isKeydilloBinary(_ pid: Int32) -> Bool {
    guard pid > 0, path(of: pid).hasSuffix("/bin/keydillo") else { return false }
    guard let mine = signingTeam(nil) else { return false }
    return signingTeam(pid) == mine
  }

  /// When `pid` is keydillo's own command running `kd`/`keydillo run` or a Claude Code session's proxy, who it serves.
  static func servedBy(_ pid: Int32) -> (owner: Int32?, command: String?)? {
    guard path(of: pid).hasSuffix("/bin/keydillo") || name(of: pid) == "keydillo" || name(of: pid) == "kd" else { return nil }
    guard let mine = signingTeam(nil), signingTeam(pid) == mine else { return nil }
    let args = Array(arguments(of: pid).dropFirst())
    if let i = args.firstIndex(of: "--serve-for"), i + 1 < args.count, let owner = Int32(args[i + 1]) { return (owner, nil) }
    // kd <command> / keydillo run [--] <command>
    var rest = args
    if rest.first == "run" { rest.removeFirst() }
    if rest.first == "--" { rest.removeFirst() }
    guard let cmd = rest.first, !cmd.hasPrefix("-") else { return nil }
    return (nil, (cmd as NSString).lastPathComponent)
  }
}
