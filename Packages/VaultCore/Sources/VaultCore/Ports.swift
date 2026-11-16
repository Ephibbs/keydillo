import Foundation
import Darwin

public enum Ports {
  /// True if nothing is listening on 127.0.0.1:port.
  public static func isFree(_ port: UInt16) -> Bool {
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let r = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
    }
    return r == 0
  }

  /// First free port at or after `start`.
  public static func firstFree(from start: UInt16, tries: UInt16 = 50) -> UInt16? {
    (0..<tries).map { start + $0 }.first(where: isFree)
  }

  /// Name of the process listening on a TCP port, if we can see it.
  public static func listener(on port: UInt16) -> String? {
    let count = proc_listallpids(nil, 0)
    guard count > 0 else { return nil }
    var pids = [Int32](repeating: 0, count: Int(count) * 2)
    let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<Int32>.size))
    for pid in pids.prefix(Int(n)) where pid > 0 && pid != getpid() {
      let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
      guard size > 0 else { continue }
      var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride)
      let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
      for fd in fds.prefix(Int(max(got, 0)) / MemoryLayout<proc_fdinfo>.stride) where fd.proc_fdtype == PROX_FDTYPE_SOCKET {
        var info = socket_fdinfo()
        let r = proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, Int32(MemoryLayout<socket_fdinfo>.size))
        guard r == Int32(MemoryLayout<socket_fdinfo>.size), info.psi.soi_kind == SOCKINFO_TCP else { continue }
        let tcp = info.psi.soi_proto.pri_tcp
        let lport = UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport))
        if lport == port && tcp.tcpsi_state == TSI_S_LISTEN { return ProcessLookup.name(of: pid) }
      }
    }
    return nil
  }
}
