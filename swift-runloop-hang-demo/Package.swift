// swift-tools-version: 5.10
import PackageDescription

let package = Package(
  name: "RunLoopHangDemo",
  platforms: [.macOS(.v14)],
  targets: [
    .executableTarget(name: "HangDemoCore"),
    .executableTarget(name: "HangDemoUI"),
  ]
)
