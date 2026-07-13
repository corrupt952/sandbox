import Foundation
import MLX
import MLXNN
import MLXOptimizers
import MLXRandom
import MNISTCore

@main
struct TrainCommand {
  static func main() async {
    do {
      try await run()
    } catch let error as TrainOptionsError {
      FileHandle.standardError.write(Data("\(error)\n\(TrainOptions.usage)\n".utf8))
      exit(1)
    } catch {
      FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
      exit(1)
    }
  }

  static func run() async throws {
    let options = try TrainOptions.parse(CommandLine.arguments)
    let device = options.device == .cpu ? Device.cpu : Device.gpu
    try await Device.withDefaultDevice(device) {
      try await train(options: options)
    }
  }

  static func train(options: TrainOptions) async throws {
    MLXRandom.seed(options.seed)
    var generator = SplitMix64RandomNumberGenerator(seed: options.seed)

    let dataURL = URL(fileURLWithPath: options.dataPath)
    let (train, test) = try await MNISTDataset.load(into: dataURL, baseURL: options.baseURL)
    let trainImages = train.images
    let trainLabels = train.labels
    let testImages = test.images
    let testLabels = test.labels
    print("Train: \(trainImages.shape[0]) images, Test: \(testImages.shape[0]) images")

    let model = MLPClassifier()
    eval(model.parameters())

    let lossAndGrad = valueAndGrad(model: model, loss)
    let optimizer = SGD(learningRate: options.learningRate)

    for epoch in 0..<options.epochs {
      let start = Date()
      var lastLoss: Float = 0

      for (x, y) in batches(
        batchSize: options.batchSize,
        x: trainImages,
        y: trainLabels,
        using: &generator
      ) {
        let (lossValue, grads) = lossAndGrad(model, x, y)
        optimizer.update(model: model, gradients: grads)
        eval(model, optimizer)
        lastLoss = lossValue.item(Float.self)
      }

      let testAccuracy = accuracy(model: model, x: testImages, y: testLabels)
      let elapsed = Date().timeIntervalSince(start)
      print(
        String(
          format: "Epoch %d: loss %.4f, test accuracy %.2f%%, %.2fs",
          epoch + 1,
          lastLoss,
          testAccuracy * 100,
          elapsed
        ))
    }
  }

  static func batches(
    batchSize: Int,
    x: MLXArray,
    y: MLXArray,
    using generator: inout some RandomNumberGenerator
  ) -> [(MLXArray, MLXArray)] {
    let count = y.size
    let indices = Array(0..<count).shuffled(using: &generator)
    var result: [(MLXArray, MLXArray)] = []
    var start = 0
    while start < count {
      let end = min(start + batchSize, count)
      let ids = MLXArray(Array(indices[start..<end]))
      result.append((x[ids], y[ids]))
      start = end
    }
    return result
  }
}
