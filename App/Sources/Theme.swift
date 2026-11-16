import SwiftUI
import AppKit

/// Monochrome palette from the approved mockups, with dark-mode counterparts.
enum Theme {
  static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
    Color(nsColor: NSColor(name: nil) { appearance in
      let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
      return NSColor(hex: isDark ? dark : light)
    })
  }
  static let background = dynamic(0xFFFFFF, 0x1E1E1E)
  static let sidebar = dynamic(0xF9F9F9, 0x181818)
  static let text = dynamic(0x0D0D0D, 0xECECEC)
  static let secondary = dynamic(0x676767, 0xA3A3A3)
  static let tertiary = dynamic(0x444444, 0xC4C4C4)
  static let fill = dynamic(0xF4F4F4, 0x2C2C2C)
  static let selected = dynamic(0xECECEC, 0x333333)
  static let border = dynamic(0xE0E0E0, 0x3A3A3A)
  static let hairline = dynamic(0xEDEDED, 0x2E2E2E)
  static let primary = dynamic(0x0D0D0D, 0xECECEC)
  static let onPrimary = dynamic(0xFFFFFF, 0x0D0D0D)
  static let success = dynamic(0x1E8E3E, 0x4CC36B)
  static let danger = dynamic(0xC2410C, 0xF0814F)
  static let mono = Font.system(.callout, design: .monospaced)
}

extension NSColor {
  convenience init(hex: UInt32) {
    self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
              blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
  }
}
