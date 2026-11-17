import Foundation
import Network

/// Minimal HTTP/1.1 server bound to 127.0.0.1 only. One request per connection.
public final class ProxyServer: @unchecked Sendable {
  public let port: UInt16
  let engine: ProxyEngine
  let queue = DispatchQueue(label: "keydillo.proxy")
  var listener: NWListener?
  var listener6: NWListener?
  public var onStateChange: (String) -> Void = { _ in }
  /// Override for tests (process lookup needs real sockets from other processes).
  public var identify: (UInt16, UInt16) -> ClientProcess = { ProcessLookup.process(connectedFrom: $0, to: $1) }

  public init(port: UInt16 = 7787, engine: ProxyEngine) {
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
    // Also on ::1, since "localhost" resolves to IPv6 first for some clients (e.g. Node 17+).
    let p6 = NWParameters.tcp
    p6.requiredLocalEndpoint = .hostPort(host: "::1", port: NWEndpoint.Port(rawValue: port)!)
    if let l6 = try? NWListener(using: p6) {
      l6.newConnectionHandler = { [weak self] c in self?.accept(c) }
      l6.start(queue: queue)
      listener6 = l6
    }
  }

  public func stop() { listener?.cancel(); listener = nil; listener6?.cancel(); listener6 = nil }

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
        let head = req.method == "HEAD"
        Task { await self.engine.serve(req, client: client, sink: ConnectionSink(c, queue: self.queue, noBody: head)) }
      }
    }
  }

  func send(_ c: NWConnection, _ r: HTTPResponse) {
    c.send(content: r.serialized(), completion: .contentProcessed { _ in c.cancel() })
  }
}


/// Streams a response to the client with chunked encoding, or turns the connection into a tunnel.
final class ConnectionSink: ResponseSink, @unchecked Sendable {
  let c: NWConnection
  let queue: DispatchQueue
  let noBody: Bool
  var chunked = true

  init(_ c: NWConnection, queue: DispatchQueue, noBody: Bool) { self.c = c; self.queue = queue; self.noBody = noBody }

  func send(_ d: Data) async {
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
      c.send(content: d, completion: .contentProcessed { _ in cont.resume() })
    }
  }

  func start(status: Int, headers: [(String, String)]) async {
    chunked = !(noBody || status == 204 || status == 304 || (100..<200).contains(status))
    var head = "HTTP/1.1 \(status) \(HTTPResponse.reason(status))\r\n"
    for (k, v) in headers where k.lowercased() != "content-length" { head += "\(k): \(v)\r\n" }
    if chunked { head += "Transfer-Encoding: chunked\r\n" }
    head += "Connection: close\r\n\r\n"
    await send(Data(head.utf8))
  }

  func write(_ data: Data) async {
    guard chunked, !data.isEmpty else { return }
    var d = Data(String(data.count, radix: 16).utf8); d.append(contentsOf: [13, 10]); d.append(data); d.append(contentsOf: [13, 10])
    await send(d)
  }

  func finish() async {
    if chunked { await send(Data("0\r\n\r\n".utf8)) }
    c.cancel()
  }

  func tunnel(host: String, port: UInt16, tls: Bool, head: Data, redact: @escaping (Data) -> Data) async {
    let up = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: tls ? .tls : .tcp)
    let client = c
    up.stateUpdateHandler = { st in
      switch st {
      case .ready: up.send(content: head, completion: .idempotent)
      case .failed, .cancelled: client.cancel()
      default: break
      }
    }
    up.start(queue: queue)
    // Read the upstream's answer before deciding: only a real 101 becomes a tunnel.
    func readHead(_ buf: Data) {
      up.receive(minimumIncompleteLength: 1, maximumLength: 65536) { d, _, done, err in
        var b = buf; if let d { b.append(d) }
        guard let end = b.range(of: Data("\r\n\r\n".utf8)) else {
          if done || err != nil || b.count > 65536 { client.cancel(); up.cancel() } else { readHead(b) }
          return
        }
        let statusLine = String(decoding: b[..<end.lowerBound], as: UTF8.self).split(separator: "\r\n").first ?? ""
        if statusLine.split(separator: " ").dropFirst().first == "101" {
          client.send(content: b, completion: .idempotent)
          Self.pipe(client, up); Self.pipe(up, client)
        } else {
          // Not a websocket after all: read the whole response (by Content-Length, or until close), pass it back scrubbed, close.
          let headText = String(decoding: b[..<end.lowerBound], as: UTF8.self).lowercased()
          let length = headText.split(separator: "\r\n").first { $0.hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) }
          let bodyStart = end.upperBound - b.startIndex
          func finish(_ all: Data) { client.send(content: redact(all), completion: .contentProcessed { _ in client.cancel(); up.cancel() }) }
          func readBody(_ acc: Data) {
            if let length, acc.count - bodyStart >= length { return finish(acc) }
            up.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { d, _, done, err in
              var a = acc; if let d { a.append(d) }
              if done || err != nil || a.count > 50_000_000 { finish(a) } else { readBody(a) }
            }
          }
          readBody(b)
        }
      }
    }
    readHead(Data())
  }

  static func pipe(_ from: NWConnection, _ to: NWConnection) {
    from.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { d, _, done, err in
      if let d, !d.isEmpty { to.send(content: d, completion: .idempotent) }
      if done || err != nil { to.cancel(); from.cancel(); return }
      pipe(from, to)
    }
  }
}
