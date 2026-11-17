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

  /// The app a person would name: "Claude Code" for the claude CLI, else the agent or program name.
  public var friendlyName: String {
    let raw = (agent ?? name).lowercased()
    let names: [(String, String)] = [("claude", "Claude Code"), ("codex", "Codex"), ("cursor", "Cursor"), ("aider", "Aider"), ("goose", "Goose"),
                                     ("gemini", "Gemini CLI"), ("opencode", "OpenCode"), ("windsurf", "Windsurf"), ("copilot", "Copilot")]
    return names.first { raw == $0.0 || raw.hasPrefix($0.0 + "-") || raw.hasPrefix($0.0 + ".") }?.1 ?? (agent ?? name)
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
      let parent = parentPid(of: cur)
      if parent <= 1 || parent == cur { break }
      cur = parent
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
  static func startTime(of pid: Int32) -> UInt64 {
    guard let i = bsdInfo(pid) else { return 0 }
    return i.pbi_start_tvsec * 1_000_000 + i.pbi_start_tvusec
  }
}
