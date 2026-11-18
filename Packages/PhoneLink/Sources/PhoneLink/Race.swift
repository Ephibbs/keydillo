import Foundation

/// The result of asking on the Mac (Touch ID) and the phone at once.
public enum RaceResult: Equatable {
  case mac(approved: Bool)
  case phone(PendingAsk.Outcome)
  /// The phone didn't answer before the ask expired, and there was no prompt on the Mac.
  case timedOut
}

/// Runs the Mac prompt (if any) and waits for the phone; the first answer wins and the other is cancelled.
/// Answers that fail verification are logged and ignored, so a forged record can't end the wait early.
public func raceApproval(mac: (@Sendable () async -> Bool)?, cancelMac: @escaping @Sendable () -> Void,
                         pending: PendingAsk, phone: PairedPhone, transport: LinkTransport,
                         pollEvery: TimeInterval = 1.5, log: @escaping @Sendable (String) -> Void = { _ in }) async -> RaceResult {
  do { try await transport.post(ask: pending.ask) } catch {
    log("phone link: couldn't send the request (\(error))")
    if let mac { return .mac(approved: await mac()) }
    return .timedOut
  }
  let hasMac = mac != nil
  let result: RaceResult = await withTaskGroup(of: RaceResult?.self) { group in
    if let mac { group.addTask { .mac(approved: await mac()) } }
    group.addTask {
      while !Task.isCancelled && epoch() <= pending.ask.expires {
        if let a = try? await transport.answer(for: pending.ask.requestID) {
          do { return .phone(try pending.accept(a, from: phone)) } catch LinkError.replayed { return nil }
          catch { log("phone link: ignored an answer (\(error))") }
        }
        try? await Task.sleep(nanoseconds: UInt64(pollEvery * 1_000_000_000))
      }
      // With a prompt still open on the Mac, the phone timing out isn't an answer: keep waiting for the Mac.
      return Task.isCancelled || hasMac ? nil : .timedOut
    }
    var winner: RaceResult?
    for await r in group {
      guard let r else { continue }
      // The Mac prompt ending on its own because the phone already won comes back as a denial; ignore it.
      if winner == nil {
        winner = r
        if case .phone = r { cancelMac() }
        group.cancelAll()
      }
    }
    return winner ?? .timedOut
  }
  try? await transport.remove(requestID: pending.ask.requestID)
  return result
}
