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
    // The same helper under a different CFBundleIdentifier, for E11. App Sandbox
    // keys the container to the identifier and then guards it against a binary whose
    // signing identity differs from the last one that used it — so a Developer ID
    // build sharing dev.zuki.jscore-oop-helper with the ad-hoc variants trips a
    // "differs from previously opened versions" dialog on both sides. Its own
    // identifier gives it its own container and keeps the two from colliding.
    // Its main.swift is a symlink to PluginHelper's — SwiftPM refuses two targets
    // over one directory, and a copy would drift.
    .executableTarget(
      name: "PluginHelperDevID",
      dependencies: ["PluginIPC", "CPluginIPC"],
      path: "Sources/PluginHelperDevID",
      exclude: ["Info.plist"],
      linkerSettings: [
        .unsafeFlags([
          "-Xlinker", "-sectcreate",
          "-Xlinker", "__TEXT",
          "-Xlinker", "__info_plist",
          "-Xlinker", "Sources/PluginHelperDevID/Info.plist",
        ])
      ]
    ),
    // A helper that has been taken over, for E12. It writes raw bytes underneath the
    // frame protocol, which is the only way to send input a cooperating helper could
    // not. Its own identifier keeps its App Sandbox container clear of the others'.
    .executableTarget(
      name: "HostileHelper",
      dependencies: ["PluginIPC", "CPluginIPC"],
      path: "Sources/HostileHelper",
      exclude: ["Info.plist"],
      linkerSettings: [
        .unsafeFlags([
          "-Xlinker", "-sectcreate",
          "-Xlinker", "__TEXT",
          "-Xlinker", "__info_plist",
          "-Xlinker", "Sources/HostileHelper/Info.plist",
        ])
      ]
    ),
    // The helper minus JavaScriptCore. E10 launches both and compares, which decides
    // whether deferring JSC could buy anything before anyone writes that version.
    .executableTarget(
      name: "StubHelper",
      dependencies: ["PluginIPC", "CPluginIPC"],
      path: "Sources/StubHelper"
    ),
    .executableTarget(
      name: "OOPHost",
      dependencies: ["PluginIPC", "CPluginIPC"],
      path: "Sources/OOPHost",
      exclude: ["Info.plist"],
      linkerSettings: [
        // E8 signs a sandboxed copy of the host, which needs a container identifier
        // for the same reason the helper does.
        .unsafeFlags([
          "-Xlinker", "-sectcreate",
          "-Xlinker", "__TEXT",
          "-Xlinker", "__info_plist",
          "-Xlinker", "Sources/OOPHost/Info.plist",
        ])
      ]
    ),
  ]
)
