import MLX
import MLXNN

/// Hand-written MLP: 784 -> hidden (ReLU) -> 10 logits.
final class MLPClassifier: Module, UnaryLayer {
  @ModuleInfo var fc1: Linear
  @ModuleInfo var fc2: Linear

  init(inputSize: Int = 28 * 28, hiddenSize: Int = 128, classCount: Int = 10) {
    fc1 = Linear(inputSize, hiddenSize)
    fc2 = Linear(hiddenSize, classCount)
  }

  func callAsFunction(_ x: MLXArray) -> MLXArray {
    var x = flattened(x, start: 1)
    x = relu(fc1(x))
    return fc2(x)
  }
}

func loss(model: MLPClassifier, x: MLXArray, y: MLXArray) -> MLXArray {
  crossEntropy(logits: model(x), targets: y, reduction: .mean)
}

func accuracy(model: MLPClassifier, x: MLXArray, y: MLXArray) -> Float {
  mean(argMax(model(x), axis: 1) .== y).item(Float.self)
}
