// swift-tools-version: 6.1
import PackageDescription

let package = Package(
  name: "swift-createml-tabular",
  platforms: [.macOS(.v14)],
  targets: [
    .target(name: "TabularCore"),
    .executableTarget(name: "train", dependencies: ["TabularCore"]),
    .testTarget(name: "TabularCoreTests", dependencies: ["TabularCore"]),
  ]
)
