#if canImport(CloudKit)
import Foundation
import CloudKit

/// Asks and answers as records in a custom zone of the user's own private CloudKit database.
/// No keydillo server: the records live in the user's iCloud and Apple pushes changes to the phone.
///
/// Records (each holds one JSON `payload`):
/// - `KDAsk` "ask-<id>": written by the Mac. `title` is copied out so the push notification can show it.
/// - `KDAnswer` "ans-<id>": written by the phone.
/// - `KDPairReply` "pair-<macID>": written by the phone while pairing.
///
/// Needs the app to be signed with the iCloud (CloudKit) entitlement for `containerID`; creating a
/// `CKContainer` without it crashes, so callers check `CloudKitTransport.isEntitled` first on the Mac.
public final class CloudKitTransport: LinkTransport, @unchecked Sendable {
  public static let defaultContainer = "iCloud.com.studiokillswitch.keydillo"
  public static let zoneID = CKRecordZone.ID(zoneName: "keydillo", ownerName: CKCurrentUserDefaultName)
  public static let askSubscriptionID = "kd-asks"

  let db: CKDatabase
  private var zoneReady = false

  public init(containerID: String = CloudKitTransport.defaultContainer) {
    db = CKContainer(identifier: containerID).privateCloudDatabase
  }

  func ensureZone() async throws {
    if zoneReady { return }
    _ = try await db.modifyRecordZones(saving: [CKRecordZone(zoneID: Self.zoneID)], deleting: [])
    zoneReady = true
  }

  func id(_ name: String) -> CKRecord.ID { CKRecord.ID(recordName: name, zoneID: Self.zoneID) }

  func save(_ type: String, _ name: String, _ payload: Data, extra: [String: CKRecordValue] = [:]) async throws {
    try await ensureZone()
    let r = CKRecord(recordType: type, recordID: id(name))
    r["payload"] = payload as CKRecordValue
    for (k, v) in extra { r[k] = v }
    _ = try await db.modifyRecords(saving: [r], deleting: [], savePolicy: .allKeys)
  }

  func fetch<T: Decodable>(_ t: T.Type, _ name: String) async throws -> T? {
    do {
      let r = try await db.record(for: id(name))
      guard let d = r["payload"] as? Data else { return nil }
      return try JSONDecoder().decode(t, from: d)
    } catch let e as CKError where e.code == .unknownItem || e.code == .zoneNotFound {
      return nil
    }
  }

  func delete(_ names: [String]) async throws {
    _ = try? await db.modifyRecords(saving: [], deleting: names.map(id))
  }

  public func post(ask: ApprovalAsk) async throws {
    try await save("KDAsk", "ask-\(ask.requestID)", try JSONEncoder().encode(ask),
                   extra: ["title": ask.title as CKRecordValue, "expires": Date(timeIntervalSince1970: TimeInterval(ask.expires)) as CKRecordValue])
  }
  public func answer(for requestID: String) async throws -> ApprovalAnswer? { try await fetch(ApprovalAnswer.self, "ans-\(requestID)") }
  public func post(answer: ApprovalAnswer) async throws { try await save("KDAnswer", "ans-\(answer.requestID)", try JSONEncoder().encode(answer)) }
  public func remove(requestID: String) async throws { try await delete(["ask-\(requestID)", "ans-\(requestID)"]) }
  public func post(pairingReply: PairingReply) async throws {
    try await save("KDPairReply", "pair-\(pairingReply.macID)", try JSONEncoder().encode(pairingReply))
  }
  public func pairingReply(macID: String) async throws -> PairingReply? { try await fetch(PairingReply.self, "pair-\(macID)") }
  public func removePairingReply(macID: String) async throws { try await delete(["pair-\(macID)"]) }

  /// Every ask in the zone. Uses zone changes rather than a query, so no CloudKit indexes are needed.
  public func pendingAsks() async throws -> [ApprovalAsk] {
    try await ensureZone()
    var token: CKServerChangeToken?
    var asks: [ApprovalAsk] = []
    while true {
      let r = try await db.recordZoneChanges(inZoneWith: Self.zoneID, since: token)
      for (_, result) in r.modificationResultsByID {
        guard let rec = try? result.get().record, rec.recordType == "KDAsk", let d = rec["payload"] as? Data,
              let ask = try? JSONDecoder().decode(ApprovalAsk.self, from: d) else { continue }
        asks.append(ask)
      }
      token = r.changeToken
      if !r.moreComing { break }
    }
    return asks.sorted { $0.created < $1.created }
  }

  /// Every record of one type in the zone (zone changes, so no CloudKit indexes are needed).
  func all<T: Decodable>(_ type: String, _ t: T.Type, prefix: String = "") async throws -> [T] {
    try await ensureZone()
    var token: CKServerChangeToken?
    var out: [T] = []
    while true {
      let r = try await db.recordZoneChanges(inZoneWith: Self.zoneID, since: token)
      for (rid, result) in r.modificationResultsByID where rid.recordName.hasPrefix(prefix) {
        guard let rec = try? result.get().record, rec.recordType == type, let d = rec["payload"] as? Data,
              let v = try? JSONDecoder().decode(T.self, from: d) else { continue }
        out.append(v)
      }
      token = r.changeToken
      if !r.moreComing { break }
    }
    return out
  }

