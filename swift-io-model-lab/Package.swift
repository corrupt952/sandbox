// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "swift-io-model-lab",
  platforms: [.macOS(.v13)],
  targets: [
    .executableTarget(name: "iolab", path: "Sources/iolab")
  ]
)
