// swift-tools-version: 6.0
import PackageDescription

// libdave build artifacts are expected in a sibling ../libdave checkout (see README),
// following the same convention as swift-dave-poc. libdave/libopus are not vendored.
let libdaveRoot = "../libdave/cpp"

let package = Package(
  name: "DiscordVoicePoC",
  platforms: [.macOS(.v14)],
  targets: [
    .systemLibrary(name: "CLibDave"),
    .systemLibrary(name: "CLibOpus", pkgConfig: "opus"),
    .executableTarget(
      name: "DiscordVoicePoC",
      dependencies: ["CLibDave", "CLibOpus"],
      linkerSettings: [
        .unsafeFlags([
          "-L", "\(libdaveRoot)/build",
          "-L", "\(libdaveRoot)/build/vcpkg_installed/arm64-osx/lib",
          "-ldave", "-lmlspp", "-lhpke", "-lbytes", "-lmls_ds", "-ltls_syntax",
          "-lssl", "-lcrypto", "-lc++",
        ])
      ]
    ),
  ],
  cxxLanguageStandard: .cxx17
)
