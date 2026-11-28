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
  /// Linked straight to the Mac (fast), rather than through iCloud.
  private(set) var direct = false
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
      let v = try await HandoffViewer(start: start, mac: mac, phoneID: PhoneStore.shared.phoneIdentifier, signer: keys.signer, transport: transport)
      // Fast path when the Mac is nearby; iCloud otherwise.
      v.useDirect(MultipeerDirect(role: .phone, sessionID: start.sessionID, name: UIDevice.current.name))
      viewer = v
      frame = nil
      open = start
      polling?.cancel()
      polling = Task { [weak self] in
        while !Task.isCancelled {
          await self?.pull()
          let fast = await MainActor.run { self?.viewer?.isDirect == true }
          await MainActor.run { self?.direct = fast }
          try? await Task.sleep(nanoseconds: fast ? 33_000_000 : 700_000_000)
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

  private var sending: Task<Void, Never>?
  /// One at a time, in order: a drag's press must reach the Mac before its moves.
  func send(_ action: HandoffAction, x: Double? = nil, y: Double? = nil, text: String? = nil) {
    guard let viewer else { return }
    let previous = sending
    sending = Task { _ = await previous?.value; try? await viewer.send(action, x: x, y: y, text: text) }
  }

  func close(_ action: HandoffAction) {
    send(action)
    polling?.cancel(); polling = nil
    let v = viewer
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { v?.stopDirect() } // let Done reach the Mac first
    viewer = nil; open = nil; frame = nil; direct = false
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
          ZoomableFrame(image: img, pageSize: handoffs.frameSize,
                        live: { handoffs.direct },
                        onTap: { x, y in handoffs.send(.tap, x: x, y: y) },
                        onDrag: { path in handoffs.send(.drag, text: path) },
                        onLive: { action, x, y in handoffs.send(action, x: x, y: y) })
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
        Text((handoffs.direct ? "Live, straight from your Mac. " : "Through iCloud, so it updates slowly. ") + "Tap to click, drag with one finger. Two fingers to zoom and move around. Claude can't see what you type here.").font(.footnote).foregroundStyle(.secondary)
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

/// The streamed page in a scroll view: fits the screen at first, pinch up to 6×, double-tap to zoom. One finger taps
/// and drags on the page (drag puzzles); two fingers pan. Positions are fractions of the page image, so zoom doesn't
/// change where they land.
struct ZoomableFrame: UIViewRepresentable {
  let image: UIImage
  let pageSize: CGSize
  let live: () -> Bool
  let onTap: (Double, Double) -> Void
  let onDrag: (String) -> Void
  let onLive: (HandoffAction, Double, Double) -> Void

  func makeCoordinator() -> Coordinator { Coordinator() }

  func makeUIView(context: Context) -> UIScrollView {
    let scroll = UIScrollView()
    scroll.delegate = context.coordinator
    scroll.maximumZoomScale = 6
    scroll.showsHorizontalScrollIndicator = false
    scroll.showsVerticalScrollIndicator = false
    scroll.backgroundColor = .clear
    scroll.contentInsetAdjustmentBehavior = .never
    scroll.panGestureRecognizer.minimumNumberOfTouches = 2 // one finger is for the page
    let iv = context.coordinator.imageView
    iv.isUserInteractionEnabled = true
    scroll.addSubview(iv)
    let double = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.doubleTap(_:)))
    double.numberOfTapsRequired = 2
    let single = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
    single.require(toFail: double)
    let drag = UIPanGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.drag(_:)))
    drag.maximumNumberOfTouches = 1
    iv.addGestureRecognizer(double)
    iv.addGestureRecognizer(single)
    iv.addGestureRecognizer(drag)
    context.coordinator.trail.strokeColor = UIColor.systemBlue.withAlphaComponent(0.7).cgColor
    context.coordinator.trail.fillColor = UIColor.clear.cgColor
    context.coordinator.trail.lineWidth = 3
    context.coordinator.trail.lineCap = .round
    iv.layer.addSublayer(context.coordinator.trail)
    context.coordinator.scroll = scroll
    return scroll
  }

  func updateUIView(_ scroll: UIScrollView, context: Context) {
    let c = context.coordinator
    c.onTap = onTap
    c.onDrag = onDrag
    c.onLive = onLive
    c.live = live
    c.imageView.image = image
    c.layout(page: pageSize, in: scroll)
  }

  final class Coordinator: NSObject, UIScrollViewDelegate {
    let imageView = UIImageView()
    weak var scroll: UIScrollView?
    var onTap: (Double, Double) -> Void = { _, _ in }
    var onDrag: (String) -> Void = { _ in }
    var onLive: (HandoffAction, Double, Double) -> Void = { _, _, _ in }
    var live: () -> Bool = { false }
    private var liveDrag = false
    private var lastMove = Date.distantPast
    let trail = CAShapeLayer()       // shows the finger's path until the page catches up
    private var points: [CGPoint] = []
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

    /// Records the path in the image's own space and sends it as one drag when the finger lifts.
    @objc func drag(_ g: UIPanGestureRecognizer) {
      let size = imageView.bounds.size
      guard size.width > 0, size.height > 0 else { return }
      let p = g.location(in: imageView)
      let fx = { (q: CGPoint) in min(max(q.x / size.width, 0), 1) }, fy = { (q: CGPoint) in min(max(q.y / size.height, 0), 1) }
      // Linked directly: the Mac presses, follows and releases as the finger moves.
      if g.state == .began { liveDrag = live() }
      if liveDrag {
        switch g.state {
        case .began:
          let s0 = CGPoint(x: p.x - g.translation(in: imageView).x, y: p.y - g.translation(in: imageView).y)
          onLive(.down, fx(s0), fy(s0)); onLive(.move, fx(p), fy(p)); points = [s0, p]
        case .changed:
          if Date().timeIntervalSince(lastMove) > 0.03 { onLive(.move, fx(p), fy(p)); lastMove = Date() }
          points.append(p)
        case .ended, .cancelled, .failed:
          onLive(.up, fx(p), fy(p)); points = []
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in self?.trail.path = nil }
          return
        default: return
        }
        let line = UIBezierPath()
        for (i, q) in points.enumerated() { i == 0 ? line.move(to: q) : line.addLine(to: q) }
        trail.path = line.cgPath
        return
      }
      switch g.state {
      case .began:
        points = [CGPoint(x: p.x - g.translation(in: imageView).x, y: p.y - g.translation(in: imageView).y), p]
      case .changed:
        if let last = points.last, hypot(last.x - p.x, last.y - p.y) > 3 { points.append(p) }
      case .ended:
        points.append(p)
        // At most 64 points: keep the start, the end and an even spread between.
        let step = max(1, Int(ceil(Double(points.count) / 60)))
        var kept = stride(from: 0, to: points.count, by: step).map { points[$0] }
        if kept.last != points.last { kept.append(points.last!) }
        let path = kept.map { String(format: "%.4f,%.4f", min(max($0.x / size.width, 0), 1), min(max($0.y / size.height, 0), 1)) }.joined(separator: ";")
        if kept.count >= 2 { onDrag(path) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in self?.trail.path = nil }
        return
      default:
        points = []; trail.path = nil; return
      }
      let line = UIBezierPath()
      for (i, q) in points.enumerated() { i == 0 ? line.move(to: q) : line.addLine(to: q) }
      trail.path = line.cgPath
    }

    @objc func doubleTap(_ g: UITapGestureRecognizer) {
      guard let scroll else { return }
      if scroll.zoomScale > 1.01 { scroll.setZoomScale(1, animated: true); return }
      let p = g.location(in: imageView), w = imageView.bounds.width / 2.5, h = imageView.bounds.height / 2.5
      scroll.zoom(to: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h), animated: true)
    }
  }
}
