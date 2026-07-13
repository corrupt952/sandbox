# swift-createml-image-classifier

Fast-feedback ML 101 with Create ML: generate a labeled image dataset, train an
image classifier programmatically (`MLImageClassifier`), and evaluate it — the
whole loop runs in seconds on Apple Silicon.

Part of a series of experiments comparing feedback-loop speed across the Apple
ML stack (Create ML / Core ML / MLX).

## Structure

| Target | Kind | Purpose |
|--------|------|---------|
| `ImageClassifierCore` | library | Synthetic shape renderer, PNG encoding, dataset writing, generation use case (unit-tested) |
| `datasetgen` | CLI | Generates a synthetic shape dataset (circle / square / triangle) with CoreGraphics |
| `datasetgen-app` | app | SwiftUI app that generates a dataset with Image Playground's `ImageCreator` (text-to-image) |
| `train` | CLI | Trains `MLImageClassifier` on a labeled directory tree and reports train/validation/test accuracy |

Two dataset sources exist because `ImageCreator` only works inside an app
bundle (not CLI tools), requires Apple Intelligence, and is deprecated as of
macOS 27. The CoreGraphics synthetic generator is the always-works fallback.

`ImageCreator` has no seed or variation API — the same prompt and style
deterministically produce the same image. `PromptVariator` therefore appends
random viewpoint/setting/lighting modifiers and the use case requests one
image per varied prompt.

## How to run

Synthetic dataset + training:

```sh
swift run -c release datasetgen --output /tmp/shapes/train --count 30 --seed 42
swift run -c release datasetgen --output /tmp/shapes/test --count 10 --seed 777
swift run -c release train --data /tmp/shapes/train --test-data /tmp/shapes/test \
  --output ShapeClassifier.mlmodel --iterations 20
```

Image Playground dataset (requires Apple Intelligence enabled and models
downloaded; builds an ad-hoc signed .app bundle and opens it):

```sh
Scripts/run-datasetgen-app.sh
```

Tests:

```sh
swift test
```

## Results (M5 Max, macOS 26.5)

Synthetic shapes, 30 images/class, 3 classes, scenePrint(revision: 2) transfer
learning: training 0.6 s, train/validation/test accuracy all 100% — the
dataset is trivially separable, which is the point: the hypothesis→train→score
loop closes in under a second.

## Requirements

macOS 15.4+ (Image Playground app path), Apple Silicon recommended.
