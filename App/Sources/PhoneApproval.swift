import AppKit
import CoreImage.CIFilterBuiltins
import Foundation
import LocalAuthentication
import PhoneLink
import Security
import SwiftUI
import VaultCore

/// Approving requests from a paired iPhone with Face ID (prototype).
///
/// Keys stay on the Mac. Each key's original needs Touch ID to read, so a phone "yes" can't open it. Instead,
/// after pairing, keydillo keeps a second copy of each key encrypted with a data key that only the phone's
/// Secure Enclave can unseal. An approval on the phone unseals the data key and seals it again to a one-time
/// key held in the Mac's memory for that request. The phone sees the request details and the data key, never
/// the key's value.
///
/// Asks and answers travel through the user's own iCloud (CloudKit private database). For local tests,
/// `KEYDILLO_PHONE_FOLDER=/some/dir` swaps in a folder and `kd-fakephone` plays the phone.
final class PhoneApprovals: @unchecked Sendable {
  static let shared = PhoneApprovals()
  static let itemService = "keydillo.phone"

  struct Saved: Codable { var macID: String; var macKey: Data; var phone: PairedPhone? }

  let transport: LinkTransport?
  /// Shown in Settings: where requests go, or why iPhone approval is unavailable.
  let transportNote: String
  private let lock = NSLock()
  private var saved: Saved?
  private var releases: [String: (value: SecureBuffer, until: Date)] = [:]

  private init() {
    if let f = ProcessInfo.processInfo.environment["KEYDILLO_PHONE_FOLDER"], !f.isEmpty {
      transport = FolderTransport(URL(fileURLWithPath: f)); transportNote = "Test mode: requests go to \(f)"
    } else if Self.hasICloud {
      transport = CloudKitTransport(); transportNote = "Requests go through your iCloud. Your keys never leave this Mac."
    } else {
      transport = nil; transportNote = "This build isn't signed for iCloud, so iPhone approval is off."
    }
    saved = Self.read("state").flatMap { try? JSONDecoder().decode(Saved.self, from: $0) }
  }

  /// Creating a CKContainer without the iCloud entitlement crashes, so check the signature first.
  static var hasICloud: Bool {
    guard let task = SecTaskCreateFromSelf(nil),
          let v = SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-identifiers" as CFString, nil) as? [String] else { return false }
    return v.contains(CloudKitTransport.defaultContainer)
  }

  var phone: PairedPhone? { lock.lock(); defer { lock.unlock() }; return saved?.phone }
  var ready: Bool { transport != nil && phone != nil }
  var copiedKeys: [String] {
    Self.accounts().filter { $0.hasPrefix("wrapped:") }.map { String($0.dropFirst("wrapped:".count)) }
  }

  // MARK: Pairing

  private func identity() throws -> (id: String, signer: SoftwareSigner) {
    lock.lock(); defer { lock.unlock() }
    if let s = saved { return (s.macID, try SoftwareSigner(raw: s.macKey)) }
    let signer = SoftwareSigner()
    let s = Saved(macID: UUID().uuidString, macKey: signer.raw, phone: nil)
    // Screen previews run next to the real app and must not write to its Keychain.
    if !AppModel.devHarness { try Self.write("state", try JSONEncoder().encode(s)) }
    saved = s
    return (s.macID, signer)
  }

  /// For hand-offs (BrowserHandoff.swift).
  func handoffIdentity() throws -> (id: String, signer: SoftwareSigner) { try identity() }

  func makeOffer() throws -> PairingOffer {
    let me = try identity()
    return PairingOffer(macID: me.id, macName: Host.current().localizedName ?? "Mac", macSigningKey: me.signer.publicKey)
  }

  /// Waits for the phone's reply to this offer and checks it. nil if the offer expired or the wait was cancelled.
  func waitForPhone(_ offer: PairingOffer) async throws -> PairedPhone? {
    guard let transport else { return nil }
    try? await transport.removePairingReply(macID: offer.macID)
    while !Task.isCancelled && epoch() <= offer.expires {
      if let r = try? await transport.pairingReply(macID: offer.macID) { return try r.verify(against: offer) }
      try? await Task.sleep(for: .seconds(2))
    }
    return nil
  }

