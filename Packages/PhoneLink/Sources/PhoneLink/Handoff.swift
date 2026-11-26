import Foundation
import CryptoKit

// Hand-offs: when the browser needs a person (a captcha, a 2FA prompt, an emailed code), the Mac streams the page to
// the paired iPhone and the phone sends taps and typing back. Claude never sees the stream or what is typed.
//
// 1. Mac → phone `HandoffStart`, signed by the Mac.
// 2. Phone → Mac `HandoffJoin`: after one Face ID, the phone's Secure Enclave key signs two fresh session keys
//    (signing and key agreement), so the rest of the session needs no more Face ID.
// 3. Mac → phone `HandoffFrame`s: a JPEG of the page sealed to the session agreement key, signed by the Mac.
// 4. Phone → Mac `HandoffInput`s: taps, text, keys, done; signed by the session signing key, numbered so none
//    can be replayed or reordered.

public struct HandoffStart: Codable, Equatable, Sendable, Identifiable {
  public var v = 1
  public var sessionID: String
  public var macID: String
  public var created: Epoch
  public var expires: Epoch
  /// What the browser needs, e.g. "Solve the captcha on github.com". From keydillo, shown as the notification.
  public var title: String
  public var url: String
  public var signature = Data()
  public var id: String { sessionID }

  var canonical: Data { Canon("kd-handoff-start-v1").string(sessionID).string(macID).int(created).int(expires).string(title).string(url).bytes }

  public static func make(title: String, url: String, macID: String, signer: LinkSigner, ttl: TimeInterval = 600, now: Date = Date()) throws -> HandoffStart {
    var s = HandoffStart(sessionID: randomBytes(16).base64URL, macID: macID, created: epoch(now), expires: epoch(now) + Epoch(ttl), title: title, url: url)
    s.signature = try signer.sign(s.canonical)
    return s
  }

  public func verify(from mac: PairedMac, now: Date = Date()) throws {
    guard v == 1 else { throw LinkError.unsupportedVersion }
    guard macID == mac.macID else { throw LinkError.wrongMac }
    guard PhoneLink.verify(signature, over: canonical, by: mac.signingKey) else { throw LinkError.badSignature }
    guard epoch(now) < expires else { throw LinkError.expired }
  }
}

public struct HandoffJoin: Codable, Equatable, Sendable {
  public var v = 1
  public var sessionID: String
  public var phoneID: String
  public var startDigest: Data
  public var sessionSigningKey: Data
  public var sessionAgreementKey: Data
  public var signature = Data()

  var canonical: Data {
    Canon("kd-handoff-join-v1").string(sessionID).string(phoneID).data(startDigest).data(sessionSigningKey).data(sessionAgreementKey).bytes
  }

  public func verify(for start: HandoffStart, from phone: PairedPhone) throws {
    guard v == 1 else { throw LinkError.unsupportedVersion }
    guard sessionID == start.sessionID else { throw LinkError.wrongRequest }
    guard phoneID == phone.phoneID else { throw LinkError.wrongPhone }
    guard startDigest == start.canonical.sha256 else { throw LinkError.askChanged }
    guard PhoneLink.verify(signature, over: canonical, by: phone.signingKey) else { throw LinkError.badSignature }
  }
}

public struct HandoffFrame: Codable, Equatable, Sendable {
  public var v = 1
  public var sessionID: String
  public var seq: Int64
  public var created: Epoch
  public var width: Int
  public var height: Int
  public var url: String
  public var image: SealedBox
  public var signature = Data()

  static func info(_ session: String, _ seq: Int64) -> String { "kd-frame-v1|\(session)|\(seq)" }

  var canonical: Data {
    Canon("kd-handoff-frame-v1").string(sessionID).int(seq).int(created).int(Int64(width)).int(Int64(height)).string(url).data(image.canonical).bytes
  }

