# swift-mlx-mnist

A hand-written training loop on MLX Swift: my own MLP (784→128→10) trained on
MNIST with SGD + cross-entropy. The dataset loader is written from scratch too,
so the only dependency is Apple's `mlx-swift`. This is the "write the loop
yourself" step after the Create ML experiments.

Part of a series of experiments comparing feedback-loop speed across the Apple
ML stack (Create ML / Core ML / MLX).

## Dependencies

Only Apple-official packages, all version-pinned (`Package.resolved` frozen):
`ml-explore/mlx-swift` (exact 0.31.6), plus its `apple/swift-numerics` and
`apple/swift-argument-parser`. No third-party code, no unpinned `branch: main`.

An earlier version pulled `mlx-swift-examples` (`branch: main`) just for its
MNIST loader, which dragged in a large third-party tree (HuggingFace,
EventSource, Gzip, yyjson) and resolved an unpinned moving target at build
time. That was removed: the loader below replaces it.

## Structure

| Target | Kind | Purpose |
|--------|------|---------|
| `MNISTCore` | library | Option parsing, seeded RNG, IDX parser, gzip decoder (Apple `Compression`) — unit-tested |
| `mnist-train` | CLI | Dataset download/load, MLP model, loss/accuracy, shuffled mini-batches, epoch loop (`valueAndGrad` + `SGD`) |

## How to run

### First time only: trust the Metal-shader plugin in Xcode

`mlx-swift` ships a build-tool plugin (`CudaBuild`) that compiles the Metal
shaders. On a clean machine it is untrusted, and `xcodebuild` on the command
line **cannot** show the trust dialog — it just fails with
`Validate plug-in "CudaBuild" in package "mlx-swift"`. Grant trust once in the
Xcode GUI (this records only this plugin's fingerprint under
`~/Library/org.swift.swiftpm/security/plugins.json`; validation stays on for
everything else):

```sh
open Package.swift
```

Then in Xcode:

1. Scheme: leave it on the auto-generated `swift-mlx-mnist`.
2. Destination: switch it to **My Mac** (the default may be an iOS device,
   which fails because this package is macOS-only and MLX requires iOS 17+).
3. Build (**⌘B**). When the **Trust & Enable** dialog appears for `CudaBuild`,
   approve it — it is Apple's official plugin.

Do **not** use `-skipPackagePluginValidation` or
`defaults write … IDESkipPackagePluginFingerprintValidatation`: both
blanket-trust every plugin. The one-time GUI approval is the targeted,
still-secure path.

### Run

```sh
Scripts/run.sh --data /tmp/mnist --epochs 5
```

Options: `--base-url URL`, `--batch-size 256`, `--learning-rate 0.1`,
`--seed 0`, `--device gpu|cpu`. Data files are downloaded from `--base-url`
(default a public MNIST mirror) when absent; they are image data parsed by the
bounded `IDXParser`, but the host is third-party, hence overridable.

**Why the script:** bare SwiftPM cannot compile MLX's Metal shaders
([mlx-swift #36](https://github.com/ml-explore/mlx-swift/issues/36)) — even
`--device cpu` fails because MLX touches Metal during stream setup. The script
builds with `xcodebuild -destination 'platform=macOS'` (which produces the
`mlx-swift_Cmlx.bundle` shader bundle) and runs the binary with
`DYLD_FRAMEWORK_PATH` pointing at the products directory, same idea as the
upstream `mlx-run` wrapper. Because the destination is pinned to macOS, the
iOS-version mismatch above only bites in the GUI, not here.

Tests:

```sh
swift test
```

## Results (M5 Max, macOS 26.5, GPU)

60,000 train / 10,000 test images. Epoch 1 includes warmup (3.2 s); after
that ~0.11 s/epoch. Test accuracy 89.3% → 93.4% over 5 epochs. The
epoch-level feedback loop is near-instant; the slow part was the build
plumbing, not the ML.

## Requirements

macOS 14+, Apple Silicon, Xcode (for xcodebuild).
