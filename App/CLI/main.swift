import Foundation
import VaultCore

// keydillo command-line tool. It talks to the running app and never prints a key value.

func fail(_ msg: String) -> Never {
  FileHandle.standardError.write(Data("keydillo: \(msg)\n".utf8)); exit(1)
}

func flag(_ args: [String], _ name: String) -> String? {
  guard let i = args.firstIndex(of: "--\(name)"), i + 1 < args.count else { return nil }
  return args[i + 1]
}

let usage = """
keydillo: let AI tools use your API keys without seeing them.

  keydillo list                         Services stored in keydillo (names and local URLs only)
  keydillo add <name> --host <host> --header <header> [--prefix "Bearer "] [--env NAME] [--project P]
                                        Opens keydillo so you can paste the key
  keydillo env <name>                   Placeholder .env lines for a service
  keydillo run -- <command>             Run a command; placeholder keys it sends to their API are swapped for the real key
  kd <command>                          Short for keydillo run -- <command>
  keydillo mcp                          Run as an MCP server (used by Claude Code)

There is no command to print a key. Use the Readout in the app.
"""

var args = Array(CommandLine.arguments.dropFirst())
// `kd <command>` is short for `keydillo run -- <command>`.
if (CommandLine.arguments.first.map { ($0 as NSString).lastPathComponent } ?? "") == "kd" {
  if args.isEmpty || args.first == "-h" || args.first == "--help" {
    print("kd <command>: run a command so the keydillo placeholders it sends are swapped for your real keys (same as keydillo run -- <command>).")
    exit(0)
  }
  if args.first == "--" { args.removeFirst() }
  Runner.run(args)
}
guard let cmd = args.first else { print(usage); exit(0) }
args.removeFirst()

func send(_ r: ControlRequest) -> ControlResponse {
  do { return try ControlSocket.send(r) } catch { fail(error.localizedDescription) }
}

switch cmd {
case "mcp":
  let parent = ProcessLookup.describe(getppid())
  MCPServer(requester: parent.agent ?? parent.name).run()

case "list":
  guard case .services(let list) = send(.listServices) else { fail("unexpected reply") }
  if list.isEmpty { print("No services yet. Add one with: keydillo add <name> --host <host> --header <header>") }
  for s in list { print("\(s.name)\t\(s.baseURL)\t\(s.host)\t[\(s.project)]") }

case "add":
  if args.contains(where: { $0 == "--key" || $0 == "--value" }) {
    fail("keys are never passed on the command line (they'd end up in shell history). Paste it in the window that opens.")
  }
  guard let name = args.first, !name.hasPrefix("--") else { fail("usage: keydillo add <name> --host <host> --header <header>") }
  guard let host = flag(args, "host"), let header = flag(args, "header") else { fail("--host and --header are required") }
  let req = SecretRequest(service: name.lowercased(), displayName: flag(args, "name"), host: host, header: header,
                          prefix: flag(args, "prefix"), envVarName: flag(args, "env"),
                          project: flag(args, "project") ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath).lastPathComponent,
                          cwd: FileManager.default.currentDirectoryPath, requester: "keydillo CLI")
  print("Opening keydillo. Paste the key there.")
  switch send(.requestSecret(req)) {
  case .saved(let s, let lines):
    print("Saved. Call \(s.baseURL) instead of https://\(s.host).\nFor your local .env:")
    lines.forEach { print("  \($0)") }
  case .declined: fail("cancelled")
  case .error(let m): fail(m)
  default: fail("unexpected reply")
  }

case "env":
  guard let name = args.first else { fail("usage: keydillo env <name>") }
  guard case .services(let list) = send(.listServices), let s = list.first(where: { $0.name == name }) else {
    fail("no service named \(name)")
  }
  s.placeholderEnvLines.forEach { print($0) }

case "run":
  // Used by the Claude Code session hook: print export lines that route this shell's commands, starting its proxy if needed.
  if args.first == "--shell-env", args.count > 1, let owner = Int32(args[1]) {
    if ProcessInfo.processInfo.environment["KEYDILLO_RUN"] == "1" { exit(0) }   // already routed
    guard let lines = Runner.shellEnv(owner: owner) else {
      FileHandle.standardError.write(Data("keydillo: not routing this command: the keydillo app isn't running. Open keydillo, or use the base URL.\n".utf8))
      exit(1)
    }
    print(lines, terminator: ""); exit(0)
  }
  if args.first == "--serve-for", args.count > 1, let owner = Int32(args[1]) { Runner.serve(owner: owner) }
  if args.first == "--" { args.removeFirst() }
  Runner.run(args)

case "hook":
  // Claude Code hooks. No argument: PreToolUse (steer direct calls). session-start: route Claude's commands.
  // post: explain a provider rejecting a placeholder.
  switch args.first {
  case "session-start": Hook.sessionStart()
  case "post": Hook.post()
  default: Hook.run()
  }

case "whois":
  // Shows how keydillo names a process in approval prompts (for checking; prints no secrets).
  guard let pid = args.first.flatMap(Int32.init) else { fail("usage: keydillo whois <pid>") }
  let c = ProcessLookup.describe(pid)
  print("name: \(c.name)\nagent: \(c.agent ?? "-")\nshown as: \(c.friendlyName)\nsession: \(c.rootPid)")
  if args.contains("-v") { print("team self: \(ProcessLookup.signingTeam(nil) ?? "-") team pid: \(ProcessLookup.signingTeam(pid) ?? "-") args: \(ProcessLookup.arguments(of: pid))") }

case "help", "-h", "--help":
  print(usage)

default:
  fail("unknown command \(cmd)\n\n\(usage)")
}
