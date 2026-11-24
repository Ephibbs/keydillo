import PhoneLink
import SwiftUI
import UIKit
import UserNotifications
import VisionKit

@main
struct KeydilloPhoneApp: App {
  @UIApplicationDelegateAdaptor(AppDelegate.self) var delegate
  @Environment(\.scenePhase) private var phase
  @State private var store = PhoneStore.shared

  var body: some Scene {
    WindowGroup {
      RootView().environment(store)
        .onChange(of: phase) { _, p in
          if p == .active { Task { await store.refresh(); await store.ensureSubscription() } }
        }
    }
  }
}

final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
  func application(_ app: UIApplication, didFinishLaunchingWithOptions opts: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in
      DispatchQueue.main.async { UIApplication.shared.registerForRemoteNotifications() }
    }
    app.registerForRemoteNotifications()
    return true
  }

  func application(_ app: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken token: Data) {
    Task { @MainActor in PhoneStore.shared.pushRegistered = true; await PhoneStore.shared.ensureSubscription() }
  }

  func application(_ app: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
    Task { @MainActor in PhoneStore.shared.notificationProblem = "Push registration failed: \(error.localizedDescription)" }
  }

  // A new request arrived (CloudKit push).
  func application(_ app: UIApplication, didReceiveRemoteNotification info: [AnyHashable: Any]) async -> UIBackgroundFetchResult {
    await PhoneStore.shared.refresh()
    await PhoneStore.shared.ensureSubscription()
    await PhoneStore.shared.notifyNewAsks()
    return .newData
  }

  func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification) async -> UNNotificationPresentationOptions {
    await PhoneStore.shared.refresh()
    return [.banner, .sound]
  }

  func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive r: UNNotificationResponse) async {
    await PhoneStore.shared.refresh()
  }
}

// MARK: Screens

struct RootView: View {
  @Environment(PhoneStore.self) private var store
  var body: some View {
    NavigationStack {
      Group {
        if store.mac == nil { PairView() } else { RequestsView() }
      }
      .background(Color(.systemBackground))
    }
    .tint(.primary)
  }
}

struct PairView: View {
  @Environment(PhoneStore.self) private var store
  @State private var scanning = false
  @State private var pasting = false
  @State private var code = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 20) {
      Spacer()
      Text("keydillo").font(.system(size: 34, weight: .semibold))
      Text("Approve your Mac's key requests with Face ID when you're away from it. Your keys stay on the Mac.")
        .font(.body).foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 8) {
        Label("On your Mac, open keydillo Settings", systemImage: "1.circle")
        Label("Click Pair iPhone", systemImage: "2.circle")
        Label("Scan the code it shows", systemImage: "3.circle")
      }
      .font(.subheadline)
      Spacer()
      if let m = store.message { Text(m).font(.footnote).foregroundStyle(.secondary) }
      Button { scanning = true } label: { Text("Scan pairing code").frame(maxWidth: .infinity) }
        .buttonStyle(PillButton(primary: true)).disabled(store.busy || !Scanner.supported)
      Button { pasting = true } label: { Text("Paste code").frame(maxWidth: .infinity) }
        .buttonStyle(PillButton(primary: false)).disabled(store.busy)
    }
    .padding(24)
    .sheet(isPresented: $scanning) {
      Scanner { found in
        scanning = false
        Task { await store.pair(code: found) }
      }
      .ignoresSafeArea()
    }
    .alert("Paste pairing code", isPresented: $pasting) {
      TextField("kdpair1:…", text: $code)
      Button("Pair") { let c = code; code = ""; Task { await store.pair(code: c) } }
      Button("Cancel", role: .cancel) { code = "" }
    } message: { Text("Use Copy code instead on the Mac's pairing screen.") }
  }
}

struct RequestsView: View {
  @Environment(PhoneStore.self) private var store
  @State private var confirmUnpair = false

