import XCTest
@testable import PhoneLink

final class HandoffTests: XCTestCase {
  let macKey = SoftwareSigner()
  let phoneSign = SoftwareSigner()
  let phoneAgree = SoftwareAgreement()

  func pair() throws -> (PairedPhone, PairedMac) {
    let offer = PairingOffer(macID: "mac-1", macName: "Mac", macSigningKey: macKey.publicKey)
    let reply = try PairingReply.make(for: offer, phoneID: "phone-1", phoneName: "iPhone", signer: phoneSign, agreement: phoneAgree)
    return (try reply.verify(against: offer), PairedMac(macID: "mac-1", name: "Mac", signingKey: macKey.publicKey))
  }

  func folder() -> FolderTransport {
    FolderTransport(FileManager.default.temporaryDirectory.appendingPathComponent("kd-handoff-\(UUID().uuidString)"))
  }

  func testFullHandoff() async throws {
    let (phone, mac) = try pair()
    let t = folder()
    let host = try HandoffHost(title: "Solve the captcha on github.com", url: "https://github.com/login", macID: "mac-1",
                               phone: phone, signer: macKey, transport: t)
    try await host.post()
    let pending = try await t.pendingHandoffs()
    XCTAssertEqual(pending.map(\.title), ["Solve the captcha on github.com"])

    let viewer = try await HandoffViewer(start: pending[0], mac: mac, phoneID: "phone-1", signer: phoneSign, transport: t)
    let joined = await host.checkJoin()
    XCTAssertTrue(joined)

    try await host.send(jpeg: Data("frame-1".utf8), width: 800, height: 600, url: "https://github.com/login")
    let f1 = try await viewer.nextFrame()
    XCTAssertEqual(f1?.0, Data("frame-1".utf8)); XCTAssertEqual(f1?.1, 800)
    let again = try await viewer.nextFrame()
    XCTAssertNil(again, "same frame shown twice")

    try await viewer.send(.tap, x: 0.5, y: 0.25)
    try await viewer.send(.text, text: "123456")
    let inputs = await host.newInputs()
    XCTAssertEqual(inputs.map(\.action), [.tap, .text]); XCTAssertEqual(inputs[0].x, 0.5); XCTAssertEqual(inputs[1].text, "123456")
    let none = await host.newInputs()
    XCTAssertTrue(none.isEmpty, "inputs returned twice")

    try await viewer.send(.done)
    let done = await host.newInputs()
    XCTAssertEqual(done.map(\.action), [.done])
    await host.end()
    let left = try await t.pendingHandoffs()
    XCTAssertTrue(left.isEmpty)
  }

  func testDirectLinkCarriesFramesAndInputsAndStillChecksThem() async throws {
    let (phone, mac) = try pair()
    let t = folder()
    let host = try HandoffHost(title: "Drag the shapes", url: "https://accounts.hcaptcha.com/demo", macID: "mac-1", phone: phone, signer: macKey, transport: t)
    try await host.post()
    let viewer = try await HandoffViewer(start: try await t.pendingHandoffs()[0], mac: mac, phoneID: "phone-1", signer: phoneSign, transport: t)
    _ = await host.checkJoin()
    let (macEnd, phoneEnd) = LoopbackDirect.pair()
    host.useDirect(macEnd); viewer.useDirect(phoneEnd)
    XCTAssertTrue(host.isDirect)

    try await host.send(jpeg: Data("fast-frame".utf8), width: 420, height: 300, url: "u")
    let cloudFrame = try await t.latestFrame(for: host.start.sessionID)
    XCTAssertNil(cloudFrame, "frame went over iCloud while linked")
    let f = try await viewer.nextFrame()
    XCTAssertEqual(f?.0, Data("fast-frame".utf8))

    try await viewer.send(.down, x: 0.1, y: 0.5)
    try await viewer.send(.move, x: 0.5, y: 0.5)
    try await viewer.send(.up, x: 0.9, y: 0.5)
    let got = await host.newInputs()
    XCTAssertEqual(got.map(\.action), [.down, .move, .up])

    // Something else on the network sends an input not signed by the phone's session key: dropped.
    let forged = try HandoffInput.make(.tap, session: host.start.sessionID, seq: 99, x: 0.5, y: 0.5, signer: SoftwareSigner())
    phoneEnd.send(try JSONEncoder().encode(DirectMessage.input(forged)))
    let none = await host.newInputs()
    XCTAssertTrue(none.isEmpty, "forged direct input accepted")

    // Link drops: back to iCloud.
    macEnd.stop()
    XCTAssertFalse(host.isDirect)
    try await host.send(jpeg: Data("slow-frame".utf8), width: 420, height: 300, url: "u")
    let slow = try await viewer.nextFrame()
    XCTAssertEqual(slow?.0, Data("slow-frame".utf8))
  }

