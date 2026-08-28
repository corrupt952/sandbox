// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "JSCoreOOPPoC",
  platforms: [.macOS("26.0")],
  targets: [
    .target(name: "CPluginIPC", path: "Sources/CPluginIPC"),
    .target(name: "PluginIPC", dependencies: ["CPluginIPC"], path: "Sources/PluginIPC"),
    .executableTarget(
      name: "PluginHelper",
      dependencies: ["PluginIPC", "CPluginIPC"],
      path: "Sources/PluginHelper",
      exclude: ["Info.plist"],
      linkerSettings: [
        // App Sandbox reads CFBundleIdentifier out of the code signature to name
        // the container. Embedding the plist keeps the helper a plain executable.
        .unsafeFlags([
          "-Xlinker", "-sectcreate",
          "-Xlinker", "__TEXT",
          "-Xlinker", "__info_plist",
          "-Xlinker", "Sources/PluginHelper/Info.plist",
        ])
      ]
    ),
    .executableTarget(
      name: "OOPHost",
      dependencies: ["PluginIPC", "CPluginIPC"],
      path: "Sources/OOPHost"
    ),
  ]
)