  var body: some View {
    List {
      if let m = store.message {
        Section { Text(m).font(.footnote).foregroundStyle(.secondary) }
      }
      if case .silent(let why) = store.pushMode {
        Section {
          Text("Notifications come through background refresh, so they stop if you swipe keydillo away. iCloud refused direct alerts: \(why)")
            .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
        }
      }
      if let n = store.notificationProblem {
        Section {
          VStack(alignment: .leading, spacing: 6) {
            Text("Notifications aren't on").font(.subheadline.weight(.medium))
            Text(n).font(.footnote).foregroundStyle(.secondary)
            if store.notificationsDenied {
              Button("Open Settings") { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) }
                .font(.footnote.weight(.medium))
            }
          }
        }
      }
      if store.waiting.isEmpty {
        Section {
          VStack(alignment: .leading, spacing: 6) {
            Text("No requests waiting").font(.headline)
            Text("Requests from \(store.mac?.name ?? "your Mac") show up here and as notifications. Pull to check now.")
              .font(.subheadline).foregroundStyle(.secondary)
          }
          .padding(.vertical, 8)
        }
      }
      ForEach(store.waiting) { ask in
        Section { RequestCard(ask: ask) }
      }
    }
    .listStyle(.insetGrouped)
    .refreshable { await store.refresh() }
    .navigationTitle(store.mac?.name ?? "keydillo")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      Menu {
        Button("Unpair this Mac", role: .destructive) { confirmUnpair = true }
      } label: { Image(systemName: "ellipsis.circle") }
    }
    .confirmationDialog("Unpair \(store.mac?.name ?? "this Mac")?", isPresented: $confirmUnpair, titleVisibility: .visible) {
      Button("Unpair", role: .destructive) { store.unpair() }
    } message: { Text("Also click Unpair in keydillo's Settings on the Mac.") }
    .task {
      // While the app is open, check every few seconds in case a push is late.
      while !Task.isCancelled { await store.refresh(); try? await Task.sleep(for: .seconds(4)) }
    }
  }
}

struct RequestCard: View {
  @Environment(PhoneStore.self) private var store
  let ask: ApprovalAsk
  @State private var forSession = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text(ask.title).font(.headline)
      if let why = ask.purpose {
        VStack(alignment: .leading, spacing: 2) {
          Text("\(ask.requester) says").font(.caption).foregroundStyle(.secondary)
          Text("“\(why)”").font(.subheadline).lineLimit(4)
        }
      }
      VStack(alignment: .leading, spacing: 8) {
        Row(label: "Site", value: "\(ask.method) \(ask.host)")
        Row(label: "Path (from the program)", value: ask.path.isEmpty ? "/" : ask.path)
      }
      // Only locked-Mac requests have a short limit; others stay until answered here or on the Mac.
      if ask.secondsLeft <= 15 * 60 {
        TimelineView(.periodic(from: .now, by: 1)) { _ in
          Text("Expires in \(ask.secondsLeft / 60):\(String(format: "%02d", ask.secondsLeft % 60))")
            .font(.footnote).foregroundStyle(.secondary).monospacedDigit()
        }
      }
      Toggle(isOn: $forSession) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Don't ask again this session").font(.subheadline)
          Text("Any path, until \(ask.requester) quits")
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
      }
      .tint(.primary)
      HStack(spacing: 10) {
        Button { Task { await store.answer(ask, .deny) } } label: { Text("Deny").frame(maxWidth: .infinity) }
          .buttonStyle(PillButton(primary: false))
        Button { Task { await store.answer(ask, .approve, scope: forSession ? .session : .once) } } label: { Text("Approve").frame(maxWidth: .infinity) }
          .buttonStyle(PillButton(primary: true))
      }
      .disabled(store.busy)
    }
    .padding(.vertical, 6)
  }
}

struct Row: View {
  let label: String, value: String
  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(label).font(.caption).foregroundStyle(.secondary)
      Text(value).font(.system(.subheadline, design: .monospaced)).lineLimit(3)
    }
  }
}

/// Monochrome pill buttons, matching the Mac app.
struct PillButton: ButtonStyle {
  var primary: Bool
  @Environment(\.isEnabled) private var enabled
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 16, weight: .medium))
      .padding(.vertical, 13).padding(.horizontal, 18)
      .foregroundStyle(primary ? Color(.systemBackground) : Color.primary)
      .background(Capsule().fill(primary ? Color.primary : Color(.secondarySystemFill)))
      .opacity(enabled ? (configuration.isPressed ? 0.7 : 1) : 0.4)
  }
}

// MARK: QR scanner

struct Scanner: UIViewControllerRepresentable {
  var found: (String) -> Void
  static var supported: Bool { DataScannerViewController.isSupported && DataScannerViewController.isAvailable }

  func makeUIViewController(context: Context) -> DataScannerViewController {
    let vc = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: [.qr])], isHighlightingEnabled: true)
    vc.delegate = context.coordinator
    try? vc.startScanning()
    return vc
  }
  func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}
  func makeCoordinator() -> Coordinator { Coordinator(found: found) }

  final class Coordinator: NSObject, DataScannerViewControllerDelegate {
    let found: (String) -> Void
    var done = false
    init(found: @escaping (String) -> Void) { self.found = found }
    func dataScanner(_ scanner: DataScannerViewController, didAdd items: [RecognizedItem], allItems: [RecognizedItem]) {
      for case .barcode(let b) in items {
        guard !done, let s = b.payloadStringValue, s.hasPrefix(PairingOffer.prefix) else { continue }
        done = true
        scanner.stopScanning()
        found(s)
      }
    }
  }
}
