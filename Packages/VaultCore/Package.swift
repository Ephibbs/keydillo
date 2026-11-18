// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "VaultCore",
  platforms: [.macOS(.v15)],
  products: [.library(name: "VaultCore", targets: ["VaultCore"])],
  targets: [
    .target(name: "VaultCore", swiftSettings: [.swiftLanguageMode(.v5)]),
    // Test-only proxy with an auto-approver, used by tests/compat. Never shipped.
    .executableTarget(name: "kd-testproxy", dependencies: ["VaultCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    // Test-only Postgres proxy that approves everything, used by tests/postgres. Never shipped.
    .executableTarget(name: "kd-pgproxy-test", dependencies: ["VaultCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
    .testTarget(name: "VaultCoreTests", dependencies: ["VaultCore"], swiftSettings: [.swiftLanguageMode(.v5)]),
  ]
)
