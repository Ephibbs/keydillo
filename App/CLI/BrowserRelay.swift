import Foundation
import Darwin

/// `keydillo browser-mcp`: Claude Code runs this as an MCP server. It relays stdin/stdout to keydillo's browser
/// tool, which the app started and which is the only thing the app hands passwords to.
enum BrowserRelay {
  static func run(socket path: String) -> Never {
    let fd = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard fd >= 0 else { fail("socket failed") }
    var addr = sockaddr_un()
    addr.sun_family = sa_family_t(AF_UNIX)
    let bytes = Array(path.utf8.prefix(MemoryLayout.size(ofValue: addr.sun_path) - 1))
    withUnsafeMutableBytes(of: &addr.sun_path) { raw in
      for (i, b) in bytes.enumerated() { raw[i] = b }
    }
    let ok = withUnsafePointer(to: &addr) {
      $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
    }
    guard ok == 0 else { fail("couldn't reach keydillo's browser tool at \(path)") }

    func pump(_ from: Int32, _ to: Int32) {
      var buf = [UInt8](repeating: 0, count: 65536)
      while true {
        let n = read(from, &buf, buf.count)
        if n <= 0 { break }
        var off = 0
        while off < n {
          let w = buf.withUnsafeBytes { write(to, $0.baseAddress! + off, n - off) }
          if w <= 0 { exit(0) }
          off += w
        }
      }
    }
    Thread.detachNewThread { pump(STDIN_FILENO, fd); shutdown(fd, SHUT_WR) }
    pump(fd, STDOUT_FILENO)
    exit(0)
  }
}
