import Foundation
import Darwin

/// Starts keydillo's browser tool (Playwright MCP plus keydillo's filters, run by Node) and keeps it running.
///
/// The tool talks MCP to Claude Code over a Unix socket (relayed by `keydillo browser-mcp`), and asks for
/// passwords over fd 3, one end of a private socketpair only this app holds. Its environment is cleared, so
/// NODE_OPTIONS and the like can't load other code into it.
public final class BrowserHost: @unchecked Sendable {
  public struct Paths: Sendable {
    public var node: String
    public var server: String
    public var dataDir: String
    public var socket: String
    public init(node: String, server: String, dataDir: String, socket: String) {
      self.node = node; self.server = server; self.dataDir = dataDir; self.socket = socket
    }
  }

  public let paths: Paths
  let broker: BrowserBroker
  let extraArgs: [String]
  private var pid: pid_t = 0
  private let lock = NSLock()

  public init(paths: Paths, broker: BrowserBroker, extraArgs: [String] = []) {
    self.paths = paths; self.broker = broker; self.extraArgs = extraArgs
  }

  public static var defaultSocket: String {
    let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/keydillo")
    return dir.appendingPathComponent("browser.sock").path
  }

  public var isRunning: Bool {
    lock.lock(); defer { lock.unlock() }
    return pid > 0 && kill(pid, 0) == 0
  }

  /// Starts the tool if it isn't running, and waits until its socket accepts connections.
  public func ensureRunning() throws {
    lock.lock()
    if pid > 0, kill(pid, 0) == 0 { lock.unlock(); return }
    defer { lock.unlock() }

    var fds: [Int32] = [0, 0]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else { throw VaultError.invalidConfig("socketpair failed") }
    let mine = fds[0], theirs = fds[1]
    _ = fcntl(mine, F_SETFD, FD_CLOEXEC)

    try? FileManager.default.createDirectory(atPath: paths.dataDir, withIntermediateDirectories: true)
    unlink(paths.socket)

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_adddup2(&actions, theirs, 3)
    let devnull = open("/dev/null", O_RDWR)
    posix_spawn_file_actions_adddup2(&actions, devnull, 0)
    let log = open((paths.dataDir as NSString).appendingPathComponent("browser.log"), O_WRONLY | O_CREAT | O_APPEND, 0o600)
    posix_spawn_file_actions_adddup2(&actions, log >= 0 ? log : devnull, 1)
    posix_spawn_file_actions_adddup2(&actions, log >= 0 ? log : devnull, 2)

    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETPGROUP))

    let args = [paths.node, "--disable-sigusr1", paths.server, "--app", "--listen", paths.socket, "--data-dir", paths.dataDir] + extraArgs
    let env = ["HOME=\(NSHomeDirectory())", "PATH=/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR=\(NSTemporaryDirectory())", "LANG=en_US.UTF-8"]
    var cArgs = args.map { strdup($0) } + [nil]
    var cEnv = env.map { strdup($0) } + [nil]
    defer { cArgs.forEach { free($0) }; cEnv.forEach { free($0) } }

    var child: pid_t = 0
    let rc = posix_spawn(&child, paths.node, &actions, &attr, &cArgs, &cEnv)
    close(theirs); close(devnull); if log >= 0 { close(log) }
    guard rc == 0 else { close(mine); throw VaultError.invalidConfig("couldn't start the browser tool (\(rc))") }
    pid = child
    broker.serve(fd: mine)

    // Wait for the socket (up to 15 s).
    for _ in 0..<150 {
      if FileManager.default.fileExists(atPath: paths.socket) { return }
      if kill(child, 0) != 0 { break }
      usleep(100_000)
    }
    throw VaultError.invalidConfig("the browser tool didn't start; see \(paths.dataDir)/browser.log")
  }

  public func stop() {
    lock.lock(); defer { lock.unlock() }
    if pid > 0 { kill(-pid, SIGTERM); kill(pid, SIGTERM) }
    pid = 0
  }
}
