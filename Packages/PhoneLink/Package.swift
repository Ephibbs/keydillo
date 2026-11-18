// swift-tools-version: 6.0
import PackageDescription

// Shared by the Mac app and the iPhone companion: the pairing and approval messages, how they are signed
// and sealed, and how they travel (CloudKit in the user's own iCloud, or a folder for local tests).
let package = Package(
  name: "PhoneLink",
  platforms: [.macOS(.v15), .iOS(.v17)],
  products: [.library(name: "PhoneLink", targets: ["PhoneLink"])],
  targets: [
    .target(name: "PhoneLink", swiftSettings: [.swiftLanguageMode(.v5)]),
    // A pretend iPhone with software keys and a folder transport, for testing the Mac side without a phone. Never shipped.
    .executableTarget(name: "kd-fakephone", dependencies: ["PhoneLink"], swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(name: "PhoneLinkTests", dependencies: ["PhoneLink"], swiftSettings: [.swiftLanguageMode(.v5)]),
  ]
)