  public func open(from mac: PairedMac, with session: LinkAgreement) throws -> Data {
    guard PhoneLink.verify(signature, over: canonical, by: mac.signingKey) else { throw LinkError.badSignature }
    return try image.open(with: session, info: Self.info(sessionID, seq))
  }
}

public enum HandoffAction: String, Codable, Sendable { case tap, text, key, done, cancel }

public struct HandoffInput: Codable, Equatable, Sendable {
  public var v = 1
  public var sessionID: String
  public var seq: Int64
  public var action: HandoffAction
  /// Tap position as a fraction of the frame, 0...1.
  public var x: Double?
  public var y: Double?
  public var text: String?
  public var signature = Data()

  var canonical: Data {
    Canon("kd-handoff-input-v1").string(sessionID).int(seq).string(action.rawValue)
      .string(x.map { String($0) } ?? "").string(y.map { String($0) } ?? "").string(text ?? "").bytes
  }

  public static func make(_ action: HandoffAction, session: String, seq: Int64, x: Double? = nil, y: Double? = nil, text: String? = nil,
                          signer: LinkSigner) throws -> HandoffInput {
    var i = HandoffInput(sessionID: session, seq: seq, action: action, x: x, y: y, text: text)
    i.signature = try signer.sign(i.canonical)
    return i
  }
}

/// Where hand-off messages travel. Implemented by the folder and CloudKit transports.
public protocol HandoffTransport: AnyObject, Sendable {
  func post(handoff: HandoffStart) async throws
  func pendingHandoffs() async throws -> [HandoffStart]
  func post(join: HandoffJoin) async throws
  func join(for sessionID: String) async throws -> HandoffJoin?
  /// Replaces the session's latest frame.
  func post(frame: HandoffFrame) async throws
  func latestFrame(for sessionID: String) async throws -> HandoffFrame?
  func post(input: HandoffInput) async throws
  func inputs(for sessionID: String) async throws -> [HandoffInput]
  func removeHandoff(_ sessionID: String) async throws
}

// MARK: Mac side

/// One hand-off on the Mac: starts it, accepts the paired phone's join, seals frames, and returns new, verified inputs.
public final class HandoffHost: @unchecked Sendable {
  public let start: HandoffStart
  let phone: PairedPhone
  let signer: LinkSigner
  let transport: HandoffTransport
  private(set) var join: HandoffJoin?
  private var seq: Int64 = 0
  private var lastInput: Int64 = 0
  private let lock = NSLock()

  public init(title: String, url: String, macID: String, phone: PairedPhone, signer: LinkSigner, transport: HandoffTransport, now: Date = Date()) throws {
    self.phone = phone; self.signer = signer; self.transport = transport
    start = try HandoffStart.make(title: title, url: url, macID: macID, signer: signer, now: now)
  }

  public func post() async throws { try await transport.post(handoff: start) }

  /// True once the phone has joined (checked against the paired phone's key).
  public func checkJoin() async -> Bool {
    if join != nil { return true }
    guard let j = try? await transport.join(for: start.sessionID), (try? j.verify(for: start, from: phone)) != nil else { return false }
    join = j
    return true
  }

  public func send(jpeg: Data, width: Int, height: Int, url: String, now: Date = Date()) async throws {
    guard let j = join else { return }
    let n: Int64 = lock.withLock { seq += 1; return seq }
    var f = HandoffFrame(sessionID: start.sessionID, seq: n, created: epoch(now), width: width, height: height, url: url,
                         image: try SealedBox.seal(jpeg, to: j.sessionAgreementKey, info: HandoffFrame.info(start.sessionID, n)))
    f.signature = try signer.sign(f.canonical)
    try await transport.post(frame: f)
  }

