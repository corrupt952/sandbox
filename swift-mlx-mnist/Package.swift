// swift-tools-version: 6.1
import PackageDescription

let package = Package(
  name: "swift-mlx-mnist",
  platforms: [.macOS(.v14)],
  dependencies: [
    // Apple-official MLX only, pinned to an exact version (no branch: main,
    // no transitive third-party tree). Package.resolved freezes the checkout.
    .package(url: "https://github.com/ml-explore/mlx-swift", exact: "0.31.6")
  ],
  targets: [
    .target(name: "MNISTCore"),
    .executableTarget(
      name: "mnist-train",
      dependencies: [
        "MNISTCore",
        .product(name: "MLX", package: "mlx-swift"),
        .product(name: "MLXNN", package: "mlx-swift"),
        .product(name: "MLXOptimizers", package: "mlx-swift"),
        .product(name: "MLXRandom", package: "mlx-swift"),
      ]
    ),
    .testTarget(name: "MNISTCoreTests", dependencies: ["MNISTCore"]),
  ]
)
