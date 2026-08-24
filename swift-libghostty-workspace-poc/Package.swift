// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "GhosttyPoC",
  platforms: [.macOS("26.0")],
  targets: [
    .systemLibrary(name: "CGhostty"),
    .executableTarget(
      name: "GhosttyPoC",
      dependencies: ["CGhostty"],
      linkerSettings: [
        .unsafeFlags(["-LVendor/ghostty/lib"]),
        .linkedLibrary("c++"),
        .linkedFramework("Carbon"),
      ]
    ),
  ]
)
