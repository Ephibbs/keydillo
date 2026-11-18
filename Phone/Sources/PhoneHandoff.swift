import Foundation
import Observation
import PhoneLink
import SwiftUI
import UIKit

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
            .buttonStyle(.borderedProminent)
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
          GeometryReader { geo in
            let fit = fitted(handoffs.frameSize, in: geo.size)
            Image(uiImage: img).resizable().scaledToFit()
              .frame(width: fit.width, height: fit.height)
              .position(x: geo.size.width / 2, y: geo.size.height / 2)
              .contentShape(Rectangle())
              .onTapGesture(coordinateSpace: .local) { p in
                handoffs.send(.tap, x: min(max(p.x / fit.width, 0), 1), y: min(max(p.y / fit.height, 0), 1))
              }
          }
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
        Text("Tap the page to click. Claude can't see what you type here.").font(.footnote).foregroundStyle(.secondary)
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

  func fitted(_ size: CGSize, in box: CGSize) -> CGSize {
    let s = min(box.width / size.width, box.height / size.height)
    return CGSize(width: size.width * s, height: size.height * s)
  }
}
