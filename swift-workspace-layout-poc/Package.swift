// swift-tools-version: 6.2

import PackageDescription

let package = Package(
  name: "WorkspaceLayoutPoC",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "WorkspaceLayoutPoC", targets: ["WorkspaceLayoutPoC"]),
  ],
  targets: [
    .target(name: "WorkspaceLayoutCore"),
    .executableTarget(
      name: "WorkspaceLayoutPoC",
      dependencies: ["WorkspaceLayoutCore"]
    ),
    .testTarget(
      name: "WorkspaceLayoutCoreTests",
      dependencies: ["WorkspaceLayoutCore"]
    ),
  ]
)
