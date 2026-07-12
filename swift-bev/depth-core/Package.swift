// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "DepthBEVCore",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .library(
      name: "DepthBEVCore",
      targets: ["DepthBEVCore"]
    )
  ],
  targets: [
    .target(
      name: "DepthBEVCore",
      dependencies: []
    ),
    .testTarget(
      name: "DepthBEVCoreTests",
      dependencies: ["DepthBEVCore"]
    ),
  ]
)
