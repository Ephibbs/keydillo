import Foundation
import CryptoKit

public typealias Epoch = Int64
public func epoch(_ d: Date = Date()) -> Epoch { Epoch(d.timeIntervalSince1970) }

// MARK: Pairing

/// Shown on the Mac as a QR code (and as text to paste). The pairing secret proves the phone's reply
/// came from whoever saw this screen, not from something else with access to the same iCloud account.
public struct PairingOffer: Codable, Equatable, Sendable {
  public static let prefix = "kdpair1:"
  public var v = 1
  public var macID: String
  public var macName: String
  public var macSigningKey: Data
  public var pairingSecret: Data
  public var expires: Epoch

  public init(macID: String, macName: String, macSigningKey: Data, ttl: TimeInterval = 600, now: Date = Date()) {
    self.macID = macID; self.macName = macName; self.macSigningKey = macSigningKey
    pairingSecret = randomBytes(32)
    expires = epoch(now.addingTimeInterval(ttl))
  }

  public var code: String { Self.prefix + ((try? JSONEncoder().encode(self)) ?? Data()).base64URL }

  public static func parse(_ code: String) throws -> PairingOffer {
    let s = code.trimmingCharacters(in: .whitespacesAndNewlines)
    guard s.hasPrefix(prefix), let d = Data(base64URL: String(s.dropFirst(prefix.count))),
          let o = try? JSONDecoder().decode(PairingOffer.self, from: d) else { throw LinkError.badPairingCode }
    guard o.v == 1 else { throw LinkError.unsupportedVersion }
    return o
  }
}

/// The phone's answer to a pairing offer: its two Secure Enclave public keys, a MAC with the pairing
/// secret, and a signature with the new signing key (which also shows Face ID works on this phone).
public struct PairingReply: Codable, Equatable, Sendable {
  public var v = 1
  public var macID: String
  public var phoneID: String
  public var phoneName: String
  public var phoneSigningKey: Data
  public var phoneAgreementKey: Data
  public var created: Epoch
  public var tag = Data()
  public var signature = Data()

  var canonical: Data {
    Canon("kd-pair-reply-v1").string(macID).string(phoneID).string(phoneName).data(phoneSigningKey).data(phoneAgreementKey).int(created).bytes
  }

  public static func make(for offer: PairingOffer, phoneID: String, phoneName: String, signer: LinkSigner, agreement: LinkAgreement,
                          now: Date = Date()) throws -> PairingReply {
    guard epoch(now) <= offer.expires else { throw LinkError.expired }
    var r = PairingReply(macID: offer.macID, phoneID: phoneID, phoneName: phoneName, phoneSigningKey: signer.publicKey,
                         phoneAgreementKey: agreement.publicKey, created: epoch(now))
    r.tag = Data(HMAC<SHA256>.authenticationCode(for: r.canonical, using: SymmetricKey(data: offer.pairingSecret)))
    r.signature = try signer.sign(r.canonical + r.tag)
    return r
  }

  /// Checked on the Mac against the offer it showed.
  public func verify(against offer: PairingOffer, now: Date = Date()) throws -> PairedPhone {
    guard v == 1 else { throw LinkError.unsupportedVersion }
    guard macID == offer.macID else { throw LinkError.wrongMac }
    guard created <= offer.expires, epoch(now) <= offer.expires + 60 else { throw LinkError.expired }
    guard HMAC<SHA256>.isValidAuthenticationCode(tag, authenticating: canonical, using: SymmetricKey(data: offer.pairingSecret)) else {
      throw LinkError.badPairingCode
    }
    guard PhoneLink.verify(signature, over: canonical + tag, by: phoneSigningKey) else { throw LinkError.badSignature }
    guard (try? P256.KeyAgreement.PublicKey(x963Representation: phoneAgreementKey)) != nil else { throw LinkError.badEncoding }
    return PairedPhone(phoneID: phoneID, name: phoneName, signingKey: phoneSigningKey, agreementKey: phoneAgreementKey, paired: created)
  }
}

/// What the Mac remembers about its phone. Public keys only.
public struct PairedPhone: Codable, Equatable, Sendable {
  public var phoneID: String
  public var name: String
  public var signingKey: Data
  public var agreementKey: Data
  public var paired: Epoch
  public init(phoneID: String, name: String, signingKey: Data, agreementKey: Data, paired: Epoch) {
    self.phoneID = phoneID; self.name = name; self.signingKey = signingKey; self.agreementKey = agreementKey; self.paired = paired
  }
}

