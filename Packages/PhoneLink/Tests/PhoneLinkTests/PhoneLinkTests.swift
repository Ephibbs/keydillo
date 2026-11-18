import XCTest
@testable import PhoneLink

final class PhoneLinkTests: XCTestCase {
  // A Mac and a phone with software keys.
  let macKey = SoftwareSigner()
  let phoneSign = SoftwareSigner()
  let phoneAgree = SoftwareAgreement()
  let secret = Data("sk-test-1234567890".utf8)

  func pair() throws -> (PairingOffer, PairedPhone, PairedMac) {
    let offer = PairingOffer(macID: "mac-1", macName: "Evan's MacBook", macSigningKey: macKey.publicKey)
    let code = offer.code
    let parsed = try PairingOffer.parse(code)
    XCTAssertEqual(parsed, offer)
    let reply = try PairingReply.make(for: parsed, phoneID: "phone-1", phoneName: "iPhone", signer: phoneSign, agreement: phoneAgree)
    let phone = try reply.verify(against: offer)
    return (offer, phone, PairedMac(macID: parsed.macID, name: parsed.macName, signingKey: parsed.macSigningKey))
  }

  func fields(_ title: String = "Claude Code wants to use your OpenAI key") -> PendingAsk.Fields {
    .init(title: title, service: "openai", displayName: "OpenAI", host: "api.openai.com", method: "POST", path: "/v1/chat/completions",
          requester: "Claude Code", folder: "~/Desktop/app")
  }

  func testPairing() throws {
    let (_, phone, mac) = try pair()
    XCTAssertEqual(phone.signingKey, phoneSign.publicKey)
    XCTAssertEqual(phone.agreementKey, phoneAgree.publicKey)
    XCTAssertEqual(mac.signingKey, macKey.publicKey)
  }

  func testPairingRejectsWrongSecretAndExpiry() throws {
    let offer = PairingOffer(macID: "mac-1", macName: "Mac", macSigningKey: macKey.publicKey)
    var other = offer; other.pairingSecret = randomBytes(32)
    let reply = try PairingReply.make(for: other, phoneID: "p", phoneName: "x", signer: phoneSign, agreement: phoneAgree)
    XCTAssertThrowsError(try reply.verify(against: offer)) { XCTAssertEqual($0 as? LinkError, .badPairingCode) }

    let old = PairingOffer(macID: "mac-1", macName: "Mac", macSigningKey: macKey.publicKey, ttl: 60, now: Date().addingTimeInterval(-600))
    XCTAssertThrowsError(try PairingReply.make(for: old, phoneID: "p", phoneName: "x", signer: phoneSign, agreement: phoneAgree))
    XCTAssertThrowsError(try PairingOffer.parse("kdpair1:garbage"))
  }

  func testPairingReplyKeySwapRejected() throws {
    let offer = PairingOffer(macID: "mac-1", macName: "Mac", macSigningKey: macKey.publicKey)
    var reply = try PairingReply.make(for: offer, phoneID: "p", phoneName: "x", signer: phoneSign, agreement: phoneAgree)
    reply.phoneAgreementKey = SoftwareAgreement().publicKey
    XCTAssertThrowsError(try reply.verify(against: offer))
  }

  func testApproveReleasesSecret() throws {
    let (_, phone, mac) = try pair()
    let wrapped = try WrappedSecret.wrap(secret, service: "openai", for: phone)
    let pending = try PendingAsk.make(fields(), macID: "mac-1", signer: macKey, wrapped: wrapped)
    try pending.ask.verify(from: mac)
    let answer = try ApprovalAnswer.make(for: pending.ask, decision: .approve, phoneID: phone.phoneID, signer: phoneSign, agreement: phoneAgree)
    XCTAssertNotNil(answer.release)
    XCTAssertEqual(try pending.accept(answer, from: phone), .approved(secret: secret))
  }

  func testWrappedCopyNeedsThePhone() throws {
    let (_, phone, _) = try pair()
    let wrapped = try WrappedSecret.wrap(secret, service: "openai", for: phone)
    XCTAssertFalse(wrapped.box.range(of: secret) != nil)
    XCTAssertThrowsError(try wrapped.sealedDataKey.open(with: SoftwareAgreement(), info: WrappedSecret.wrapInfo("openai")))
    // The phone's key opens it only under the right service name.
    XCTAssertThrowsError(try wrapped.sealedDataKey.open(with: phoneAgree, info: WrappedSecret.wrapInfo("stripe")))
    XCTAssertNoThrow(try wrapped.sealedDataKey.open(with: phoneAgree, info: WrappedSecret.wrapInfo("openai")))
  }

