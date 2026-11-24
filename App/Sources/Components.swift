import SwiftUI

struct PrimaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 14, weight: .medium))
      .foregroundStyle(Theme.onPrimary)
      .padding(.horizontal, 18).frame(height: 36)
      .background(Capsule().fill(Theme.primary.opacity(configuration.isPressed ? 0.8 : 1)))
      .contentShape(Capsule())
  }
}

struct SecondaryButtonStyle: ButtonStyle {
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 14))
      .foregroundStyle(Theme.text)
      .padding(.horizontal, 16).frame(height: 36)
      .background(Capsule().fill(configuration.isPressed ? Theme.fill : Theme.background))
      .overlay(Capsule().strokeBorder(Theme.border))
      .contentShape(Capsule())
  }
}

struct SmallButtonStyle: ButtonStyle {
  var destructive = false
  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .font(.system(size: 12))
      .foregroundStyle(destructive ? Theme.danger : Theme.text)
      .padding(.horizontal, 12).frame(height: 28)
      .background(Capsule().fill(configuration.isPressed ? Theme.fill : Theme.background))
      .overlay(Capsule().strokeBorder(Theme.border))
      .contentShape(Capsule())
  }
}

/// Filled, borderless text field from the mockups.
struct FilledField: View {
  let placeholder: String
  @Binding var text: String
  var secure = false
  var monospaced = false
  var height: CGFloat = 36
  var emphasized = false

  var body: some View {
    Group {
      if secure { SecureField(placeholder, text: $text) } else { TextField(placeholder, text: $text) }
    }
    .textFieldStyle(.plain)
    .font(monospaced ? .system(size: 12.5, design: .monospaced) : .system(size: 14))
    .padding(.horizontal, 12).frame(height: height)
    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.fill))
    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(emphasized ? Theme.primary : .clear, lineWidth: 2))
  }
}

/// Pill-shaped segmented control.
struct PillPicker<T: Hashable>: View {
  let options: [(T, String)]
  @Binding var selection: T
  var body: some View {
    HStack(spacing: 0) {
      ForEach(options, id: \.0) { value, label in
        Button { selection = value } label: {
          Text(label).font(.system(size: 12.5)).lineLimit(1).fixedSize()
            .foregroundStyle(selection == value ? Theme.text : Theme.tertiary)
            .padding(.horizontal, 11).frame(height: 28)
            .background(Capsule().fill(selection == value ? Theme.background : .clear)
              .shadow(color: .black.opacity(selection == value ? 0.12 : 0), radius: 1.5, y: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
      }
    }
    .padding(3)
    .background(Capsule().fill(Theme.fill))
  }
}

/// "› Options" style collapsible.
struct Collapsible<Content: View>: View {
  let title: String
  @Binding var isOpen: Bool
  @ViewBuilder var content: () -> Content
  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Button { withAnimation(.easeInOut(duration: 0.15)) { isOpen.toggle() } } label: {
        HStack(spacing: 6) {
          Image(systemName: "chevron.right").font(.system(size: 10, weight: .semibold))
            .rotationEffect(.degrees(isOpen ? 90 : 0))
          Text(title).font(.system(size: 13))
        }
        .foregroundStyle(Theme.tertiary)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      if isOpen { content() }
    }
  }
}

struct StepDots: View {
  let count: Int
  let current: Int
  var body: some View {
    HStack(spacing: 6) {
      ForEach(0..<count, id: \.self) { i in
        Capsule().fill(i == current ? Theme.primary : Theme.border)
          .frame(width: i == current ? 18 : 6, height: 6)
      }
    }
    .accessibilityLabel("Step \(current + 1) of \(count)")
  }
}

struct StatusDot: View {
  var on: Bool
  var body: some View { Circle().fill(on ? Theme.success : Theme.danger).frame(width: 8, height: 8) }
}

/// Round badge for a service: its logo (Simple Icons, CC0) when we have one, else initials.
struct ServiceBadge: View {
  var service: String = ""
  let name: String
  var size: CGFloat = 34
  var body: some View {
    Group {
      if let img = Self.logo(service) {
        Image(nsImage: img).renderingMode(.template).resizable().scaledToFit().frame(width: size * 0.46, height: size * 0.46)
      } else {
        Text(Self.initials(name)).font(.system(size: 12, weight: .semibold))
      }
    }
    .foregroundStyle(Theme.text)
    .frame(width: size, height: size)
    .background(Circle().fill(Theme.fill))
    .accessibilityHidden(true)
  }
  static func logo(_ service: String) -> NSImage? {
    let base = service.split(separator: "-").first.map(String.init) ?? service
    return NSImage(named: "logo-" + base)
  }
  static func initials(_ s: String) -> String {
    let words = s.split(whereSeparator: { $0 == " " || $0 == "-" })
    if words.count >= 2 { return String(words[0].prefix(1) + words[1].prefix(1)).uppercased() }
    return String(s.prefix(2)).uppercased()
  }
}

/// Shows the content at its full height when it fits, and lets it scroll when it's taller than `maxHeight`
/// (the screen, by default). The window or popover around it grows and shrinks with the content, as it did
/// with fixed sizes, but never past the screen.
struct FitOrScroll<Content: View>: View {
  var maxHeight: CGFloat = ScreenRoom.height - 40
  @ViewBuilder var content: () -> Content
  @State private var height: CGFloat = 0

  var body: some View {
    ViewThatFits(in: .vertical) {
      measured
      ScrollView(.vertical) { measured }.scrollBounceBehavior(.basedOnSize)
    }
    .frame(minHeight: height > 0 ? min(height, maxHeight) : nil, maxHeight: height > 0 ? height : nil, alignment: .top)
  }

  var measured: some View {
    content().onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
  }
}

/// The usable height of the main screen. Development previews can pretend it's shorter (`-kdScreenHeight 600`).
enum ScreenRoom {
  static var height: CGFloat {
    let fake = ProcessInfo.processInfo.environment["KEYDILLO_DEV"] == "1" ? UserDefaults.standard.double(forKey: "kdScreenHeight") : 0
    return fake > 0 ? fake : NSScreen.main?.visibleFrame.height ?? 800
  }
}

extension View {
  func sheetCard() -> some View {
    FitOrScroll { self.padding(24).frame(width: 460) }.background(Theme.background).foregroundStyle(Theme.text)
  }
}
