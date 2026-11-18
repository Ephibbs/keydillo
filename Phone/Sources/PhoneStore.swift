import Foundation
import Observation
import PhoneLink
import UIKit

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
      if let ck = transport as? CloudKitTransport { try? await ck.subscribeToAsks() }
    } catch {
      message = "Couldn't pair: \(Self.describe(error))"
    }
  }

  func unpair() {
    UserDefaults.standard.removeObject(forKey: "pairedMac")
    PhoneKeys.delete()
    mac = nil; asks = []; answered = []
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

  func answer(_ ask: ApprovalAsk, _ decision: Decision) async {
    guard let mac else { return }
    busy = true; defer { busy = false }
    do {
      try ask.verify(from: mac)
      let verb = decision == .approve ? "Approve" : "Deny"
      let keys = try await PhoneKeys.unlock(reason: "\(verb): \(ask.title)")
      let a = try ApprovalAnswer.make(for: ask, decision: decision, phoneID: phoneID, signer: keys.signer, agreement: keys.agreement)
      try await transport.post(answer: a)
      answered.insert(ask.requestID)
      message = decision == .approve ? "Approved. \(mac.name) is sending the request." : "Denied."
    } catch {
      message = "Couldn't answer: \(Self.describe(error))"
    }
  }

  static func describe(_ error: Error) -> String {
    if let e = error as? LinkError { return e.description }
    return error.localizedDescription
  }
}