  func testDeny() throws {
    let (_, phone, _) = try pair()
    let pending = try PendingAsk.make(fields(), macID: "mac-1", signer: macKey, wrapped: try WrappedSecret.wrap(secret, service: "openai", for: phone))
    let answer = try ApprovalAnswer.make(for: pending.ask, decision: .deny, phoneID: phone.phoneID, signer: phoneSign, agreement: phoneAgree)
    XCTAssertNil(answer.release)
    XCTAssertEqual(try pending.accept(answer, from: phone), .denied)
  }

  func testTamperedAskRejectedOnPhone() throws {
    let (_, _, mac) = try pair()
    let pending = try PendingAsk.make(fields(), macID: "mac-1", signer: macKey, wrapped: nil)
    var ask = pending.ask
    ask.title = "Approve this harmless thing"
    XCTAssertThrowsError(try ask.verify(from: mac)) { XCTAssertEqual($0 as? LinkError, .badSignature) }
    var forged = try PendingAsk.make(fields(), macID: "mac-1", signer: SoftwareSigner(), wrapped: nil).ask
    XCTAssertThrowsError(try forged.verify(from: mac)) { XCTAssertEqual($0 as? LinkError, .badSignature) }
    forged.macID = "mac-2"
    XCTAssertThrowsError(try forged.verify(from: mac)) { XCTAssertEqual($0 as? LinkError, .wrongMac) }
  }

  func testExpiredAskRejectedOnPhoneAndMac() throws {
    let (_, phone, mac) = try pair()
    let pending = try PendingAsk.make(fields(), macID: "mac-1", signer: macKey, wrapped: nil, ttl: 30, now: Date().addingTimeInterval(-60))
    XCTAssertThrowsError(try pending.ask.verify(from: mac)) { XCTAssertEqual($0 as? LinkError, .expired) }
    let answer = try ApprovalAnswer.make(for: pending.ask, decision: .approve, phoneID: phone.phoneID, signer: phoneSign, agreement: phoneAgree)
    XCTAssertThrowsError(try pending.accept(answer, from: phone)) { XCTAssertEqual($0 as? LinkError, .expired) }
  }

  func testReplayAndCrossRequestRejected() throws {
    let (_, phone, _) = try pair()
    let a = try PendingAsk.make(fields(), macID: "mac-1", signer: macKey, wrapped: try WrappedSecret.wrap(secret, service: "openai", for: phone))
    let b = try PendingAsk.make(fields(), macID: "mac-1", signer: macKey, wrapped: try WrappedSecret.wrap(secret, service: "openai", for: phone))
    let answerA = try ApprovalAnswer.make(for: a.ask, decision: .approve, phoneID: phone.phoneID, signer: phoneSign, agreement: phoneAgree)
    // An answer for A can't approve B, even with B's ID pasted in.
    XCTAssertThrowsError(try b.accept(answerA, from: phone)) { XCTAssertEqual($0 as? LinkError, .wrongRequest) }
    var moved = answerA; moved.requestID = b.ask.requestID
    XCTAssertThrowsError(try b.accept(moved, from: phone)) { XCTAssertEqual($0 as? LinkError, .badSignature) }
    // Used once only.
    XCTAssertNoThrow(try a.accept(answerA, from: phone))
    XCTAssertThrowsError(try a.accept(answerA, from: phone)) { XCTAssertEqual($0 as? LinkError, .replayed) }
  }

  func testAnswerToChangedAskRejected() throws {
    let (_, phone, _) = try pair()
    let pending = try PendingAsk.make(fields(), macID: "mac-1", signer: macKey, wrapped: nil)
    var shown = pending.ask
    shown.title = "something else"   // what an attacker showed the phone
    let answer = try ApprovalAnswer.make(for: shown, decision: .approve, phoneID: phone.phoneID, signer: phoneSign, agreement: phoneAgree)
    XCTAssertThrowsError(try pending.accept(answer, from: phone)) { XCTAssertEqual($0 as? LinkError, .askChanged) }
  }

  func testOtherPhoneRejected() throws {
    let (_, phone, _) = try pair()
    let pending = try PendingAsk.make(fields(), macID: "mac-1", signer: macKey, wrapped: nil)
    let answer = try ApprovalAnswer.make(for: pending.ask, decision: .approve, phoneID: phone.phoneID, signer: SoftwareSigner(), agreement: phoneAgree)
    XCTAssertThrowsError(try pending.accept(answer, from: phone)) { XCTAssertEqual($0 as? LinkError, .badSignature) }
    var other = answer; other.phoneID = "phone-2"
    XCTAssertThrowsError(try pending.accept(other, from: phone)) { XCTAssertEqual($0 as? LinkError, .wrongPhone) }
  }

