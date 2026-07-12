// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "DavePoC",
  targets: [
    .systemLibrary(name: "CLibDave"),
    .executableTarget(
      name: "DavePoC",
      dependencies: ["CLibDave"],
      linkerSettings: [
        .unsafeFlags([
          "-L", "../libdave/cpp/build",
          "-L", "../libdave/cpp/build/vcpkg_installed/arm64-osx/lib",
          "-ldave",
          "-lmlspp",
          "-lhpke",
          "-lbytes",
          "-lmls_ds",
          "-ltls_syntax",
          "-lssl",
          "-lcrypto",
          "-lc++",
        ])
      ]
    ),
  ]
)
