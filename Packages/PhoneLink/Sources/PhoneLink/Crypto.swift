import Foundation
import CryptoKit

/// A P-256 signing key. On the iPhone it lives in the Secure Enclave and every signature needs Face ID;
/// on the Mac it is a software key in keydillo's private Keychain group.
public protocol LinkSigner {
  /// X9.63 public key.
  var publicKey: Data { get }
  /// Raw (r||s) ECDSA signature over SHA-256 of `data`.
  func sign(_ data: Data) throws -> Data
}

/// A P-256 key-agreement key. On the iPhone it lives in the Secure Enclave behind Face ID.
public protocol LinkAgreement {
  var publicKey: Data { get }
  func sharedSecret(with peer: P256.KeyAgreement.PublicKey) throws -> SharedSecret
}

public struct SoftwareSigner: LinkSigner {
  public let key: P256.Signing.PrivateKey
  public init(_ key: P256.Signing.PrivateKey = .init()) { self.key = key }
  public init(raw: Data) throws { key = try .init(rawRepresentation: raw) }
  public var raw: Data { key.rawRepresentation }
  public var publicKey: Data { key.publicKey.x963Representation }
  public func sign(_ data: Data) throws -> Data { try key.signature(for: data).rawRepresentation }
}

public struct SoftwareAgreement: LinkAgreement {
  public let key: P256.KeyAgreement.PrivateKey
  public init(_ key: P256.KeyAgreement.PrivateKey = .init()) { self.key = key }
  public init(raw: Data) throws { key = try .init(rawRepresentation: raw) }
  public var raw: Data { key.rawRepresentation }
  public var publicKey: Data { key.publicKey.x963Representation }
  public func sharedSecret(with peer: P256.KeyAgreement.PublicKey) throws -> SharedSecret { try key.sharedSecretFromKeyAgreement(with: peer) }
}

#if !targetEnvironment(simulator)
public struct EnclaveSigner: LinkSigner {
  public let key: SecureEnclave.P256.Signing.PrivateKey
  public init(_ key: SecureEnclave.P256.Signing.PrivateKey) { self.key = key }
  public var publicKey: Data { key.publicKey.x963Representation }
  public func sign(_ data: Data) throws -> Data { try key.signature(for: data).rawRepresentation }
}

public struct EnclaveAgreement: LinkAgreement {
  public let key: SecureEnclave.P256.KeyAgreement.PrivateKey
  public init(_ key: SecureEnclave.P256.KeyAgreement.PrivateKey) { self.key = key }
  public var publicKey: Data { key.publicKey.x963Representation }
  public func sharedSecret(with peer: P256.KeyAgreement.PublicKey) throws -> SharedSecret { try key.sharedSecretFromKeyAgreement(with: peer) }
}
#endif

public enum LinkError: Error, Equatable, CustomStringConvertible {
  case badEncoding
  case badSignature
  case expired
  case wrongMac
  case wrongPhone
  case wrongRequest
  case askChanged
  case replayed
  case badPairingCode
  case missingKey
  case unsupportedVersion

  public var description: String {
    switch self {
    case .badEncoding: return "the message couldn't be read"
    case .badSignature: return "the signature didn't match the paired device"
    case .expired: return "the request expired"
    case .wrongMac: return "the request came from a Mac this phone isn't paired with"
    case .wrongPhone: return "the answer came from a phone this Mac isn't paired with"
    case .wrongRequest: return "the answer is for a different request"
    case .askChanged: return "the answer was for different request details than the Mac sent"
    case .replayed: return "that answer was already used"
    case .badPairingCode: return "the pairing code didn't match"
    case .missingKey: return "the approval didn't include the key release"
    case .unsupportedVersion: return "this message is from a newer version of keydillo"
    }
  }
}

func verify(_ signature: Data, over data: Data, by publicKey: Data) -> Bool {
  guard let key = try? P256.Signing.PublicKey(x963Representation: publicKey),
        let sig = try? P256.Signing.ECDSASignature(rawRepresentation: signature) else { return false }
  return key.isValidSignature(sig, for: data)
}

/// Data sealed to one P-256 key-agreement key: an ephemeral ECDH key, HKDF-SHA256 and AES-256-GCM.
/// `info` names what the box is for, so a box made for one purpose can't be opened as another.
public struct SealedBox: Codable, Equatable, Sendable {
  public var ephemeral: Data
  public var box: Data

  static func key(_ shared: SharedSecret, ephemeral: Data, recipient: Data, info: String) -> SymmetricKey {
    shared.hkdfDerivedSymmetricKey(using: SHA256.self, salt: ephemeral + recipient, sharedInfo: Data(info.utf8), outputByteCount: 32)
  }

  public static func seal(_ data: Data, to recipient: Data, info: String) throws -> SealedBox {
    let peer = try P256.KeyAgreement.PublicKey(x963Representation: recipient)
    let eph = P256.KeyAgreement.PrivateKey()
    let shared = try eph.sharedSecretFromKeyAgreement(with: peer)
    let k = key(shared, ephemeral: eph.publicKey.x963Representation, recipient: recipient, info: info)
    guard let box = try AES.GCM.seal(data, using: k).combined else { throw LinkError.badEncoding }
    return SealedBox(ephemeral: eph.publicKey.x963Representation, box: box)
  }

  public func open(with me: LinkAgreement, info: String) throws -> Data {
    let peer = try P256.KeyAgreement.PublicKey(x963Representation: ephemeral)
    let shared = try me.sharedSecret(with: peer)
    let k = Self.key(shared, ephemeral: ephemeral, recipient: me.publicKey, info: info)
    return try AES.GCM.open(try AES.GCM.SealedBox(combined: box), using: k)
  }

  var canonical: Data { Canon().data(ephemeral).data(box).bytes }
}

/// Length-prefixed field encoding, so what gets signed doesn't depend on a JSON encoder's choices.
struct Canon {
  var bytes = Data()
  init(_ tag: String = "") { if !tag.isEmpty { self = self.string(tag) } }
  func data(_ d: Data) -> Canon {
    var c = self
    var n = UInt32(d.count).bigEndian
    c.bytes.append(Data(bytes: &n, count: 4))
    c.bytes.append(d)
    return c
  }
  func string(_ s: String) -> Canon { data(Data(s.utf8)) }
  func int(_ i: Int64) -> Canon { string(String(i)) }
  /// Added after v1 shipped: absent purpose leaves the bytes exactly as before, so older asks still verify.
  func withPurpose(_ p: String?) -> Canon { p.map { string("purpose").string($0) } ?? self }
  func optional(_ d: Data?) -> Canon { d.map { string("1").data($0) } ?? string("0") }
}

extension Data {
  public var base64URL: String {
    base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
  }
  public init?(base64URL s: String) {
    var b = s.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    while b.count % 4 != 0 { b += "=" }
    self.init(base64Encoded: b)
  }
  var sha256: Data { Data(SHA256.hash(data: self)) }
}

public func randomBytes(_ n: Int) -> Data {
  var d = Data(count: n)
  _ = d.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, n, $0.baseAddress!) }
  return d
}
