import Foundation
import CryptoKit
#if canImport(MultipeerConnectivity)
import MultipeerConnectivity
#endif

/// A fast, direct pipe between the Mac and the phone for one hand-off: frames one way, taps and drags the other.
/// iCloud still starts the hand-off and carries it when the phone isn't near the Mac.
///
/// The pipe adds speed, not trust: every frame is still sealed to the phone's session key and signed by the Mac,
/// and every input is still signed by the phone's session key, exactly as over iCloud. Something else on the
/// network that connects gets nothing it can read and can't send anything the other side will accept.
public protocol HandoffDirect: AnyObject, Sendable {
  var isConnected: Bool { get }
  /// Best effort; dropped if not connected.
  func send(_ data: Data)
  func setReceiver(_ receive: @escaping @Sendable (Data) -> Void)
  func stop()
}

/// What travels over the direct pipe.
enum DirectMessage: Codable {
  case frame(HandoffFrame)
  case input(HandoffInput)
}

/// The name both sides look for: derived from the session, so the session ID itself is never broadcast.
func directTag(_ sessionID: String) -> String {
  SHA256.hash(data: Data("kd-direct-v1|\(sessionID)".utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
}

#if canImport(MultipeerConnectivity)
/// Multipeer Connectivity: same Wi-Fi, or peer-to-peer Wi-Fi and Bluetooth when there's no shared network.
/// The Mac advertises the session's tag; the phone looks for it and connects.
public final class MultipeerDirect: NSObject, HandoffDirect, MCSessionDelegate, MCNearbyServiceAdvertiserDelegate,
  MCNearbyServiceBrowserDelegate, @unchecked Sendable {
  public static let serviceType = "kd-handoff"
  public enum Role { case mac, phone }

  private let role: Role
  private let tag: String
  private let peer: MCPeerID
  private let session: MCSession
  private var advertiser: MCNearbyServiceAdvertiser?
  private var browser: MCNearbyServiceBrowser?
  private var receive: (@Sendable (Data) -> Void)?
  private let lock = NSLock()

  public init(role: Role, sessionID: String, name: String) {
    self.role = role
    tag = directTag(sessionID)
    peer = MCPeerID(displayName: String(name.prefix(40)))
    session = MCSession(peer: peer, securityIdentity: nil, encryptionPreference: .required)
    super.init()
    session.delegate = self
    switch role {
    case .mac:
      let a = MCNearbyServiceAdvertiser(peer: peer, discoveryInfo: ["s": tag], serviceType: Self.serviceType)
      a.delegate = self; a.startAdvertisingPeer(); advertiser = a
    case .phone:
      let b = MCNearbyServiceBrowser(peer: peer, serviceType: Self.serviceType)
      b.delegate = self; b.startBrowsingForPeers(); browser = b
    }
  }

  public var isConnected: Bool { !session.connectedPeers.isEmpty }

  public func send(_ data: Data) {
    let peers = session.connectedPeers
    guard !peers.isEmpty else { return }
    try? session.send(data, toPeers: peers, with: .reliable)
  }

  public func setReceiver(_ receive: @escaping @Sendable (Data) -> Void) { lock.withLock { self.receive = receive } }

  public func stop() {
    advertiser?.stopAdvertisingPeer(); browser?.stopBrowsingForPeers()
    session.disconnect()
  }

  // Mac: only the phone that names this session's tag is let in; only one at a time.
  public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                         withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
    let ok = context.map { String(decoding: $0, as: UTF8.self) } == tag && session.connectedPeers.isEmpty
    invitationHandler(ok, ok ? session : nil)
  }

  // Phone: connect to the Mac advertising this session's tag.
  public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID, withDiscoveryInfo info: [String: String]?) {
    guard info?["s"] == tag, session.connectedPeers.isEmpty else { return }
    browser.invitePeer(peerID, to: session, withContext: Data(tag.utf8), timeout: 10)
  }
  public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {}

  public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
    let r = lock.withLock { receive }
    r?(data)
  }
  public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
    // Phone: if the link drops, look for the Mac again.
    if state == .notConnected, role == .phone, session.connectedPeers.isEmpty {
      browser?.stopBrowsingForPeers(); browser?.startBrowsingForPeers()
    }
  }
  public func session(_ session: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
  public func session(_ session: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
  public func session(_ session: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}
#endif

/// An in-memory pair of pipes, for tests.
public final class LoopbackDirect: HandoffDirect, @unchecked Sendable {
  public weak var other: LoopbackDirect?
  private var receive: (@Sendable (Data) -> Void)?
  public var connected = true
  public init() {}
  public static func pair() -> (LoopbackDirect, LoopbackDirect) {
    let a = LoopbackDirect(), b = LoopbackDirect(); a.other = b; b.other = a; return (a, b)
  }
  public var isConnected: Bool { connected && other?.connected == true }
  public func send(_ data: Data) { guard isConnected else { return }; other?.receive?(data) }
  public func setReceiver(_ receive: @escaping @Sendable (Data) -> Void) { self.receive = receive }
  public func stop() { connected = false }
}
