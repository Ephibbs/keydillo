import SwiftUI

struct SetupView: View {
  @Environment(AppModel.self) private var model
  @State var step = 0
  @State private var approval: DefaultApproval = .window15
  @State private var changesOpen = false
  @State private var connecting = false
  @State private var connectError: String?

  let steps = 4

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      switch step {
      case 0: welcome
      case 1: touchID
      case 2: ImportView(inSetup: true) { step = 3 }
      default: claude
      }
    }
    .padding(.top, 4)
    .sheetCard()
    .animation(.easeInOut(duration: 0.15), value: step)
  }

  var welcome: some View {
    Group {
      Image(systemName: "key.horizontal").font(.system(size: 24)).foregroundStyle(Theme.text)
        .frame(width: 56, height: 56).background(RoundedRectangle(cornerRadius: 14).fill(Theme.fill))
      header("Welcome to keydillo", "Let Claude and other AI tools use your API keys without ever seeing them. Keys are encrypted on this Mac.")
      footer(0) { Button("Continue") { step = 1 }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction) }
    }
  }

  var touchID: some View {
    Group {
      header("How often should we ask for Touch ID?", "Before an AI tool uses one of your keys.")
      VStack(spacing: 8) {
        choice(.eachRequest, "Every time")
        choice(.window15, "Once every 15 minutes", note: "Recommended")
        choice(.session, "Once per session")
      }
      Text("You can change this anytime, or per key.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
      footer(1) {
        Button("Continue") { model.defaultApproval = approval; step = 2 }
          .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction)
      }
    }
  }

  var claude: some View {
    Group {
      header("Connect Claude Code", "Claude will ask keydillo when it needs a key, instead of asking you to paste it into the chat.")
      Collapsible(title: "What this changes", isOpen: $changesOpen) {
        VStack(alignment: .leading, spacing: 6) {
          ForEach(ClaudeConnector.changes, id: \.self) { line in
            HStack(alignment: .top, spacing: 8) {
              Text("•").foregroundStyle(Theme.secondary)
              Text(line).fixedSize(horizontal: false, vertical: true)
            }
          }
        }
        .font(.system(size: 13)).foregroundStyle(Theme.tertiary)
      }
      if let connectError { Text(connectError).font(.system(size: 12)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true) }
      footer(3) {
        HStack(spacing: 8) {
          Button("Skip") { finish() }.buttonStyle(SecondaryButtonStyle())
          Button(connecting ? "Connecting…" : "Connect") {
            connecting = true
            Task {
              let result = await ClaudeConnector.connect()
              connecting = false
              if let err = result { connectError = err } else { finish() }
            }
          }
          .buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction).disabled(connecting)
        }
      }
    }
  }

  func header(_ title: String, _ body: String) -> some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title).font(.system(size: 22, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
      Text(body).font(.system(size: 14)).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
    }
  }

  func choice(_ value: DefaultApproval, _ label: String, note: String? = nil) -> some View {
    Button { approval = value } label: {
      HStack(spacing: 12) {
        Image(systemName: approval == value ? "largecircle.fill.circle" : "circle")
          .foregroundStyle(approval == value ? Theme.primary : Theme.secondary)
        Text(label).font(.system(size: 14))
        Spacer()
        if let note { Text(note).font(.system(size: 12)).foregroundStyle(Theme.secondary) }
      }
      .padding(.horizontal, 14).frame(height: 44)
      .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(approval == value ? Theme.primary : .clear, lineWidth: 2))
      .contentShape(RoundedRectangle(cornerRadius: 12))
    }
    .buttonStyle(.plain)
  }

  func footer<B: View>(_ index: Int, @ViewBuilder _ buttons: () -> B) -> some View {
    HStack { StepDots(count: steps, current: index); Spacer(); buttons() }.padding(.top, 8)
  }

  func finish() {
    model.setupDone = true
    model.openAtLogin = true   // start at login and restart after a crash; can be turned off in Settings
    WindowManager.shared.close("setup")
    StatusItem.shared?.open()
  }
}
