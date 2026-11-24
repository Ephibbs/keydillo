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
                   extra: ["title": ask.notificationText as CKRecordValue, "expires": Date(timeIntervalSince1970: TimeInterval(ask.expires)) as CKRecordValue])
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
    _ = try await db.modifySubscriptions(saving: [sub], deleting: [])
  }
}
#endif