  /// Inputs not seen before, in order. Anything not signed by this session's key, or out of order, is dropped.
  public func newInputs() async -> [HandoffInput] {
    guard let j = join, let all = try? await transport.inputs(for: start.sessionID) else { return [] }
    var out: [HandoffInput] = []
    for i in all.sorted(by: { $0.seq < $1.seq }) where i.sessionID == start.sessionID && i.seq > lastInput {
      guard PhoneLink.verify(i.signature, over: i.canonical, by: j.sessionSigningKey) else { continue }
      lastInput = i.seq
      out.append(i)
    }
    return out
  }

  public func end() async { try? await transport.removeHandoff(start.sessionID) }
}

// MARK: Phone side

/// One hand-off on the phone, after it has verified the start and joined.
public final class HandoffViewer: @unchecked Sendable {
  public let start: HandoffStart
  let mac: PairedMac
  let transport: HandoffTransport
  let sessionSigner: SoftwareSigner
  let sessionAgreement: SoftwareAgreement
  private var seq: Int64 = 0
  private var lastFrame: Int64 = 0

  /// `signer` is the phone's paired (Secure Enclave) signing key: one Face ID here covers the whole session.
  public init(start: HandoffStart, mac: PairedMac, phoneID: String, signer: LinkSigner, transport: HandoffTransport, now: Date = Date()) async throws {
    try start.verify(from: mac, now: now)
    self.start = start; self.mac = mac; self.transport = transport
    sessionSigner = SoftwareSigner(); sessionAgreement = SoftwareAgreement()
    var j = HandoffJoin(sessionID: start.sessionID, phoneID: phoneID, startDigest: start.canonical.sha256,
                        sessionSigningKey: sessionSigner.publicKey, sessionAgreementKey: sessionAgreement.publicKey)
    j.signature = try signer.sign(j.canonical)
    try await transport.post(join: j)
  }

  /// The newest frame, if it is newer than the last one shown: (jpeg, width, height, url).
  public func nextFrame() async throws -> (Data, Int, Int, String)? {
    guard let f = try await transport.latestFrame(for: start.sessionID), f.seq > lastFrame, f.sessionID == start.sessionID else { return nil }
    let jpeg = try f.open(from: mac, with: sessionAgreement)
    lastFrame = f.seq
    return (jpeg, f.width, f.height, f.url)
  }

  public func send(_ action: HandoffAction, x: Double? = nil, y: Double? = nil, text: String? = nil) async throws {
    seq += 1
    try await transport.post(input: try HandoffInput.make(action, session: start.sessionID, seq: seq, x: x, y: y, text: text, signer: sessionSigner))
  }
}

// MARK: Folder transport

extension FolderTransport: HandoffTransport {
  public func post(handoff: HandoffStart) async throws { try write(handoff, "handoff-\(handoff.sessionID).json") }
  public func pendingHandoffs() async throws -> [HandoffStart] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return names.filter { $0.hasPrefix("handoff-") }.compactMap { read(HandoffStart.self, $0) }.sorted { $0.created < $1.created }
  }
  public func post(join: HandoffJoin) async throws { try write(join, "hjoin-\(join.sessionID).json") }
  public func join(for sessionID: String) async throws -> HandoffJoin? { read(HandoffJoin.self, "hjoin-\(sessionID).json") }
  public func post(frame: HandoffFrame) async throws { try write(frame, "hframe-\(frame.sessionID).json") }
  public func latestFrame(for sessionID: String) async throws -> HandoffFrame? { read(HandoffFrame.self, "hframe-\(sessionID).json") }
  public func post(input: HandoffInput) async throws { try write(input, "hinput-\(input.sessionID)-\(input.seq).json") }
  public func inputs(for sessionID: String) async throws -> [HandoffInput] {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    return names.filter { $0.hasPrefix("hinput-\(sessionID)-") }.compactMap { read(HandoffInput.self, $0) }
  }
  public func removeHandoff(_ sessionID: String) async throws {
    let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
    for n in names where n.contains(sessionID) { try? FileManager.default.removeItem(at: url(n)) }
  }
}