  /// Saves the phone and makes a phone copy of every key, reading each with the Touch ID `context`.
  func finishPairing(_ phone: PairedPhone, context: LAContext, services: [ServiceConfig], keychain: KeychainBackend) throws -> Int {
    lock.lock()
    guard var s = saved else { lock.unlock(); throw LinkError.badPairingCode }
    s.phone = phone
    try Self.write("state", try JSONEncoder().encode(s))
    saved = s
    lock.unlock()
    Self.deleteCopies()
    var n = 0
    for svc in services where !svc.isLaunchTime {
      guard var value = try? keychain.secret(for: svc.name, context: context) else { continue }
      defer { value.resetBytes(in: 0..<value.count) }
      if (try? storeCopy(svc.name, value)) != nil { n += 1 }
    }
    if let t = transport { Task { try? await t.removePairingReply(macID: s.macID) } }
    return n
  }

  func unpair() {
    lock.lock()
    if var s = saved { s.phone = nil; try? Self.write("state", try JSONEncoder().encode(s)); saved = s }
    releases.removeAll()
    lock.unlock()
    Self.deleteCopies()
  }

  // MARK: Phone copies of keys

  func storeCopy(_ service: String, _ value: Data) throws {
    guard let phone else { return }
    try Self.write("wrapped:" + service, try JSONEncoder().encode(try WrappedSecret.wrap(value, service: service, for: phone)))
  }

  /// After a Touch ID approval on the Mac: refresh this key's phone copy, so new and rotated keys follow.
  func refreshCopy(_ service: String, context: LAContext?, keychain: KeychainBackend) {
    guard ready, let context, var value = try? keychain.secret(for: service, context: context) else { return }
    defer { value.resetBytes(in: 0..<value.count) }
    try? storeCopy(service, value)
  }

  func copy(of service: String) -> WrappedSecret? {
    guard let phone, let d = Self.read("wrapped:" + service), let w = try? JSONDecoder().decode(WrappedSecret.self, from: d),
          w.phoneID == phone.phoneID else { return nil }
    return w
  }

  // MARK: Asking

  /// Sends the request to the phone and, when `mac` is given, shows Touch ID at the same time. First answer wins.
  func ask(_ request: ApprovalRequest, wrapped: WrappedSecret, mac: (@Sendable () async -> Bool)?, cancelMac: @escaping @Sendable () -> Void) async -> RaceResult {
    guard let transport, let phone, let me = try? identity() else { return .timedOut }
    let folder = request.client.cwd.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? ""
    let fields = PendingAsk.Fields(kind: .use, title: "\(request.client.friendlyName) wants to use your \(request.displayName) key",
                                   service: request.service, displayName: request.displayName, host: request.host, method: request.method,
                                   path: request.path, requester: request.client.friendlyName, folder: folder)
    guard let pending = try? PendingAsk.make(fields, macID: me.id, signer: me.signer, wrapped: wrapped) else { return .timedOut }
    return await raceApproval(mac: mac, cancelMac: cancelMac, pending: pending, phone: phone, transport: transport,
                              log: { NSLog("keydillo: %@", $0) })
  }

  // MARK: Values released by the phone

  /// Holds a phone-released value for as long as the approval it came with lasts, so later reads under the same
  /// grant don't need the Mac's Touch ID.
  func hold(_ service: String, _ value: Data, approval: ApprovalMode) {
    let seconds: TimeInterval
    switch approval {
    case .eachRequest: seconds = 15
    case .perProcess: seconds = 30 * 60
    case .window(let m): seconds = TimeInterval(m) * 60
    }
    lock.lock(); releases[service] = (SecureBuffer(value), Date().addingTimeInterval(seconds)); lock.unlock()
  }

  func released(_ service: String) -> Data? {
    lock.lock(); defer { lock.unlock() }
    guard let r = releases[service] else { return nil }
    if r.until <= Date() { releases[service] = nil; return nil }
    return r.value.data
  }

  // MARK: Keychain (private group, readable while the Mac is locked once it has been unlocked since boot)

  private static func base(_ account: String?) -> [String: Any]? {
    guard let group = AppModel.accessGroup else { return nil }
    var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: itemService,
                            kSecUseDataProtectionKeychain as String: true, kSecAttrAccessGroup as String: group]
    if let account { q[kSecAttrAccount as String] = account }
    return q
  }

  static func read(_ account: String) -> Data? {
    guard var q = base(account) else { return nil }
    q[kSecReturnData as String] = true
    var out: CFTypeRef?
    return SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess ? out as? Data : nil
  }

  static func write(_ account: String, _ data: Data) throws {
    guard var q = base(account) else { throw VaultError.invalidConfig(AppModel.insecureMessage) }
    SecItemDelete(q as CFDictionary)
    q[kSecValueData as String] = data
    q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    q[kSecAttrLabel as String] = "keydillo: iPhone approval"
    let s = SecItemAdd(q as CFDictionary, nil)
    guard s == errSecSuccess else { throw VaultError.keychain(s) }
  }

  static func accounts() -> [String] {
    guard var q = base(nil) else { return [] }
    q[kSecReturnAttributes as String] = true
    q[kSecMatchLimit as String] = kSecMatchLimitAll
    var out: CFTypeRef?
    guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [[String: Any]] else { return [] }
    return items.compactMap { $0[kSecAttrAccount as String] as? String }
  }

  static func deleteCopies() {
    for a in accounts() where a.hasPrefix("wrapped:") { if let q = base(a) { SecItemDelete(q as CFDictionary) } }
  }
}

