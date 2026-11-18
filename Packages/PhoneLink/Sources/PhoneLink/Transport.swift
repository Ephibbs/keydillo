import Foundation

/// How asks and answers travel between the Mac and the phone. Untrusted: everything that arrives is
/// checked by signature, so the transport can lose or delay messages but can't forge or replay them.
public protocol LinkTransport: AnyObject, Sendable {
  func post(ask: ApprovalAsk) async throws
  func answer(for requestID: String) async throws -> ApprovalAnswer?
  func post(answer: ApprovalAnswer) async throws
  func pendingAsks() async throws -> [ApprovalAsk]
  func remove(requestID: String) async throws
  func post(pairingReply: PairingReply) async throws
  func pairingReply(macID: String) async throws -> PairingReply?
  func removePairingReply(macID: String) async throws
}

public extension LinkTransport {
  /// Polls for the answer until it arrives, the ask expires, or the task is cancelled.
  func waitForAnswer(_ requestID: String, until expires: Epoch, every interval: TimeInterval = 1.5) async -> ApprovalAnswer? {
    while !Task.isCancelled && epoch() <= expires {
      if let a = try? await answer(for: requestID) { return a }
      try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
    }
    return nil
  }
}

/// A shared folder, for tests and for trying the Mac side with `kd-fakephone`.
public final class FolderTransport: LinkTransport, @unchecked Sendable {
  let dir: URL
  public init(_ dir: URL) {
    self.dir = dir
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }
  func url(_ name: String) -> URL { dir.appendingPathComponent(name) }
  func write<T: Encodable>(_ v: T, _ name: String) throws {
    try JSONEncoder().encode(v).write(to: url(name), options: .atomic)
  }
  func read<T: Decodable>(_ t: T.Type, _ name: String) -> T? {
    guard let d = try? Data(contentsOf: url(name)) else { return nil }
    return try? JSONDecoder().decode(t, from: d)
  }

  public func post(ask: ApprovalAsk) async throws { try write(ask, "ask-\(ask.requestID).json") }
  public func answer(for requestID: String) async throws -> ApprovalAnswer? { read(ApprovalAnswer.self, "ans-\(requestID).json") }
  public func post(answer: ApprovalAnswer) async throws { try write(answer, "ans-\(answer.requestID).json") }
  public func pendingAsks() async throws -> [ApprovalAsk] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return names.filter { $0.hasPrefix("ask-") }.compactMap { read(ApprovalAsk.self, $0) }.sorted { $0.created < $1.created }
  }
  public func remove(requestID: String) async throws {
    try? FileManager.default.removeItem(at: url("ask-\(requestID).json"))
    try? FileManager.default.removeItem(at: url("ans-\(requestID).json"))
  }
  public func post(pairingReply: PairingReply) async throws { try write(pairingReply, "pair-\(pairingReply.macID).json") }
  public func pairingReply(macID: String) async throws -> PairingReply? { read(PairingReply.self, "pair-\(macID).json") }
  public func removePairingReply(macID: String) async throws { try? FileManager.default.removeItem(at: url("pair-\(macID).json")) }
}