/// What the phone remembers about its Mac. Public key only.
public struct PairedMac: Codable, Equatable, Sendable {
  public var macID: String
  public var name: String
  public var signingKey: Data
  public init(macID: String, name: String, signingKey: Data) { self.macID = macID; self.name = name; self.signingKey = signingKey }
}

// MARK: A key, sealed so only the phone can unlock it

/// A copy of one stored key kept on the Mac for phone approvals. The value is encrypted with a random data key,
/// and the data key is sealed to the phone's Secure Enclave key. Without a Face ID on the paired phone this
/// copy is unreadable, same as the Touch ID-protected original.
public struct WrappedSecret: Codable, Equatable, Sendable {
  public var v = 1
  public var service: String
  public var phoneID: String
  public var sealedDataKey: SealedBox
  public var box: Data
  public var created: Epoch

  static func wrapInfo(_ service: String) -> String { "kd-wrap-v1|" + service }

  public static func wrap(_ secret: Data, service: String, for phone: PairedPhone, now: Date = Date()) throws -> WrappedSecret {
    let dataKey = SymmetricKey(size: .bits256)
    let raw = dataKey.withUnsafeBytes { Data($0) }
    guard let box = try AES.GCM.seal(secret, using: dataKey, authenticating: Data(service.utf8)).combined else { throw LinkError.badEncoding }
    return WrappedSecret(service: service, phoneID: phone.phoneID,
                         sealedDataKey: try SealedBox.seal(raw, to: phone.agreementKey, info: wrapInfo(service)), box: box, created: epoch(now))
  }

  public func unwrap(dataKey: Data) throws -> Data {
    try AES.GCM.open(try AES.GCM.SealedBox(combined: box), using: SymmetricKey(data: dataKey), authenticating: Data(service.utf8))
  }
}

// MARK: Requests and answers

public enum AskKind: String, Codable, Sendable { case use, newHost, start }

/// One approval request, written by the Mac and signed with its key. Every field shown on the phone
/// comes from keydillo's own records (stored key name, bound host, the caller as keydillo identified it),
/// except `path`, which the program chose and is labelled as such.
public struct ApprovalAsk: Codable, Equatable, Sendable, Identifiable {
  public var v = 1
  public var requestID: String
  public var macID: String
  public var kind: AskKind
  public var created: Epoch
  public var expires: Epoch
  /// Short line for the notification, e.g. "Claude Code wants to use your OpenAI key".
  public var title: String
  public var service: String
  public var displayName: String
  public var host: String
  public var method: String
  public var path: String
  public var requester: String
  public var folder: String
  /// Ephemeral key the phone seals its key release to. Its private half exists only in the Mac's memory.
  public var responseKey: Data
  /// This key's data key, sealed to the phone. Absent when the Mac has no phone copy of the key.
  public var sealedDataKey: SealedBox?
  public var signature = Data()

  public var id: String { requestID }

  var canonical: Data {
    Canon("kd-ask-v1").string(requestID).string(macID).string(kind.rawValue).int(created).int(expires).string(title)
      .string(service).string(displayName).string(host).string(method).string(path).string(requester).string(folder)
      .data(responseKey).optional(sealedDataKey?.canonical).bytes
  }
  /// What the phone's answer commits to, so an answer can't be moved to a different request.
  public var digest: Data { canonical.sha256 }

  /// Checked on the phone before anything is shown.
  public func verify(from mac: PairedMac, now: Date = Date()) throws {
    guard v == 1 else { throw LinkError.unsupportedVersion }
    guard macID == mac.macID else { throw LinkError.wrongMac }
    guard PhoneLink.verify(signature, over: canonical, by: mac.signingKey) else { throw LinkError.badSignature }
    guard epoch(now) < expires else { throw LinkError.expired }
  }

  public var secondsLeft: Int { max(0, Int(expires - epoch())) }
}

public enum Decision: String, Codable, Sendable { case approve, deny }

/// The phone's signed answer. An approval carries the key's data key, opened inside the Secure Enclave
/// and sealed again to the Mac's one-time response key.
public struct ApprovalAnswer: Codable, Equatable, Sendable {
  public var v = 1
  public var requestID: String
  public var macID: String
  public var phoneID: String
  public var decision: Decision
  public var answered: Epoch
  public var askDigest: Data
  public var release: SealedBox?
  public var signature = Data()

  static func releaseInfo(_ requestID: String) -> String { "kd-release-v1|" + requestID }