// MARK: Settings UI

struct PhoneSettingsSection: View {
  @Environment(AppModel.self) private var model
  @State private var pairing = false
  @State private var tick = 0
  private var link: PhoneApprovals { PhoneApprovals.shared }

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("iPhone").font(.system(size: 13, weight: .medium))
      if link.transport == nil {
        Text(link.transportNote).font(.system(size: 12)).foregroundStyle(Theme.secondary)
      } else if let phone = link.phone {
        let _ = tick
        Text("Requests also go to \(phone.name). Approve with Face ID there or Touch ID here, whichever comes first. \(link.copiedKeys.count) keys ready.")
          .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        Button("Unpair") { link.unpair(); tick += 1 }.buttonStyle(SmallButtonStyle(destructive: true))
      } else {
        Text("Approve requests from your iPhone with Face ID when you're away from this Mac.")
          .font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
        Button("Pair iPhone…") { pairing = true }.buttonStyle(SmallButtonStyle())
      }
    }
    .sheet(isPresented: $pairing, onDismiss: { tick += 1 }) { PairPhoneView { pairing = false } }
  }
}

struct PairPhoneView: View {
  @Environment(AppModel.self) private var model
  var close: () -> Void
  @State private var offer: PairingOffer?
  @State private var phone: PairedPhone?
  @State private var status = "Open keydillo on your iPhone and scan this code."
  @State private var done = false
  @State private var waiter: Task<Void, Never>?

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Pair iPhone").font(.system(size: 20, weight: .semibold))
      if let offer, phone == nil {
        if let img = Self.qr(offer.code) {
          Image(nsImage: img).interpolation(.none).resizable().frame(width: 220, height: 220).frame(maxWidth: .infinity)
        }
        Button("Copy code instead") {
          NSPasteboard.general.clearContents(); NSPasteboard.general.setString(offer.code, forType: .string)
        }.buttonStyle(SmallButtonStyle())
      }
      if let phone, !done {
        Text("\(phone.name) wants to approve requests for this Mac. keydillo will keep a copy of each key that only that phone can unlock.")
          .font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
      }
      Text(status).font(.system(size: 12)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
      HStack {
        Spacer()
        Button(done ? "Done" : "Cancel") { waiter?.cancel(); close() }.buttonStyle(SecondaryButtonStyle())
        if let phone, !done {
          Button("Pair with Touch ID") { Task { await finish(phone) } }.buttonStyle(PrimaryButtonStyle())
        }
      }
    }
    .padding(24).frame(width: 420).background(Theme.background).foregroundStyle(Theme.text)
    .onAppear(perform: start)
    .onDisappear { waiter?.cancel() }
  }

  func start() {
    do { offer = try PhoneApprovals.shared.makeOffer() } catch { status = "Couldn't start pairing: \(error)"; return }
    guard let offer else { return }
    waiter = Task {
      do {
        guard let p = try await PhoneApprovals.shared.waitForPhone(offer) else {
          if !Task.isCancelled { status = "The code expired. Close this and try again." }
          return
        }
        phone = p
        status = "Check that this is your phone, then confirm."
      } catch {
        status = "Pairing failed: \(error)"
      }
    }
  }

  func finish(_ phone: PairedPhone) async {
    guard let ctx = await model.authenticate("let \(phone.name) approve keydillo requests for this Mac") else { return }
    do {
      let n = try PhoneApprovals.shared.finishPairing(phone, context: ctx, services: model.services, keychain: model.keychain)
      status = "Paired. \(n) keys can now be approved from \(phone.name)."
      done = true
    } catch { status = "Pairing failed: \(error)" }
  }

  static func qr(_ s: String) -> NSImage? {
    let f = CIFilter.qrCodeGenerator()
    f.message = Data(s.utf8)
    f.correctionLevel = "M"
    guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
    let rep = NSCIImageRep(ciImage: out)
    let img = NSImage(size: rep.size)
    img.addRepresentation(rep)
    return img
  }
}
