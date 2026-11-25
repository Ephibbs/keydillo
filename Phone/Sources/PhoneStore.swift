import Foundation
import Observation
import PhoneLink
import UIKit
import UserNotifications

/// The phone's state: which Mac it's paired with, and the requests waiting for an answer.
@MainActor
@Observable
final class PhoneStore {
  static let shared = PhoneStore()

  private(set) var mac: PairedMac?
  private(set) var asks: [ApprovalAsk] = []
  private(set) var answered: Set<String> = []
  var message: String?
  var busy = false
  /// Shown on the requests screen when request notifications can't work, with the reason.
  var notificationProblem: String?
  var notificationsDenied = false
  var pushRegistered = false
  private var subscribed = false
  private var subscribing = false
  private(set) var pushMode: CloudKitTransport.PushMode?

  let transport: LinkTransport
  let transportNote: String
  private let phoneID: String

  private init() {
    let d = UserDefaults.standard
    if let id = d.string(forKey: "phoneID") { phoneID = id } else { phoneID = UUID().uuidString; d.set(phoneID, forKey: "phoneID") }
    mac = d.data(forKey: "pairedMac").flatMap { try? JSONDecoder().decode(PairedMac.self, from: $0) }
    // Simulator tests can use a folder on the Mac instead of iCloud (the simulator shares the Mac's disk):
    //   SIMCTL_CHILD_KEYDILLO_PHONE_FOLDER=/path xcrun simctl launch booted com.studiokillswitch.keydillo.phone
    if let f = ProcessInfo.processInfo.environment["KEYDILLO_PHONE_FOLDER"], !f.isEmpty {
      transport = FolderTransport(URL(fileURLWithPath: f)); transportNote = "Test folder"
    } else {
      transport = CloudKitTransport(); transportNote = "iCloud"
    }
    #if DEBUG && targetEnvironment(simulator)
    // Simulator tests: pair from a code file written by kd-fakemac.
    if mac == nil, let f = ProcessInfo.processInfo.environment["KEYDILLO_PAIR_CODE_FILE"], let code = try? String(contentsOfFile: f, encoding: .utf8) {
      Task { await self.pair(code: code) }
    }
    #endif
  }

  var waiting: [ApprovalAsk] { asks.filter { !answered.contains($0.requestID) && $0.secondsLeft > 0 } }

  // MARK: Pairing

  func pair(code: String) async {
    busy = true; defer { busy = false }
    message = nil
    do {
      let offer = try PairingOffer.parse(code)
      let keys = try await PhoneKeys.unlock(reason: "Pair with \(offer.macName)", create: true)
      let reply = try PairingReply.make(for: offer, phoneID: phoneID, phoneName: UIDevice.current.name,
                                        signer: keys.signer, agreement: keys.agreement)
      try await transport.post(pairingReply: reply)
      let m = PairedMac(macID: offer.macID, name: offer.macName, signingKey: offer.macSigningKey)
      UserDefaults.standard.set(try JSONEncoder().encode(m), forKey: "pairedMac")
      mac = m
      message = "Now confirm with Touch ID on \(offer.macName)."
      await ensureSubscription()
    } catch {
      message = "Couldn't pair: \(Self.describe(error))"
    }
  }

  /// Makes sure iCloud will push a notification for each new request. Runs on every launch and return to the app,
  /// since a failed attempt at pairing (offline, iCloud busy) would otherwise leave the phone silent for good.
  func ensureSubscription() async {
    guard mac != nil else { return }
    let settings = await UNUserNotificationCenter.current().notificationSettings()
    notificationsDenied = settings.authorizationStatus == .denied
    if notificationsDenied {
      notificationProblem = "Notifications for keydillo are turned off. Turn them on in Settings to hear about requests when the app is closed."
      return
    }
    guard !subscribed, !subscribing, let ck = transport as? CloudKitTransport else {
      if subscribed { notificationProblem = nil }
      return
    }
    subscribing = true; defer { subscribing = false }
    do {
      pushMode = try await ck.subscribeToAsks()
      subscribed = true
      notificationProblem = nil
    } catch {
      notificationProblem = "Couldn't set up request notifications with iCloud: \(Self.describe(error))"
    }
  }

  /// With a silent subscription iCloud only wakes the app, so the app shows the notification itself,
  /// once per request. Not while the app is open: the card is already on screen.
  func notifyNewAsks() async {
    guard case .silent = pushMode, UIApplication.shared.applicationState != .active else { return }
    let d = UserDefaults.standard
    var seen = d.stringArray(forKey: "notifiedAsks") ?? []
    for ask in waiting where !seen.contains(ask.requestID) {
      let c = UNMutableNotificationContent()
      c.title = "keydillo"
      c.body = ask.notificationText
      c.sound = .default
      c.interruptionLevel = .timeSensitive
      try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: ask.requestID, content: c, trigger: nil))
      seen.append(ask.requestID)
    }
    d.set(Array(seen.suffix(200)), forKey: "notifiedAsks")
    // Clear notifications for requests that were answered or closed on the Mac.
    let live = Set(waiting.map(\.requestID))
    let delivered = await UNUserNotificationCenter.current().deliveredNotifications().map(\.request.identifier)
    UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: delivered.filter { !live.contains($0) && $0.count == 36 })
  }

  func unpair() {
    UserDefaults.standard.removeObject(forKey: "pairedMac")
    PhoneKeys.delete()
    mac = nil; asks = []; answered = []; subscribed = false; notificationProblem = nil
  }

  // MARK: Requests

  /// Reads waiting requests and keeps only those signed by the paired Mac and not expired.
  func refresh() async {
    guard let mac else { return }
    do {
      let all = try await transport.pendingAsks()
      asks = all.filter { (try? $0.verify(from: mac)) != nil }
      if message?.hasPrefix("Couldn't load") == true || (message?.hasPrefix("Now confirm") == true && !asks.isEmpty) { message = nil }
    } catch {
      message = "Couldn't load requests: \(Self.describe(error))"
    }
  }

  func answer(_ ask: ApprovalAsk, _ decision: Decision, scope: AnswerScope = .once) async {
    guard let mac else { return }
    busy = true; defer { busy = false }
    do {
      try ask.verify(from: mac)
      let verb = decision == .approve ? "Approve" : "Deny"
      let wide = decision == .approve && scope == .session
      let keys = try await PhoneKeys.unlock(reason: wide ? "Approve for this session: \(ask.title)" : "\(verb): \(ask.title)")
      let a = try ApprovalAnswer.make(for: ask, decision: decision, scope: scope, phoneID: phoneID, signer: keys.signer, agreement: keys.agreement)
      try await transport.post(answer: a)
      answered.insert(ask.requestID)
      message = decision == .deny ? "Denied." : wide ? "Approved for this session. \(mac.name) won't ask again for this key until \(ask.requester) quits."
        : "Approved. \(mac.name) is sending the request."
    } catch {
      message = "Couldn't answer: \(Self.describe(error))"
    }
  }

  static func describe(_ error: Error) -> String {
    if let e = error as? LinkError { return e.description }
    return error.localizedDescription
  }
}
