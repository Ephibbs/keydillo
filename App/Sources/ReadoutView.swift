import SwiftUI
import AppKit

/// Shows a project's real key values after Touch ID. GUI only, hides after 60 s.
struct ReadoutView: View {
  enum Format: String, CaseIterable { case env = ".env", vercel = "Vercel", fly = "Fly", shell = "Shell export" }
  let project: String
  let values: [(String, String)]
  @State private var format: Format = .env
  @State private var copied = false
  @State private var remaining = 60

  var text: String {
    switch format {
    case .env: return values.map { "\($0.0)=\($0.1)" }.joined(separator: "\n")
    case .vercel: return values.map { "printf %s '\($0.1)' | vercel env add \($0.0) production" }.joined(separator: "\n")
    case .fly: return "fly secrets set " + values.map { "\($0.0)='\($0.1)'" }.joined(separator: " ")
    case .shell: return values.map { "export \($0.0)='\($0.1)'" }.joined(separator: "\n")
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      VStack(alignment: .leading, spacing: 4) {
        Text("\(project) keys").font(.system(size: 20, weight: .semibold))
        Text("Unlocked with Touch ID. Hides again in \(remaining) s.").font(.system(size: 13)).foregroundStyle(Theme.secondary)
      }
      PillPicker(options: Format.allCases.map { ($0, $0.rawValue) }, selection: $format)
      ScrollView {
        Text(text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading).padding(14)
      }
      .frame(height: 180)
      .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
      Text("Only this window can show values. Claude, the CLI and the proxy never get them.")
        .font(.system(size: 12)).foregroundStyle(Theme.secondary)
      HStack {
        Text(copied ? "Copied. Clears from the clipboard in 30 s." : "").font(.system(size: 12)).foregroundStyle(Theme.secondary)
        Spacer()
        Button("Done") { WindowManager.shared.close("readout") }.buttonStyle(SecondaryButtonStyle())
        Button("Copy all") { copy() }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
      }
    }
    .padding(24).frame(width: 560).background(Theme.background).foregroundStyle(Theme.text)
    .task {
      while remaining > 0 { try? await Task.sleep(for: .seconds(1)); remaining -= 1 }
      WindowManager.shared.close("readout")
    }
  }

  func copy() {
    let pb = NSPasteboard.general
    pb.prepareForNewContents(with: .currentHostOnly)   // keep keys off Universal Clipboard
    pb.setString(text, forType: .string)
    // Mark as concealed so clipboard managers that respect it skip this.
    pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
    let change = pb.changeCount
    copied = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 30) {
      if NSPasteboard.general.changeCount == change { NSPasteboard.general.clearContents() }
    }
  }
}
