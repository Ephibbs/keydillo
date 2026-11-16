import Foundation
import Network

/// Minimal HTTP/1.1 server bound to 127.0.0.1 only. One request per connection.
public final class ProxyServer: @unchecked Sendable {
  public let port: UInt16
  let engine: ProxyEngine
  let queue = DispatchQueue(label: "agent-vault.proxy")
  var listener: NWListener?
  public var onStateChange: (String) -> Void = { _ in }
  /// Override for tests (process lookup needs real sockets from other processes).
  public var identify: (UInt16, UInt16) -> ClientProcess = { ProcessLookup.process(connectedFrom: $0, to: $1) }

  public init(port: UInt16 = 8787, engine: ProxyEngine) {
    self.port = port
    self.engine = engine
  }

  public func start() throws {
    let params = NWParameters.tcp
    params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
    params.allowLocalEndpointReuse = true
    let l = try NWListener(using: params)
    l.stateUpdateHandler = { [weak self] st in
      switch st {
      case .ready: self?.onStateChange("ready")
      case .failed(let e): self?.onStateChange("failed: \(e)")
      case .cancelled: self?.onStateChange("stopped")
      default: break
      }
    }
    l.newConnectionHandler = { [weak self] c in self?.accept(c) }
    l.start(queue: queue)
    listener = l
  }

  public func stop() { listener?.cancel(); listener = nil }

  func accept(_ c: NWConnection) {
    // Refuse anything not from loopback.
    if case .hostPort(let host, _) = c.endpoint, !"\(host)".hasPrefix("127.0.0.1") && "\(host)" != "::1" {
      c.cancel(); return
    }
    c.start(queue: queue)
    receive(c, buffer: Data())
  }

  func receive(_ c: NWConnection, buffer: Data) {
    c.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, done, err in
      guard let self else { return }
      var buf = buffer
      if let data { buf.append(data) }
      switch HTTPParser.parse(buf) {
      case .incomplete:
        if done || err != nil { c.cancel() } else { self.receive(c, buffer: buf) }
      case .invalid(let status, let reason):
        self.send(c, .error(status, reason))
      case .complete(let req, _):
        var clientPort: UInt16 = 0
        if case .hostPort(_, let p) = c.endpoint { clientPort = p.rawValue }
        let client = self.identify(clientPort, self.port)
        Task {
          let resp = await self.engine.handle(req, client: client)
          self.send(c, resp)
        }
      }
    }
  }

  func send(_ c: NWConnection, _ r: HTTPResponse) {
    c.send(content: r.serialized(), completion: .contentProcessed { _ in c.cancel() })
  }
}
