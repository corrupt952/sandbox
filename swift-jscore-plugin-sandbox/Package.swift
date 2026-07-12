// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "JSCorePluginSandbox",
  platforms: [.macOS("26.0")],
  targets: [
    .executableTarget(
      name: "JSCorePluginSandbox",
      path: "Sources/JSCorePluginSandbox"
    )
  ]
)
