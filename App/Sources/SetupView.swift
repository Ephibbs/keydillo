import SwiftUI

struct SetupView: View {
  @Environment(AppModel.self) private var model
  @State var step = 0
  @State private var approval: DefaultApproval = .session
  @State var never = false
  @State private var neverError: String?
  @State private var changesOpen = false
  @State private var connecting = false
  @State private var connectError: String?
  @State private var kdMissing = false

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
      Image("AppLogo").resizable().interpolation(.high).frame(width: 56, height: 56).accessibilityHidden(true)
      header("Welcome to keydillo", "Let Claude and other AI tools use your API keys without ever seeing them. Keys are encrypted on this Mac.")
      footer(0) { Button("Continue") { step = 1 }.buttonStyle(PrimaryButtonStyle()).keyboardShortcut(.defaultAction) }
    }
  }

  var touchID: some View {
    Group {
      header("How often should we ask for Touch ID?", "Before an AI tool uses one of your keys.")
      VStack(spacing: 8) {
        choice(.eachRequest, "Every time")
        choice(.session, "Once per session", note: "Recommended")
        neverChoice
      }
      if never {
        Text(TrustCopy.onboarding)
          .font(.system(size: 12)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true)
      }
      if let neverError { Text(neverError).font(.system(size: 12)).foregroundStyle(Theme.danger).fixedSize(horizontal: false, vertical: true) }
      Text("You can change this anytime in Settings, or per project.").font(.system(size: 12)).foregroundStyle(Theme.secondary)
      footer(1) {
        Button(never ? "Continue with Touch ID" : "Continue") {
          Task {
            if never {
              neverError = await model.setTrusted("Claude Code", true)
              guard model.trustedAgents.contains("Claude Code") else { return }
              await model.setDefaultAccess(.perKey)
            } else {
              if model.trustedAgents.contains("Claude Code") { _ = await model.setTrusted("Claude Code", false) }
              await model.setDefaultAccess(approval == .eachRequest ? .everyTime : .perKey)
            }
            step = 2
          }
        }
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
      VStack(alignment: .leading, spacing: 4) {
        Text("Put kd in front of commands that use your keys. Claude does it for you.").font(.system(size: 13)).fixedSize(horizontal: false, vertical: true)
        Text("kd npm run dev").font(.system(size: 13, design: .monospaced)).foregroundStyle(Theme.secondary)
        if kdMissing {
          Text("To use kd in Terminal, add this line to ~/.zshrc: \(ShellIntegration.pathLine)")
            .font(.system(size: 12)).foregroundStyle(Theme.secondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
      }
      .task { kdMissing = await Task.detached { !ShellIntegration.kdOnPath() }.value }
      OtherToolsLine()
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

  var neverChoice: some View {
    Button { never = true } label: {
      HStack(spacing: 12) {
        Image(systemName: never ? "largecircle.fill.circle" : "circle").foregroundStyle(never ? Theme.primary : Theme.secondary)
        Text("Always allow Claude Code").font(.system(size: 14))
        Spacer()
        Text("Fewest prompts").font(.system(size: 12)).foregroundStyle(Theme.secondary)
      }
      .padding(.horizontal, 14).frame(height: 44)
      .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(never ? Theme.primary : .clear, lineWidth: 2))
      .contentShape(RoundedRectangle(cornerRadius: 12))
    }
    .buttonStyle(.plain)
  }

  func choice(_ value: DefaultApproval, _ label: String, note: String? = nil) -> some View {
    Button { approval = value; never = false } label: {
      HStack(spacing: 12) {
        Image(systemName: !never && approval == value ? "largecircle.fill.circle" : "circle")
          .foregroundStyle(!never && approval == value ? Theme.primary : Theme.secondary)
        Text(label).font(.system(size: 14))
        Spacer()
        if let note { Text(note).font(.system(size: 12)).foregroundStyle(Theme.secondary) }
      }
      .padding(.horizontal, 14).frame(height: 44)
      .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
      .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(!never && approval == value ? Theme.primary : .clear, lineWidth: 2))
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
    if !Handover.underLaunchd && AppModel.agent.status == .enabled {
      model.noteCleanExit()
      if Handover.toLaunchd() { exit(0) }
      model.noteUncleanExit()   // launchd couldn't start it: keep running here
      Handover.repair()
    }
    StatusItem.shared?.open()
  }
}

/// For people using Cursor, Codex and other agents: the skill works there too (no tools or hook).
struct OtherToolsLine: View {
  static let command = "npx skills add Ephibbs/keydillo"
  @State private var copied = false
  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Text("Using Cursor, Codex or another AI tool? Run:").font(.system(size: 12)).foregroundStyle(Theme.secondary)
      HStack(spacing: 8) {
        Text(Self.command).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
        Button(copied ? "Copied" : "Copy") {
          NSPasteboard.general.clearContents(); NSPasteboard.general.setString(Self.command, forType: .string); copied = true
        }
        .buttonStyle(SmallButtonStyle())
      }
    }
  }
}
