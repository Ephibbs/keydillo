import Foundation
import VaultCore

// Test-only: kd-pgproxy-test <port> <service> <real postgres URL>. Approves every connection for <service>.
let args = CommandLine.arguments
guard args.count == 4, let port = UInt16(args[1]), let target = PostgresURL.parse(args[3]) else {
  FileHandle.standardError.write(Data("usage: kd-pgproxy-test <port> <service> <postgres URL>\n".utf8)); exit(2)
}
let service = args[2]
let proxy = PostgresProxy(port: port) { s, _, _ in
  s == service ? .success(target) : .failure(PostgresProxy.Refusal("no database key named \(s)"))
}
try proxy.start()
print(PostgresURL.local(service: service, target: target, port: port))
fflush(stdout)
dispatchMain()