  func testForgedStartRejectedByPhone() async throws {
    let (_, mac) = try pair()
    let t = folder()
    let fake = try HandoffStart.make(title: "Type your password here", url: "https://evil.example", macID: "mac-1", signer: SoftwareSigner())
    do {
      _ = try await HandoffViewer(start: fake, mac: mac, phoneID: "phone-1", signer: phoneSign, transport: t)
      XCTFail("forged start accepted")
    } catch { XCTAssertEqual(error as? LinkError, .badSignature) }
  }

  func testJoinFromOtherPhoneIgnored() async throws {
    let (phone, mac) = try pair()
    let t = folder()
    let host = try HandoffHost(title: "x", url: "https://a.example", macID: "mac-1", phone: phone, signer: macKey, transport: t)
    try await host.post()
    _ = try await HandoffViewer(start: host.start, mac: mac, phoneID: "phone-1", signer: SoftwareSigner(), transport: t)
    let joined = await host.checkJoin()
    XCTAssertFalse(joined, "a join not signed by the paired phone was accepted")
  }

  func testForgedInputDropped() async throws {
    let (phone, mac) = try pair()
    let t = folder()
    let host = try HandoffHost(title: "x", url: "https://a.example", macID: "mac-1", phone: phone, signer: macKey, transport: t)
    try await host.post()
    let viewer = try await HandoffViewer(start: host.start, mac: mac, phoneID: "phone-1", signer: phoneSign, transport: t)
    _ = await host.checkJoin()
    try await t.post(input: try HandoffInput.make(.text, session: host.start.sessionID, seq: 1, text: "evil", signer: SoftwareSigner()))
    try await viewer.send(.text, text: "real")   // seq 1 too, but the forged file was written first and replaced
    let got = await host.newInputs()
    XCTAssertEqual(got.map(\.text), ["real"])
  }

  func testFrameOnlyOpensWithSessionKey() async throws {
    let (phone, mac) = try pair()
    let t = folder()
    let host = try HandoffHost(title: "x", url: "https://a.example", macID: "mac-1", phone: phone, signer: macKey, transport: t)
    try await host.post()
    _ = try await HandoffViewer(start: host.start, mac: mac, phoneID: "phone-1", signer: phoneSign, transport: t)
    _ = await host.checkJoin()
    try await host.send(jpeg: Data("secret page".utf8), width: 1, height: 1, url: "u")
    let frame = try await t.latestFrame(for: host.start.sessionID)!
    XCTAssertThrowsError(try frame.open(from: mac, with: SoftwareAgreement()))
    XCTAssertThrowsError(try frame.open(from: mac, with: phoneAgree), "paired key shouldn't open a session frame")
  }
}

final class HandoffDragPathTests: XCTestCase {
  func testParsesAValidPath() {
    let p = handoffDragPoints("0.1,0.5;0.5,0.5;0.9,0.5")
    XCTAssertEqual(p?.count, 3)
    XCTAssertEqual(p?.last?.0, 0.9)
  }
  func testRejectsBadPaths() {
    XCTAssertNil(handoffDragPoints(nil))
    XCTAssertNil(handoffDragPoints("0.1,0.5"))                 // one point
    XCTAssertNil(handoffDragPoints("0.1,0.5;1.2,0.5"))         // off the frame
    XCTAssertNil(handoffDragPoints("0.1,0.5;x,0.5"))           // not a number
    XCTAssertNil(handoffDragPoints(Array(repeating: "0.5,0.5", count: 65).joined(separator: ";")))
  }
}
