import SwiftUI
import VaultCore

/// Wording shared by onboarding and Settings, so both say the same thing.
enum TrustCopy {
  static let section = "Trusted apps"
  static let explain = "A trusted app, and everything it runs, uses and changes your keys without asking, even while your Mac is locked. It still asks to add a key, send a key to a new site, start a program with a startup key, or show a key. Other programs ask as usual."
  static let onboarding = "Claude Code and everything it runs use your keys without asking, even while your Mac is locked. Adding a key, a new site, startup keys and showing a key still ask. Other programs ask once per session."
}
