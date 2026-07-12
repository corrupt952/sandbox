// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "IPMCore",
  platforms: [
    .macOS(.v13)
  ],
  products: [
    .library(
      name: "IPMCore",
      targets: ["IPMCore"]
    ),
    .executable(
      name: "ipm-demo",
      targets: ["ipm-demo"]
    ),
  ],
  targets: [
    .target(
      name: "IPMCore",
      dependencies: []
    ),
    .executableTarget(
      name: "ipm-demo",
      dependencies: ["IPMCore"]
    ),
    .testTarget(
      name: "IPMCoreTests",
      dependencies: ["IPMCore"]
    ),
  ]
)
