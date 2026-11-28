import Foundation
import Observation
import PhoneLink
import SwiftUI
import UIKit
import UserNotifications

/// Hand-offs from the Mac's browser: "Claude needs you on github.com: Enter the code GitHub emailed you".
/// The page streams here; taps and typing go back to the Mac's browser. Claude never sees either.
@MainActor
@Observable
final class HandoffStore {
  static let shared = HandoffStore()

  private(set) var pending: [HandoffStart] = []
  var open: HandoffStart?
  private(set) var frame: UIImage?
  private(set) var frameSize = CGSize(width: 1, height: 1)
  var message: String?
  private var viewer: HandoffViewer?
  private var polling: Task<Void, Never>?

  var transport: HandoffTransport? { PhoneStore.shared.transport as? HandoffTransport }

  func refresh() async {
    guard let mac = PhoneStore.shared.mac, let transport else { return }
    let all = (try? await transport.pendingHandoffs()) ?? []
    pending = all.filter { (try? $0.verify(from: mac)) != nil }
    await notifyNew()
  }

  /// When iCloud only wakes the app (no direct alerts), the app shows the notification itself, once per hand-off.
  private func notifyNew() async {
    guard case .silent = PhoneStore.shared.pushMode, UIApplication.shared.applicationState != .active else { return }
    let d = UserDefaults.standard
    var seen = d.stringArray(forKey: "notifiedHandoffs") ?? []
    for h in pending where !seen.contains(h.sessionID) {
      let c = UNMutableNotificationContent()
      c.title = "keydillo browser"
      c.body = h.title
      c.sound = .default
      c.interruptionLevel = .timeSensitive
      try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "handoff-" + h.sessionID, content: c, trigger: nil))
      seen.append(h.sessionID)
    }
    d.set(Array(seen.suffix(100)), forKey: "notifiedHandoffs")
  }

  /// One Face ID: the phone's paired key signs this session's keys.
  func join(_ start: HandoffStart) async {
    guard let mac = PhoneStore.shared.mac, let transport else { return }
    do {
      let keys = try await PhoneKeys.unlock(reason: "Open: \(start.title)")
      viewer = try await HandoffViewer(start: start, mac: mac, phoneID: PhoneStore.shared.phoneIdentifier, signer: keys.signer, transport: transport)
      frame = nil
      open = start
      polling?.cancel()
      polling = Task { [weak self] in
        while !Task.isCancelled {
          await self?.pull()
          try? await Task.sleep(nanoseconds: 700_000_000)
        }
      }
    } catch {
      message = "Couldn't open it: \(PhoneStore.describe(error))"
    }
  }

  private func pull() async {
    guard let viewer, let f = try? await viewer.nextFrame(), let img = UIImage(data: f.0) else { return }
    frame = img
    frameSize = CGSize(width: max(f.1, 1), height: max(f.2, 1))
  }

  func send(_ action: HandoffAction, x: Double? = nil, y: Double? = nil, text: String? = nil) {
    guard let viewer else { return }
    Task { try? await viewer.send(action, x: x, y: y, text: text) }
  }

  func close(_ action: HandoffAction) {
    send(action)
    polling?.cancel(); polling = nil
    viewer = nil; open = nil; frame = nil
    pending.removeAll()
  }
}

struct HandoffSection: View {
  @State private var handoffs = HandoffStore.shared
  var body: some View {
    ForEach(handoffs.pending) { h in
      Section {
        VStack(alignment: .leading, spacing: 8) {
          Text(h.title).font(.headline)
          Text(URL(string: h.url)?.host ?? h.url).font(.subheadline).foregroundStyle(.secondary)
          Button { Task { await handoffs.join(h) } } label: { Text("Open browser").frame(maxWidth: .infinity) }
            .buttonStyle(PillButton(primary: true))
        }
        .padding(.vertical, 6)
      }
    }
    .fullScreenCover(item: $handoffs.open) { _ in HandoffSessionView() }
  }
}

struct HandoffSessionView: View {
  @State private var handoffs = HandoffStore.shared
  @State private var typed = ""

