// swift-tools-version: 6.1
import PackageDescription

let package = Package(
  name: "swift-coreml-embed",
  platforms: [.macOS(.v14)],
  targets: [
    .target(name: "CoreMLEmbedCore"),
    .executableTarget(name: "predict", dependencies: ["CoreMLEmbedCore"]),
    .testTarget(name: "CoreMLEmbedCoreTests", dependencies: ["CoreMLEmbedCore"]),
  ]
)