  var canonical: Data {
    Canon("kd-answer-v1").string(requestID).string(macID).string(phoneID).string(decision.rawValue).int(answered)
      .data(askDigest).optional(release?.canonical).bytes
  }

  /// Made on the phone after Face ID. `signer` and `agreement` should share one authenticated context so
  /// the user sees a single Face ID.
  public static func make(for ask: ApprovalAsk, decision: Decision, phoneID: String, signer: LinkSigner, agreement: LinkAgreement,
                          now: Date = Date()) throws -> ApprovalAnswer {
    var release: SealedBox?
    if decision == .approve, let sealed = ask.sealedDataKey {
      let dataKey = try sealed.open(with: agreement, info: WrappedSecret.wrapInfo(ask.service))
      release = try SealedBox.seal(dataKey, to: ask.responseKey, info: releaseInfo(ask.requestID))
    }
    var a = ApprovalAnswer(requestID: ask.requestID, macID: ask.macID, phoneID: phoneID, decision: decision, answered: epoch(now),
                           askDigest: ask.digest, release: release)
    a.signature = try signer.sign(a.canonical)
    return a
  }
}

// MARK: Mac side

/// A request the Mac has sent and is waiting on. Holds the one-time response key in memory only.
public final class PendingAsk: @unchecked Sendable {
  public let ask: ApprovalAsk
  let responseKey: SoftwareAgreement
  let wrapped: WrappedSecret?
  private let lock = NSLock()
  private var used = false

  init(ask: ApprovalAsk, responseKey: SoftwareAgreement, wrapped: WrappedSecret?) {
    self.ask = ask; self.responseKey = responseKey; self.wrapped = wrapped
  }

  public struct Fields: Sendable {
    public var kind: AskKind, title: String, service: String, displayName: String, host: String, method: String, path: String
    public var requester: String, folder: String
    public init(kind: AskKind = .use, title: String, service: String, displayName: String, host: String, method: String, path: String,
                requester: String, folder: String) {
      self.kind = kind; self.title = title; self.service = service; self.displayName = displayName; self.host = host
      self.method = method; self.path = path; self.requester = requester; self.folder = folder
    }
  }

  public static func make(_ f: Fields, macID: String, signer: LinkSigner, wrapped: WrappedSecret?, ttl: TimeInterval = 120,
                          now: Date = Date()) throws -> PendingAsk {
    let rk = SoftwareAgreement()
    let path = f.path.count > 120 ? String(f.path.prefix(119)) + "…" : f.path
    var ask = ApprovalAsk(requestID: UUID().uuidString, macID: macID, kind: f.kind, created: epoch(now), expires: epoch(now.addingTimeInterval(ttl)),
                          title: f.title, service: f.service, displayName: f.displayName, host: f.host, method: f.method, path: path,
                          requester: f.requester, folder: f.folder, responseKey: rk.publicKey, sealedDataKey: wrapped?.sealedDataKey)
    ask.signature = try signer.sign(ask.canonical)
    return PendingAsk(ask: ask, responseKey: rk, wrapped: wrapped)
  }

  public enum Outcome: Equatable {
    /// `secret` is the key's value, unwrapped with the released data key; nil when the ask carried no key.
    case approved(secret: Data?)
    case denied
  }

  /// Checks an answer from the transport. Each pending ask accepts one answer, once.
  public func accept(_ a: ApprovalAnswer, from phone: PairedPhone, now: Date = Date()) throws -> Outcome {
    guard a.v == 1 else { throw LinkError.unsupportedVersion }
    guard a.requestID == ask.requestID else { throw LinkError.wrongRequest }
    guard a.macID == ask.macID else { throw LinkError.wrongMac }
    guard a.phoneID == phone.phoneID else { throw LinkError.wrongPhone }
    guard PhoneLink.verify(a.signature, over: a.canonical, by: phone.signingKey) else { throw LinkError.badSignature }
    guard a.askDigest == ask.digest else { throw LinkError.askChanged }
    // The Mac's own clock decides. The phone's `answered` time is signed but only informative.
    guard epoch(now) <= ask.expires else { throw LinkError.expired }
    lock.lock(); defer { lock.unlock() }
    guard !used else { throw LinkError.replayed }
    used = true
    switch a.decision {
    case .deny: return .denied
    case .approve:
      guard let wrapped else { return .approved(secret: nil) }
      guard let release = a.release else { throw LinkError.missingKey }
      let dataKey = try release.open(with: responseKey, info: ApprovalAnswer.releaseInfo(ask.requestID))
      return .approved(secret: try wrapped.unwrap(dataKey: dataKey))
    }
  }
}
