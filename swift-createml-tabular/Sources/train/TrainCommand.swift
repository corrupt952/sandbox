import CreateML
import Foundation
import TabularCore
import TabularData

@main
struct TrainCommand {
  static func main() {
    do {
      try run()
    } catch let error as TrainOptionsError {
      FileHandle.standardError.write(Data("\(error)\n\(TrainOptions.usage)\n".utf8))
      exit(1)
    } catch {
      FileHandle.standardError.write(Data("Error: \(error)\n".utf8))
      exit(1)
    }
  }

  static func run() throws {
    let options = try TrainOptions.parse(CommandLine.arguments)

    var frame = try DataFrame(
      contentsOfCSVFile: URL(fileURLWithPath: options.dataPath)
    )
    frame = try TabularPreprocessor.selecting(
      frame,
      columns: [options.target] + options.features
    )
    for column in frame.columns where column.wrappedElementType == Double.self {
      frame = try TabularPreprocessor.imputingMedian(frame, column: column.name)
    }
    frame = TabularPreprocessor.droppingRowsWithNil(frame)

    let (trainFrame, testFrame) = TabularPreprocessor.split(
      frame,
      trainFraction: options.trainFraction,
      seed: options.seed
    )
    print(
      "Rows: \(frame.rows.count) (train \(trainFrame.rows.count) / test \(testFrame.rows.count))")
    print("Features: \(options.features.joined(separator: ", "))")

    let start = Date()
    switch options.task {
    case .classification:
      try trainClassifier(options: options, train: trainFrame, test: testFrame)
    case .regression:
      try trainRegressor(options: options, train: trainFrame, test: testFrame)
    }
    print(String(format: "Elapsed: %.2fs", Date().timeIntervalSince(start)))
  }

  static func trainClassifier(options: TrainOptions, train: DataFrame, test: DataFrame) throws {
    let trainingError: Double
    let validationError: Double
    let testError: Double

    switch options.model {
    case .boostedTree:
      let model = try MLBoostedTreeClassifier(trainingData: train, targetColumn: options.target)
      trainingError = model.trainingMetrics.classificationError
      validationError = model.validationMetrics.classificationError
      testError = model.evaluation(on: test).classificationError
    case .linear:
      let model = try MLLogisticRegressionClassifier(
        trainingData: train,
        targetColumn: options.target
      )
      trainingError = model.trainingMetrics.classificationError
      validationError = model.validationMetrics.classificationError
      testError = model.evaluation(on: test).classificationError
    }

    print(String(format: "Training accuracy:   %.1f%%", (1 - trainingError) * 100))
    if !validationError.isNaN {
      print(String(format: "Validation accuracy: %.1f%%", (1 - validationError) * 100))
    }
    print(String(format: "Test accuracy:       %.1f%%", (1 - testError) * 100))
  }

  static func trainRegressor(options: TrainOptions, train: DataFrame, test: DataFrame) throws {
    let trainingRMSE: Double
    let testRMSE: Double

    switch options.model {
    case .boostedTree:
      let model = try MLBoostedTreeRegressor(trainingData: train, targetColumn: options.target)
      trainingRMSE = model.trainingMetrics.rootMeanSquaredError
      testRMSE = model.evaluation(on: test).rootMeanSquaredError
    case .linear:
      let model = try MLLinearRegressor(trainingData: train, targetColumn: options.target)
      trainingRMSE = model.trainingMetrics.rootMeanSquaredError
      testRMSE = model.evaluation(on: test).rootMeanSquaredError
    }

    print(String(format: "Training RMSE: %.4f", trainingRMSE))
    print(String(format: "Test RMSE:     %.4f", testRMSE))
  }
}
