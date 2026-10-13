// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "LocoLoco",
  platforms: [.macOS(.v14)],
  targets: [
    // Finds servers, keeps history, starts and stops processes. No UI.
    .target(name: "LocoCore"),
    // The menu bar app.
    .executableTarget(name: "LocoLoco", dependencies: ["LocoCore"]),
    // Prints what the scanner sees, to check it against lsof.
    .executableTarget(name: "loco-scan", dependencies: ["LocoCore"]),
    .testTarget(name: "LocoCoreTests", dependencies: ["LocoCore"]),
  ]
)
