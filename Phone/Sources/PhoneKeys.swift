import CryptoKit
import Foundation
import LocalAuthentication
import PhoneLink
import Security

/// This phone's two keys: one signs answers, one unseals the Mac's key copies.
/// On a device both live in the Secure Enclave and can only be used after Face ID (`.biometryCurrentSet`:
/// enrolling a new face makes them unusable, and the phone has to pair again).
/// The Keychain holds only the Secure Enclave's encrypted handles, which are useless on any other device.
enum PhoneKeys {
  static let service = "keydillo.phone.keys"

  struct Unlocked { let signer: LinkSigner; let agreement: LinkAgreement }

  /// Asks for Face ID once and returns both keys bound to that authentication.
  static func unlock(reason: String, create: Bool = false) async throws -> Unlocked {
    #if targetEnvironment(simulator)
    // The simulator has no Secure Enclave: software keys, test use only.
    let s = try load("sign").map(SoftwareSigner.init(raw:)) ?? { let k = SoftwareSigner(); try save("sign", k.raw); return k }()
    let a = try load("agree").map(SoftwareAgreement.init(raw:)) ?? { let k = SoftwareAgreement(); try save("agree", k.raw); return k }()
    return Unlocked(signer: s, agreement: a)
    #else
    let ctx = LAContext()
    ctx.localizedCancelTitle = "Cancel"
    guard try await ctx.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) else { throw LinkError.badSignature }
    if create {
      var err: Unmanaged<CFError>?
      guard let ac = SecAccessControlCreateWithFlags(nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet], &err) else {
        throw err!.takeRetainedValue() as Error
      }
      let s = try SecureEnclave.P256.Signing.PrivateKey(accessControl: ac, authenticationContext: ctx)
      let a = try SecureEnclave.P256.KeyAgreement.PrivateKey(accessControl: ac, authenticationContext: ctx)
      try save("sign", s.dataRepresentation)
      try save("agree", a.dataRepresentation)
      return Unlocked(signer: EnclaveSigner(s), agreement: EnclaveAgreement(a))
    }
    guard let sd = try load("sign"), let ad = try load("agree") else { throw LinkError.missingKey }
    return Unlocked(signer: EnclaveSigner(try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: sd, authenticationContext: ctx)),
                    agreement: EnclaveAgreement(try SecureEnclave.P256.KeyAgreement.PrivateKey(dataRepresentation: ad, authenticationContext: ctx)))
    #endif
  }

  static var available: Bool {
    #if targetEnvironment(simulator)
    return true
    #else
    return SecureEnclave.isAvailable
    #endif
  }

  static func delete() {
    SecItemDelete([kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service] as CFDictionary)
  }

  private static func query(_ account: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
  }

  private static func save(_ account: String, _ data: Data) throws {
    SecItemDelete(query(account) as CFDictionary)
    var q = query(account)
    q[kSecValueData as String] = data
    q[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
    let s = SecItemAdd(q as CFDictionary, nil)
    guard s == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(s)) }
  }

  private static func load(_ account: String) throws -> Data? {
    var q = query(account)
    q[kSecReturnData as String] = true
    var out: CFTypeRef?
    let s = SecItemCopyMatching(q as CFDictionary, &out)
    if s == errSecItemNotFound { return nil }
    guard s == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(s)) }
    return out as? Data
  }
}
