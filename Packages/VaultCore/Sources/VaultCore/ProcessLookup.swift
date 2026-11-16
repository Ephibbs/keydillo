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

  public init(pid: Int32, name: String, agent: String? = nil, agentPid: Int32? = nil, startTime: UInt64 = 0) {
    self.pid = pid; self.name = name; self.agent = agent; self.agentPid = agentPid; self.startTime = startTime
  }

  /// The process a "session" approval belongs to: the agent if we found one, else the caller itself.
  public var sessionKey: String {
    if let agentPid { return "\(agentPid)|\(ProcessLookup.startTime(of: agentPid))" }
    return "\(pid)|\(startTime)"
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
    var cur = pid
    for _ in 0..<8 {
      let n = name(of: cur).lowercased()
      if agentNames.contains(where: { n.contains($0) }) { p.agent = name(of: cur); p.agentPid = cur; break }
      let parent = parentPid(of: cur)
      if parent <= 1 || parent == cur { break }
      cur = parent
    }
    return p
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