  func testReleaseSealedToThisRequestOnly() throws {
    // A release for one request can't be opened with another request's response key.
    let (_, phone, _) = try pair()
    let w = try WrappedSecret.wrap(secret, service: "openai", for: phone)
    let a = try PendingAsk.make(fields(), macID: "mac-1", signer: macKey, wrapped: w)
    let b = try PendingAsk.make(fields(), macID: "mac-1", signer: macKey, wrapped: w)
    let answerA = try ApprovalAnswer.make(for: a.ask, decision: .approve, phoneID: phone.phoneID, signer: phoneSign, agreement: phoneAgree)
    XCTAssertThrowsError(try answerA.release!.open(with: b.responseKey, info: ApprovalAnswer.releaseInfo(b.ask.requestID)))
  }

  // MARK: Race over a folder transport

  func tempTransport() -> FolderTransport {
    FolderTransport(FileManager.default.temporaryDirectory.appendingPathComponent("phonelink-\(UUID().uuidString)"))
  }

  func testRacePhoneWinsAndCancelsMacPrompt() async throws {
    let (_, phone, mac) = try pair()
    let t = tempTransport()
    let pending = try PendingAsk.make(fields(), macID: "mac-1", signer: macKey, wrapped: try WrappedSecret.wrap(secret, service: "openai", for: phone))
    let cancelled = Flag()
    let phoneTask = Task {
      try await Task.sleep(nanoseconds: 300_000_000)
      let ask = try await t.pendingAsks().first!
      try ask.verify(from: mac)
      try await t.post(answer: try ApprovalAnswer.make(for: ask, decision: .approve, phoneID: "phone-1", signer: self.phoneSign, agreement: self.phoneAgree))
    }
    let r = await raceApproval(mac: {
      // Stands in for the Touch ID sheet: returns false once cancelled, like LAContext.invalidate().
      for _ in 0..<100 { if cancelled.value { return false }; try? await Task.sleep(nanoseconds: 50_000_000) }
      return true
    }, cancelMac: { cancelled.value = true }, pending: pending, phone: phone, transport: t, pollEvery: 0.1)
    try await phoneTask.value
    XCTAssertEqual(r, .phone(.approved(secret: secret)))
    XCTAssertTrue(cancelled.value)
    let left = try await t.pendingAsks()
    XCTAssertTrue(left.isEmpty, "records are cleaned up")
  }

  func testRaceMacWins() async throws {
    let (_, phone, _) = try pair()
    let t = tempTransport()
    let pending = try PendingAsk.make(fields(), macID: "mac-1", signer: macKey, wrapped: nil)
    let r = await raceApproval(mac: { try? await Task.sleep(nanoseconds: 200_000_000); return true }, cancelMac: {},
                               pending: pending, phone: phone, transport: t, pollEvery: 0.1)
    XCTAssertEqual(r, .mac(approved: true))
  }

  func testRaceIgnoresForgedAnswerThenAcceptsReal() async throws {
    let (_, phone, _) = try pair()
    let t = tempTransport()
    let pending = try PendingAsk.make(fields(), macID: "mac-1", signer: macKey, wrapped: nil)
    let attacker = SoftwareSigner()
    let task = Task {
      try await Task.sleep(nanoseconds: 200_000_000)
      try await t.post(answer: try ApprovalAnswer.make(for: pending.ask, decision: .approve, phoneID: "phone-1", signer: attacker, agreement: SoftwareAgreement()))
      try await Task.sleep(nanoseconds: 400_000_000)
      try await t.post(answer: try ApprovalAnswer.make(for: pending.ask, decision: .deny, phoneID: "phone-1", signer: self.phoneSign, agreement: self.phoneAgree))
    }
    let r = await raceApproval(mac: nil, cancelMac: {}, pending: pending, phone: phone, transport: t, pollEvery: 0.1)
    try await task.value
    XCTAssertEqual(r, .phone(.denied))
  }

  func testRaceTimesOutWithoutMac() async throws {
    let (_, phone, _) = try pair()
    let t = tempTransport()
    let pending = try PendingAsk.make(fields(), macID: "mac-1", signer: macKey, wrapped: nil, ttl: 1)
    let r = await raceApproval(mac: nil, cancelMac: {}, pending: pending, phone: phone, transport: t, pollEvery: 0.2)
    XCTAssertEqual(r, .timedOut)
  }

  func testPhoneTimeoutDoesNotOverrideOpenMacPrompt() async throws {
    let (_, phone, _) = try pair()
    let t = tempTransport()
    let pending = try PendingAsk.make(fields(), macID: "mac-1", signer: macKey, wrapped: nil, ttl: 1)
    let r = await raceApproval(mac: { try? await Task.sleep(nanoseconds: 2_500_000_000); return true }, cancelMac: {},
                               pending: pending, phone: phone, transport: t, pollEvery: 0.2)
    XCTAssertEqual(r, .mac(approved: true))
  }
}

final class Flag: @unchecked Sendable {
  private let l = NSLock(); private var v = false
  var value: Bool { get { l.lock(); defer { l.unlock() }; return v } set { l.lock(); v = newValue; l.unlock() } }
}
