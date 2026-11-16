import Foundation

/// A parsed HTTP/1.1 request as received from a local client.
public struct HTTPRequest: Equatable {
  public var method: String
  public var target: String          // e.g. /elevenlabs/v1/voices?x=1
  public var headers: [(String, String)]
  public var body: Data

  public static func == (a: HTTPRequest, b: HTTPRequest) -> Bool {
    a.method == b.method && a.target == b.target && a.body == b.body
      && a.headers.map { "\($0.0):\($0.1)" } == b.headers.map { "\($0.0):\($0.1)" }
  }

  public func header(_ name: String) -> String? {
    headers.first { $0.0.caseInsensitiveCompare(name) == .orderedSame }?.1
  }
}

public enum HTTPParseResult: Equatable {
  case incomplete
  case complete(HTTPRequest, consumed: Int)
  case invalid(status: Int, reason: String)
}

public enum HTTPParser {
  public static let maxHeaderBytes = 64 * 1024
  public static let maxBodyBytes = 50 * 1024 * 1024

  /// Parses one request from the front of `buffer`. Chunked request bodies are rejected.
  public static func parse(_ buffer: Data) -> HTTPParseResult {
    let sep = Data("\r\n\r\n".utf8)
    guard let headEnd = buffer.range(of: sep) else {
      return buffer.count > maxHeaderBytes ? .invalid(status: 431, reason: "Headers too large") : .incomplete
    }
    guard let head = String(data: buffer[buffer.startIndex..<headEnd.lowerBound], encoding: .utf8) else {
      return .invalid(status: 400, reason: "Headers are not UTF-8")
    }
    var lines = head.components(separatedBy: "\r\n")
    let requestLine = lines.removeFirst().split(separator: " ", omittingEmptySubsequences: true)
    guard requestLine.count == 3, requestLine[2].hasPrefix("HTTP/1.") else {
      return .invalid(status: 400, reason: "Bad request line")
    }
    var headers: [(String, String)] = []
    for line in lines where !line.isEmpty {
      guard let colon = line.firstIndex(of: ":") else { return .invalid(status: 400, reason: "Bad header") }
      let name = line[..<colon].trimmingCharacters(in: .whitespaces)
      let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty, !name.contains(" ") else { return .invalid(status: 400, reason: "Bad header name") }
      headers.append((name, value))
    }
    var req = HTTPRequest(method: String(requestLine[0]).uppercased(), target: String(requestLine[1]), headers: headers, body: Data())
    let bodyStart = headEnd.upperBound
    if let te = req.header("Transfer-Encoding"), te.lowercased().contains("chunked") {
      // Streamed request body (Node streams, Python generators): decode the chunks.
      var i = bodyStart; var body = Data()
      while true {
        guard let lineEnd = buffer[i...].range(of: Data("\r\n".utf8)) else { return .incomplete }
        let sizeLine = String(decoding: buffer[i..<lineEnd.lowerBound], as: UTF8.self).split(separator: ";").first ?? ""
        guard let size = Int(sizeLine.trimmingCharacters(in: .whitespaces), radix: 16) else { return .invalid(status: 400, reason: "Bad chunk size") }
        let dataStart = lineEnd.upperBound
        if size == 0 {
          // Skip optional trailers up to the blank line.
          guard let end = buffer[lineEnd.lowerBound...].range(of: sep) else { return .incomplete }
          req.body = body
          req.headers.removeAll { $0.0.lowercased() == "transfer-encoding" }
          return .complete(req, consumed: end.upperBound - buffer.startIndex)
        }
        guard buffer.endIndex >= dataStart + size + 2 else { return .incomplete }
        body.append(buffer[dataStart..<(dataStart + size)])
        guard body.count <= maxBodyBytes else { return .invalid(status: 413, reason: "Body too large") }
        i = dataStart + size + 2
      }
    }
    var length = 0
    if let cl = req.header("Content-Length") {
      guard let n = Int(cl), n >= 0 else { return .invalid(status: 400, reason: "Bad Content-Length") }
      guard n <= maxBodyBytes else { return .invalid(status: 413, reason: "Body too large") }
      length = n
    }
    let available = buffer.endIndex - bodyStart
    if available < length { return .incomplete }
    req.body = Data(buffer[bodyStart..<(bodyStart + length)])
    return .complete(req, consumed: (bodyStart + length) - buffer.startIndex)
  }
}

public struct HTTPResponse {
  public var status: Int
  public var reason: String
  public var headers: [(String, String)]
  public var body: Data

  public static func reason(_ status: Int) -> String { HTTPURLResponse.localizedString(forStatusCode: status).capitalized }

  public init(status: Int, reason: String? = nil, headers: [(String, String)] = [], body: Data = Data()) {
    self.status = status
    self.reason = reason ?? HTTPURLResponse.localizedString(forStatusCode: status).capitalized
    self.headers = headers
    self.body = body
  }

  /// Errors are written for the agent: what happened, a stable code, and what to do next.
  public static func error(_ status: Int, _ message: String, code: String = "error", hint: String? = nil) -> HTTPResponse {
    var obj: [String: Any] = ["error": "keydillo: " + message, "code": code, "source": "keydillo"]
    if let hint { obj["hint"] = hint }
    let json = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
    return HTTPResponse(status: status, headers: [("Content-Type", "application/json")], body: json)
  }

  public func serialized() -> Data {
    var head = "HTTP/1.1 \(status) \(reason)\r\n"
    for (k, v) in headers { head += "\(k): \(v)\r\n" }
    head += "Content-Length: \(body.count)\r\nConnection: close\r\n\r\n"
    return Data(head.utf8) + body
  }
}
