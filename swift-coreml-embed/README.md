# swift-coreml-embed

Minimal Core ML embedding: compile a `.mlmodel` on-device
(`MLModel.compileModel`), load it, and run image classification from a CLI —
closing the train→convert→embed loop started in
[swift-createml-image-classifier](../swift-createml-image-classifier/).

Part of a series of experiments comparing feedback-loop speed across the Apple
ML stack (Create ML / Core ML / MLX).

## Structure

| Target | Kind | Purpose |
|--------|------|---------|
| `CoreMLEmbedCore` | library | Option parsing, prediction formatting, accuracy tally — unit-tested |
| `predict` | CLI | Compiles/loads a model, predicts a single image or a whole labeled directory tree |

The CLI reads the model's input image constraint from `modelDescription`, so
it works with any single-image-input classifier, and resolves the predicted
label / probability outputs via `predictedFeatureName` /
`predictedProbabilitiesName`.

## How to run

```sh
# Single image
swift run -c release predict --model ShapeClassifier.mlmodel --input circle.png

# Labeled directory (subdirectory name = expected label): reports accuracy
swift run -c release predict --model ShapeClassifier.mlmodel --input shapes/test
```

Tests:

```sh
swift test
```

## Results (M5 Max, macOS 26.5)

Using the shape classifier trained in swift-createml-image-classifier:
model compile 0.01 s, 100% (30/30) on the held-out synthetic test set,
~5 ms/image end-to-end (file read + resize + inference).

## Requirements

macOS 14+.
