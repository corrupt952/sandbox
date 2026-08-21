// swift-tools-version:5.9
import PackageDescription

let package = Package(
  name: "swift-kana-kanji-poc",
  platforms: [.macOS(.v14)],
  targets: [
    .target(name: "KanaKanjiCore", path: "Sources/KanaKanjiCore"),
    .executableTarget(name: "kkc", dependencies: ["KanaKanjiCore"], path: "Sources/kkc"),
    .executableTarget(name: "kkclab", dependencies: ["KanaKanjiCore"], path: "Sources/kkclab"),
    .testTarget(
      name: "KanaKanjiCoreTests", dependencies: ["KanaKanjiCore"], path: "Tests/KanaKanjiCoreTests"),
  ]
)
