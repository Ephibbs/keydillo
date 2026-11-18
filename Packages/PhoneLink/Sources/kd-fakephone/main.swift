// A pretend iPhone for trying the Mac side without a phone. Software keys, folder transport. Never shipped.
//
//   kd-fakephone <folder> pair '<kdpair1:...>'     pair with the code the Mac shows
//   kd-fakephone <folder> list                     show pending requests (verified)
//   kd-fakephone <folder> approve|deny [id]        answer one request (the oldest if no id)
//   kd-fakephone <folder> watch approve|deny       answer every request as it arrives
import Foundation
import PhoneLink

struct State: Codable { var phoneID: String; var sign: Data; var agree: Data; var mac: PairedMac? }

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: kd-fakephone <folder> pair <code> | list | approve [id] | deny [id] | watch approve|deny"); exit(2) }
let dir = URL(fileURLWithPath: args[1])
let transport = FolderTransport(dir)
let stateURL = dir.appendingPathComponent("fakephone-state.json")
var state = (try? JSONDecoder().decode(State.self, from: Data(contentsOf: stateURL))) ?? {
  State(phoneID: UUID().uuidString, sign: SoftwareSigner().raw, agree: SoftwareAgreement().raw, mac: nil)
}()
func save() { try? JSONEncoder().encode(state).write(to: stateURL) }
let signer = try SoftwareSigner(raw: state.sign)
let agreement = try SoftwareAgreement(raw: state.agree)

func verified(_ mac: PairedMac?) async -> [ApprovalAsk] {
  guard let mac else { print("not paired"); exit(1) }
  return ((try? await transport.pendingAsks()) ?? []).filter {
    do { try $0.verify(from: mac); return true } catch { print("  skipped \($0.requestID): \(error)"); return false }
  }
}

func answer(_ ask: ApprovalAsk, _ d: Decision, phoneID: String) async throws {
  try await transport.post(answer: try ApprovalAnswer.make(for: ask, decision: d, phoneID: phoneID, signer: signer, agreement: agreement))
  print("\(d.rawValue)d: \(ask.title) [\(ask.method) \(ask.host)\(ask.path)]")
}

switch args[2] {
case "pair":
  let offer = try PairingOffer.parse(args[3])
  try await transport.post(pairingReply: try PairingReply.make(for: offer, phoneID: state.phoneID, phoneName: "Fake iPhone", signer: signer, agreement: agreement))
  state.mac = PairedMac(macID: offer.macID, name: offer.macName, signingKey: offer.macSigningKey)
  save()
  print("paired with \(offer.macName)")
case "list":
  for a in await verified(state.mac) { print("\(a.requestID)  \(a.title)  \(a.method) \(a.host)\(a.path)  from \(a.requester) in \(a.folder)  (\(a.secondsLeft)s left)") }
case "approve", "deny":
  let d = Decision(rawValue: args[2])!
  let asks = await verified(state.mac)
  guard let ask = args.count > 3 ? asks.first(where: { $0.requestID == args[3] }) : asks.first else { print("no pending request"); exit(1) }
  try await answer(ask, d, phoneID: state.phoneID)
case "watch":
  let d = Decision(rawValue: args.count > 3 ? args[3] : "approve") ?? .approve
  var done = Set<String>()
  print("watching \(dir.path), will \(d.rawValue) everything")
  while true {
    for a in await verified(state.mac) where !done.contains(a.requestID) { done.insert(a.requestID); try? await answer(a, d, phoneID: state.phoneID) }
    try await Task.sleep(nanoseconds: 500_000_000)
  }
default:
  print("unknown command"); exit(2)
}