  var body: some View {
    NavigationStack {
      VStack(spacing: 12) {
        if let img = handoffs.frame {
          // Pinch to zoom and drag to pan; double-tap zooms in or back out. A tap clicks the page there.
          ZoomableFrame(image: img, pageSize: handoffs.frameSize) { x, y in handoffs.send(.tap, x: x, y: y) }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
          Spacer()
          ProgressView("Waiting for the page…")
          Spacer()
        }
        HStack {
          TextField("Type into the page", text: $typed).textFieldStyle(.roundedBorder)
            .textInputAutocapitalization(.never).autocorrectionDisabled()
          Button("Send") { handoffs.send(.text, text: typed); typed = "" }.disabled(typed.isEmpty)
          Button("Enter") { handoffs.send(.key, text: "Enter") }
        }
        Text("Tap the page to click. Pinch to zoom. Claude can't see what you type here.").font(.footnote).foregroundStyle(.secondary)
      }
      .padding()
      .navigationTitle(handoffs.open?.title ?? "")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) { Button("Cancel") { handoffs.close(.cancel) } }
        ToolbarItem(placement: .confirmationAction) { Button("Done") { handoffs.close(.done) } }
      }
    }
  }

}

/// The streamed page in a scroll view: fits the screen at first, pinch up to 6×, double-tap to zoom. Taps are
/// reported as fractions of the page image, so zoom doesn't change where they land.
struct ZoomableFrame: UIViewRepresentable {
  let image: UIImage
  let pageSize: CGSize
  let onTap: (Double, Double) -> Void

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> UIScrollView {
    let scroll = UIScrollView()
    scroll.delegate = context.coordinator
    scroll.maximumZoomScale = 6
    scroll.showsHorizontalScrollIndicator = false
    scroll.showsVerticalScrollIndicator = false
    scroll.backgroundColor = .clear
    scroll.contentInsetAdjustmentBehavior = .never
    let iv = context.coordinator.imageView
    iv.isUserInteractionEnabled = true
    scroll.addSubview(iv)
    let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
    double.numberOfTapsRequired = 2
    let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
    single.require(toFail: double)
    iv.addGestureRecognizer(double)
    iv.addGestureRecognizer(single)
    context.coordinator.scroll = scroll
    return scroll
  }

  func updateUIView(_ scroll: UIScrollView, context: Context) {
    let c = context.coordinator
    c.onTap = onTap
    c.imageView.image = image
    c.layout(page: pageSize, in: scroll)
  }

  final class Coordinator: NSObject, UIScrollViewDelegate {
    let imageView = UIImageView()
    weak var scroll: UIScrollView?
    var onTap: (Double, Double) -> Void = { _, _ in }
    private var laidOut: (CGSize, CGSize)?

    /// Sizes the image to fit the screen at zoom 1. Only when the page size or the screen changes, so a new frame
    /// every second doesn't reset the user's zoom.
    func layout(page: CGSize, in scroll: UIScrollView) {
      let box = scroll.bounds.size
      guard box.width > 0, page.width > 0, page.height > 0 else { return }
      if let l = laidOut, l.0 == page, l.1 == box { return }
      laidOut = (page, box)
      scroll.zoomScale = 1
      let s = min(box.width / page.width, box.height / page.height)
      imageView.frame = CGRect(x: 0, y: 0, width: page.width * s, height: page.height * s)
      scroll.contentSize = imageView.frame.size
      center(scroll)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { imageView }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { center(scrollView) }

    private func center(_ scroll: UIScrollView) {
      let f = imageView.frame.size, b = scroll.bounds.size
      scroll.contentInset = UIEdgeInsets(top: max(0, (b.height - f.height) / 2), left: max(0, (b.width - f.width) / 2), bottom: 0, right: 0)
    }

    @objc func tap(_ g: UITapGestureRecognizer) {
      let p = g.location(in: imageView), size = imageView.bounds.size
      guard size.width > 0, size.height > 0 else { return }
      onTap(min(max(p.x / size.width, 0), 1), min(max(p.y / size.height, 0), 1))
    }

    @objc func doubleTap(_ g: UITapGestureRecognizer) {
      guard let scroll else { return }
      if scroll.zoomScale > 1.01 { scroll.setZoomScale(1, animated: true); return }
      let p = g.location(in: imageView), w = imageView.bounds.width / 2.5, h = imageView.bounds.height / 2.5
      scroll.zoom(to: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), animated: true)
    }
  }
}
