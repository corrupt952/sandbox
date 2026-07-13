import CreateML
import Foundation

@main
struct TrainCommand {
  static func main() throws {
    let options = try Options.parse(CommandLine.arguments)

    let source = MLImageClassifier.DataSource.labeledDirectories(at: options.dataURL)
    let parameters = MLImageClassifier.ModelParameters(
      validation: .split(strategy: .automatic),
      maxIterations: options.iterations,
      augmentation: [],
      algorithm: .transferLearning(
        featureExtractor: .scenePrint(revision: 2),
        classifier: .logisticRegressor
      )
    )

    print("Training on \(options.dataURL.path) (maxIterations: \(options.iterations))...")
    let start = Date()
    let classifier = try MLImageClassifier(trainingData: source, parameters: parameters)
    let elapsed = Date().timeIntervalSince(start)

    let trainingAccuracy = (1 - classifier.trainingMetrics.classificationError) * 100
    let validationAccuracy = (1 - classifier.validationMetrics.classificationError) * 100
    print(String(format: "Training took %.1fs", elapsed))
    print(String(format: "Training accuracy:   %.1f%%", trainingAccuracy))
    print(String(format: "Validation accuracy: %.1f%%", validationAccuracy))

    if let testURL = options.testDataURL {
      let testSource = MLImageClassifier.DataSource.labeledDirectories(at: testURL)
      let metrics = classifier.evaluation(on: testSource)
      let testAccuracy = (1 - metrics.classificationError) * 100
      print(String(format: "Test accuracy:       %.1f%%", testAccuracy))
    }

    try classifier.write(to: options.outputURL)
    print("Model saved: \(options.outputURL.path)")
  }
}

struct Options {
  var dataURL: URL
  var outputURL: URL
  var testDataURL: URL?
  var iterations: Int

  static func parse(_ arguments: [String]) throws -> Options {
    var data: String?
    var output = "ImageClassifier.mlmodel"
    var testData: String?
    var iterations = 20

    var iterator = arguments.dropFirst().makeIterator()
    while let argument = iterator.next() {
      switch argument {
      case "--data":
        data = iterator.next()
      case "--output":
        output = iterator.next() ?? output
      case "--test-data":
        testData = iterator.next()
      case "--iterations":
        iterations = Int(iterator.next() ?? "") ?? iterations
      case "--help", "-h":
        print(
          "Usage: train --data DIR [--output PATH] [--test-data DIR] [--iterations N]"
        )
        exit(0)
      default:
        FileHandle.standardError.write(Data("Unknown argument: \(argument)\n".utf8))
        exit(1)
      }
    }

    guard let data else {
      FileHandle.standardError.write(Data("Missing required argument: --data\n".utf8))
      exit(1)
    }

    return Options(
      dataURL: URL(fileURLWithPath: data),
      outputURL: URL(fileURLWithPath: output),
      testDataURL: testData.map { URL(fileURLWithPath: $0) },
      iterations: iterations
    )
  }
}
