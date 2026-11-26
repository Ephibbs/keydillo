// A pretend Mac for trying the iPhone app (in the simulator, over a folder) without the real keydillo. Never shipped.
//
//   kd-fakemac <folder> pair      print a pairing code, wait for the phone, save it
//   kd-fakemac <folder> ask       send one request for a dummy key and wait for the answer
//   kd-fakemac <folder> handoff <image.jpg>   start a browser hand-off, stream the image, print taps and typing until done
import Foundation
import PhoneLink

struct State: Codable { var macID: String; var key: Data; var phone: PairedPhone? }
let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: kd-fakemac <folder> pair | ask"); exit(2) }
let dir = URL(fileURLWithPath: args[1])
let transport = FolderTransport(dir)
let stateURL = dir.appendingPathComponent("fakemac-state.json")
let state = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))) ?? State(macID: UUID().uuidString, key: SoftwareSigner().raw)
let signer = try SoftwareSigner(raw: state.key)
func save(_ s: State) { try? JSONEncoder().encode(s).write(to: stateURL) }

switch args[2] {
case "handoff":
  guard let phone = state.phone, args.count >= 4, let jpeg = try? Data(contentsOf: URL(fileURLWithPath: args[3])) else { print("usage: kd-fakemac <folder> handoff <image.jpg> (after pair)"); exit(1) }
  let host = try HandoffHost(title: "Claude needs you on github.com: Enter the code GitHub emailed you", url: "https://github.com/sessions/verified-device",
                             macID: state.macID, phone: phone, signer: signer, transport: transport)
  try await host.post()
  print("started \(host.start.sessionID); waiting for the phone")
  while !(await host.checkJoin()) { try await Task.sleep(nanoseconds: 500_000_000) }
  print("phone joined")
  while true {
    try await host.send(jpeg: jpeg, width: 1280, height: 800, url: host.start.url)
    for i in await host.newInputs() {
      print("input \(i.seq): \(i.action.rawValue) \(i.x.map { String(format: "x=%.2f", $0) } ?? "") \(i.y.map { String(format: "y=%.2f", $0) } ?? "") \(i.text ?? "")")
      if i.action == .done || i.action == .cancel { await host.end(); exit(0) }
    }
    try await Task.sleep(nanoseconds: 1_000_000_000)
  }
case "pair":
  let offer = PairingOffer(macID: state.macID, macName: "Test Mac", macSigningKey: signer.publicKey)
  try offer.code.write(to: dir.appendingPathComponent("pairing-code.txt"), atomically: true, encoding: .utf8)
  print(offer.code)
  while epoch() <= offer.expires {
    if let r = try await transport.pairingReply(macID: offer.macID) {
      var s = state; s.phone = try r.verify(against: offer); save(s)
      try await transport.removePairingReply(macID: offer.macID)
      print("paired with \(r.phoneName)"); exit(0)
    }
    try await Task.sleep(nanoseconds: 500_000_000)
  }
  print("expired"); exit(1)
case "ask":
  guard let phone = state.phone else { print("not paired"); exit(1) }
  let secret = Data("dummy-\(Int.random(in: 1000...9999))".utf8)
  let wrapped = try WrappedSecret.wrap(secret, service: "example", for: phone)
  let pending = try PendingAsk.make(.init(title: "Claude Code wants to use your Example key", service: "example", displayName: "Example",
                                          host: "api.example.com", method: "POST", path: "/v1/messages", requester: "Claude Code",
                                          folder: "~/Desktop/demo", purpose: "Generating voiceover for the demo video"), macID: state.macID, signer: signer, wrapped: wrapped)
  print("asked \(pending.ask.requestID), expecting \(String(decoding: secret, as: UTF8.self)) back on approval")
  let r = await raceApproval(mac: nil, cancelMac: {}, pending: pending, phone: phone, transport: transport, pollEvery: 0.5, log: { print($0) })
  switch r {
  case .phone(.approved(let s, let scope)): print("APPROVED (\(scope)), released value: \(s.map { String(decoding: $0, as: UTF8.self) } ?? "none")")
  case .phone(.denied): print("DENIED")
  default: print("no answer: \(r)")
  }
default: print("unknown command"); exit(2)
}
