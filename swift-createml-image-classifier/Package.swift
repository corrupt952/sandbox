// swift-tools-version: 6.1
import PackageDescription

let package = Package(
  name: "swift-createml-image-classifier",
  platforms: [.macOS("15.4")],
  targets: [
    .target(name: "ImageClassifierCore"),
    .executableTarget(name: "datasetgen", dependencies: ["ImageClassifierCore"]),
    .executableTarget(name: "train"),
    .executableTarget(name: "datasetgen-app", dependencies: ["ImageClassifierCore"]),
    .testTarget(name: "ImageClassifierCoreTests", dependencies: ["ImageClassifierCore"]),
  ]
)