  /// Phone only: a push notification for every new ask, with the Mac's title as the text.
  /// Creates and deletes a placeholder record first, because the development environment only lets you
  /// subscribe to a record type that already exists.
  public func subscribeToAsks() async throws {
    try await ensureZone()
    let probe = "ask-schema-probe"
    try? await save("KDAsk", probe, Data(), extra: ["title": "" as CKRecordValue, "expires": Date() as CKRecordValue])
    try? await save("KDAnswer", "ans-schema-probe", Data())
    try? await save("KDPairReply", "pair-schema-probe", Data())
    try await delete([probe, "ans-schema-probe", "pair-schema-probe"])

    let sub = CKQuerySubscription(recordType: "KDAsk", predicate: NSPredicate(value: true), subscriptionID: Self.askSubscriptionID,
                                  options: [.firesOnRecordCreation])
    sub.zoneID = Self.zoneID
    let info = CKSubscription.NotificationInfo()
    info.titleLocalizationKey = "KD_ASK_TITLE"
    info.alertLocalizationKey = "KD_ASK_BODY"
    info.alertLocalizationArgs = ["title"]
    info.soundName = "default"
    info.shouldSendContentAvailable = true
    info.desiredKeys = ["title"]
    info.category = "KD_ASK"
    sub.notificationInfo = info
    // Hand-offs: "Claude needs you in the browser".
    try? await save("KDHandoff", "handoff-schema-probe", Data(), extra: ["title": "" as CKRecordValue])
    for (t, n) in [("KDHJoin", "hjoin-schema-probe"), ("KDHFrame", "hframe-schema-probe"), ("KDHInput", "hinput-schema-probe")] { try? await save(t, n, Data()) }
    try await delete(["handoff-schema-probe", "hjoin-schema-probe", "hframe-schema-probe", "hinput-schema-probe"])
    let hsub = CKQuerySubscription(recordType: "KDHandoff", predicate: NSPredicate(value: true), subscriptionID: Self.handoffSubscriptionID,
                                   options: [.firesOnRecordCreation])
    hsub.zoneID = Self.zoneID
    let hinfo = CKSubscription.NotificationInfo()
    hinfo.titleLocalizationKey = "KD_HANDOFF_TITLE"
    hinfo.alertLocalizationKey = "KD_ASK_BODY"
    hinfo.alertLocalizationArgs = ["title"]
    hinfo.soundName = "default"
    hinfo.shouldSendContentAvailable = true
    hinfo.desiredKeys = ["title"]
    hinfo.category = "KD_HANDOFF"
    hsub.notificationInfo = hinfo
    _ = try await db.modifySubscriptions(saving: [sub, hsub], deleting: [])
  }
}

extension CloudKitTransport: HandoffTransport {
  public static let handoffSubscriptionID = "kd-handoffs"
  public func post(handoff: HandoffStart) async throws {
    try await save("KDHandoff", "handoff-\(handoff.sessionID)", try JSONEncoder().encode(handoff), extra: ["title": handoff.title as CKRecordValue])
  }
  public func pendingHandoffs() async throws -> [HandoffStart] { try await all("KDHandoff", HandoffStart.self, prefix: "handoff-").sorted { $0.created < $1.created } }
  public func post(join: HandoffJoin) async throws { try await save("KDHJoin", "hjoin-\(join.sessionID)", try JSONEncoder().encode(join)) }
  public func join(for sessionID: String) async throws -> HandoffJoin? { try await fetch(HandoffJoin.self, "hjoin-\(sessionID)") }
  public func post(frame: HandoffFrame) async throws { try await save("KDHFrame", "hframe-\(frame.sessionID)", try JSONEncoder().encode(frame)) }
  public func latestFrame(for sessionID: String) async throws -> HandoffFrame? { try await fetch(HandoffFrame.self, "hframe-\(sessionID)") }
  public func post(input: HandoffInput) async throws { try await save("KDHInput", "hinput-\(input.sessionID)-\(input.seq)", try JSONEncoder().encode(input)) }
  public func inputs(for sessionID: String) async throws -> [HandoffInput] { try await all("KDHInput", HandoffInput.self, prefix: "hinput-\(sessionID)-") }
  public func removeHandoff(_ sessionID: String) async throws {
    var names = ["handoff-\(sessionID)", "hjoin-\(sessionID)", "hframe-\(sessionID)"]
    names += (try? await inputs(for: sessionID))?.map { "hinput-\(sessionID)-\($0.seq)" } ?? []
    try await delete(names)
  }
}
#endif
